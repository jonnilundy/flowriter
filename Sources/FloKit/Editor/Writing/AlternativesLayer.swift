import AppKit
import FloCore

/// Flowriter: Alternatives on one editor. Text with other versions gets a thin squiggle and
/// three small dots centred under it (the middle one in the accent colour while a version other than
/// the original is shown); a paragraph gets a thin line in the left margin instead of the
/// squiggle. Hover the text and press Up / Down to swap versions in place. Everything is drawn
/// in FloTextView.draw (like the find highlights): no characters, no attributes, no reflow.
///
/// Hooks into the editor are one line each (search "alternatives?."). The editing state is an
/// `AlternativesSession`; the stored state is the `alternatives` of the document's shared
/// `SidecarSession` (one per open document, shared with ghosts and overflow), written to
/// `.<name>.md.flowriter.json` next to the post.
@MainActor
public final class AlternativesLayer {
    unowned let editor: EditorController
    public let documentPath: String
    /// The document's shared sidecar (alternatives, ghosts, overflow in one file).
    public let shared: SidecarSession
    public private(set) var session: AlternativesSession
    /// The set under the mouse (Up / Down swap its versions).
    public private(set) var hoveredId: String? {
        didSet { if hoveredId != oldValue { editor.textView.needsDisplay = true; notify() } }
    }
    /// userEvent of the swaps this layer dispatches (their own history entries). The swap moves
    /// the anchors itself, so it is dispatched inside `SidecarEditHook.anchored { }`.
    public static let selectEvent = "alternative.select"
    public static let didChange = Notification.Name("FlowriterAlternativesDidChange")

    private var lastDoc: Text
    private var lastSelection: EditorSelection
    private var segmentCache: [String: [Segment]] = [:]
    private var saveWork: DispatchWorkItem?
    private var terminateObserver: NSObjectProtocol?
    private var toolsObserver: NSObjectProtocol?
    public private(set) var saveCount = 0
    public private(set) var lastSaveError: Error?
    public var saveDelay: TimeInterval = 0.4

    private static var live: [String: WeakLayer] = [:]
    private final class WeakLayer { weak var layer: AlternativesLayer?; init(_ l: AlternativesLayer) { layer = l } }

    init(editor: EditorController, documentPath: String) {
        self.editor = editor
        self.documentPath = documentPath
        shared = SidecarSession.shared(for: documentPath)
        lastDoc = editor.state.doc
        lastSelection = editor.state.selection
        session = AlternativesSession()
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        // WritingTools off: no squiggles, dots or margin lines, no hover swaps (the sets stay)
        toolsObserver = NotificationCenter.default.addObserver(forName: WritingTools.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoveredId = nil; self?.editor.textView.needsDisplay = true }
        }
    }

    deinit { for o in [terminateObserver, toolsObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(o) } }

    /// Attach to `editor` and load the document's sidecar against its current text.
    @discardableResult
    public static func attach(to editor: EditorController, documentPath: String) -> AlternativesLayer {
        if let old = live[documentPath]?.layer, old.editor !== editor { old.flush() }   // a rebuilt editor on the same file
        editor.alternatives?.detach()
        SidecarEditHook.ensure(on: editor, documentPath: documentPath)
        let layer = AlternativesLayer(editor: editor, documentPath: documentPath)
        editor.alternatives = layer
        live[documentPath] = WeakLayer(layer)
        layer.loadFromDisk()
        return layer
    }

    public func detach() {
        flush()
        if editor.alternatives === self { editor.alternatives = nil }
        editor.textView.needsDisplay = true
        notify()
    }

    public var sidecarURL: URL { SidecarStore.url(for: shared.documentURL) }

    /// Take the alternatives from the shared sidecar (read from disk on the document's first open).
    func loadFromDisk() {
        shared.loadIfNeeded(doc: editor.state.doc.string)
        session = AlternativesSession(sidecar: DocumentSidecar(alternatives: shared.sidecar.alternatives))
        lastDoc = editor.state.doc
        session.record(doc: lastDoc.units)
        changed(save: false)
    }

    // MARK: hooks (called by the editor)

    /// `load()` swapped the whole text (external reload): the editor's SidecarEditHook found the
    /// anchors again by quote (lost ones went to `unresolved`); take its result.
    func documentReplaced() {
        let doc = editor.state.doc
        guard lastDoc !== doc, lastDoc.units != doc.units else { lastDoc = doc; return }
        session = AlternativesSession(sidecar: DocumentSidecar(alternatives: shared.sidecar.alternatives))
        lastDoc = doc
        session.record(doc: doc.units)
        hoveredId = nil
        changed(save: true)
    }

    /// After every state change (EditorFeatures.stateDidChange). `edit` is the text change the
    /// editor's SidecarEditHook already applied to the shared anchors (nil: only the selection
    /// moved). The layer adopts the moved sets and adds what only it knows: undo snapshots,
    /// authorship of edited AI versions.
    func stateDidChange(_ edit: SidecarEdit?) {
        let doc = editor.state.doc
        let selMoved = editor.state.selection != lastSelection
        lastSelection = editor.state.selection
        guard let e = edit, doc !== lastDoc, doc.units != lastDoc.units else {
            lastDoc = doc
            if selMoved { notify() }
            return
        }
        let old = lastDoc
        let oldSets = session.sets
        let undo = e.history, own = e.anchored
        session.adopt(shared.sidecar.alternatives, dropped: e.before.alternatives.filter { e.result.droppedAlternatives.contains($0.id) })
        if undo { session.restore(doc: doc.units, old: old.units, oldSets: oldSets) }
        if !own && !undo { session.claimEditedVersions(doc: doc.units) }
        session.record(doc: doc.units)
        lastDoc = doc
        if !own && !undo { hoveredId = nil }   // typing hides the pointer: no hover until it moves
        changed(save: true)
    }

    /// The column moved or resized (EditorController.layoutColumn).
    func layoutChanged() {
        segmentCache.removeAll()
        editor.textView.needsDisplay = true
    }

    private func changed(save: Bool) {
        publish()
        segmentCache.removeAll()
        if let h = hoveredId, session.set(h)?.visible != true { hoveredId = nil }
        editor.textView.needsDisplay = true
        if save { scheduleSave() }
        notify()
    }

    private func notify() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    // MARK: API (panel, menu, tests)

    public var doc: [UInt16] { editor.state.doc.units }
    public var text: NSString { editor.state.doc.string as NSString }
    public var caret: Int { editor.state.selection.main.head }
    public var selectionRange: NSRange {
        let m = editor.state.selection.main
        return NSRange(location: m.from, length: m.to - m.from)
    }

    public func set(_ id: String) -> AlternativeSet? { session.set(id) }
    public func text(of v: AlternativeVariant, in set: AlternativeSet) -> String { AlternativesSession.text(of: v, in: set, doc: doc) }

    /// The set at `level` around `pos`, if any.
    public func set(level: AlternativeLevel, at pos: Int) -> AlternativeSet? { session.innermost(at: pos, level: level) }

    /// Show `variantId` of a set in the document (one undo step).
    @discardableResult
    public func show(_ variantId: String, in setId: String) -> Bool {
        let before = editor.state
        let hook = SidecarEditHook.ensure(on: editor, documentPath: documentPath)
        // The swap runs on the shared sidecar, so every anchor moves with it (ghosts, and sets that
        // enclose the word), then goes into the text as an anchored change: the hook skips it.
        publish()
        let units = before.doc.units
        guard let change = (try? shared.update({ try $0.selectVariant(variantId, in: setId, text: String(utf16CodeUnits: units, count: units.count)) })) ?? nil else { return false }
        session.adopt(shared.sidecar.alternatives, dropped: [])
        // A swap is its own undo step, and typing right after it starts a new one.
        hook.anchored {
            editor.session.env.time = Date().timeIntervalSince1970 * 1000
            editor.session.dispatch(TransactionSpec(changes: change.changes, userEvent: Self.selectEvent, scrollIntoView: false,
                                                    filter: false, isolateHistory: .full))
            editor.sync(from: before, scroll: false)
        }
        return true
    }

    /// Next (+1) / previous (-1) version of a set, wrapping.
    @discardableResult
    public func cycle(_ setId: String, by step: Int) -> Bool {
        guard let v = session.stepped(setId, step) else { return false }
        return show(v, in: setId)
    }

    /// Add a version of `range` at `level` and show it. Returns (set id, variant id).
    @discardableResult
    public func addVersion(_ text: String, author: SidecarAuthor = .me, level: AlternativeLevel, range: NSRange, show showIt: Bool = true) -> (String, String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, range.length > 0, NSMaxRange(range) <= doc.count else { return nil }
        session.refreshCurrentTexts(doc: doc)
        guard let ids = try? session.addVersion(t, author: author, level: level, range: range, doc: editor.state.doc.string) else { return nil }
        session.record(doc: doc)
        if showIt { show(ids.1, in: ids.0) }
        changed(save: true)
        return ids
    }

    /// Remove a version. The shown one is swapped for the original (or the next) first; with a
    /// single version left the set goes and the text stays as it is.
    public func remove(_ variantId: String, from setId: String) {
        guard var s = session.set(setId) else { return }
        if s.currentId == variantId {
            let other = s.originalId != variantId ? s.originalId : session.stepped(setId, 1)
            guard let o = other, o != variantId else { return }
            show(o, in: setId)
            guard let again = session.set(setId) else { return }
            s = again
        }
        try? session.remove(variantId, from: s.id)
        session.record(doc: doc)
        changed(save: true)
    }

    // MARK: keys + hover

    /// Up / Down while the pointer is on text with versions: swap in place.
    func handleKey(_ chord: String) -> Bool {
        guard let id = hoveredId, editor.features.completion.open == nil else { return false }
        switch chord {
        case "Down": return cycle(id, by: 1)
        case "Up": return cycle(id, by: -1)
        default: return false
        }
    }

    /// FloTextView.mouseMoved (view coordinates).
    public func mouseMoved(_ p: NSPoint) { hoveredId = hit(p)?.id }
    func mouseExited() { hoveredId = nil }

    /// The smallest visible set drawn under a text-view point.
    public func hit(_ p: NSPoint) -> AlternativeSet? {
        guard WritingTools.isOn else { return nil }
        return session.sets.filter { s in
            guard s.visible else { return false }
            if s.level == .paragraph, let m = marginLine(s), m.insetBy(dx: -5, dy: 0).contains(p) { return true }
            return segments(s).contains { $0.rect.insetBy(dx: 0, dy: -1).contains(p) }
        }.min { $0.anchor.length < $1.anchor.length }
    }

    // MARK: geometry + painting

    public struct Segment { public let rect: NSRect; public let baseline: CGFloat }

    /// Text segments of a set with the baseline of each (view coordinates).
    public func segments(_ s: AlternativeSet) -> [Segment] {
        if let c = segmentCache[s.id] { return c }
        let len = editor.state.doc.length
        let out = segments(max(0, min(s.anchor.from, len)), max(0, min(s.anchor.to, len)))
        segmentCache[s.id] = out
        return out
    }

    public func segments(_ from: Int, _ to: Int) -> [Segment] {
        guard let tlm = editor.textView.textLayoutManager, let tcm = tlm.textContentManager,
              let a = tcm.location(tcm.documentRange.location, offsetBy: from),
              let b = tcm.location(tcm.documentRange.location, offsetBy: to),
              let range = NSTextRange(location: a, end: b) else { return [] }
        var out: [Segment] = []
        let o = editor.textView.textContainerOrigin
        tlm.enumerateTextSegments(in: range, type: .standard, options: [.rangeNotRequired]) { _, r, baseline, _ in
            if r.width > 0 { out.append(Segment(rect: r.offsetBy(dx: o.x, dy: o.y), baseline: r.minY + o.y + baseline)) }
            return true
        }
        return out
    }

    /// The paragraph's margin line (left of the text column).
    public func marginLine(_ s: AlternativeSet) -> NSRect? {
        let segs = segments(s)
        guard let first = segs.first, let last = segs.last else { return nil }
        let x = editor.textView.textContainerOrigin.x + editor.applier.gutter - 7
        let top = first.baseline - bodyFont.ascender + 1
        let bottom = last.baseline - bodyFont.descender - 1
        return NSRect(x: x, y: top, width: 1.5, height: max(2, bottom - top))
    }

    static let dotSize: CGFloat = 2.2, dotGap: CGFloat = 1.6
    static var dotsWidth: CGFloat { 3 * dotSize + 2 * dotGap }
    /// Below the baseline, where the squiggle runs.
    public static let underlineOffset: CGFloat = 3.5

    /// Space kept clear of squiggle on each side of the dots.
    static let dotsClear: CGFloat = 2.5

    /// The three dots, centred under the text (a multi-line set: under its last line's part), on
    /// the underline. A word shorter than the dots gets them centred anyway.
    public func dots(_ s: AlternativeSet) -> [NSRect] {
        guard let last = segments(s).last else { return [] }
        let d = Self.dotSize
        let x0 = last.rect.midX - Self.dotsWidth / 2
        let y = last.baseline + Self.underlineOffset - d / 2
        return (0..<3).map { i in NSRect(x: x0 + CGFloat(i) * (d + Self.dotGap), y: y, width: d, height: d) }
    }

    /// The squiggle's horizontal runs: each text segment whole, except the last, which is cut
    /// around the dots (a run too short to read as a wave is dropped).
    public func squiggleSpans(_ s: AlternativeSet) -> [(x0: CGFloat, x1: CGFloat, y: CGFloat)] {
        let segs = segments(s)
        var out: [(x0: CGFloat, x1: CGFloat, y: CGFloat)] = []
        for (k, seg) in segs.enumerated() {
            let y = seg.baseline + Self.underlineOffset
            if k < segs.count - 1 { out.append((seg.rect.minX, seg.rect.maxX, y)); continue }
            let half = Self.dotsWidth / 2 + Self.dotsClear
            for (a, b) in [(seg.rect.minX, seg.rect.midX - half), (seg.rect.midX + half, seg.rect.maxX)] where b - a > 2 {
                out.append((a, b, y))
            }
        }
        return out
    }

    var bodyFont: NSFont { editor.theme.font(size: editor.theme.baseSize, weight: 400, mono: false) }
    var inkColor: NSColor { editor.theme.primaryColor }
    var accentColor: NSColor { editor.features.chrome.tokens.accent.nsColor }

    public private(set) var drawCount = 0
    /// What the last draw put on screen, per set id (tests).
    public private(set) var lastDrawn: [String: (squiggle: Bool, margin: Bool, highlightedDot: Bool)] = [:]

    /// FloTextView.draw.
    func draw(_ dirty: NSRect) {
        let visible = WritingTools.isOn ? session.sets.filter(\.visible) : []   // the tools switch (WritingTools.swift)
        guard !visible.isEmpty else { if !lastDrawn.isEmpty { lastDrawn = [:] }; return }
        drawCount += 1
        segmentCache.removeAll(keepingCapacity: true)   // hit tests use what this pass draws
        var drawn: [String: (Bool, Bool, Bool)] = [:]
        for s in visible {
            let segs = segments(s)
            guard !segs.isEmpty else { continue }
            let hot = s.id == hoveredId
            let dark = editor.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink = inkColor.withAlphaComponent(hot ? 0.62 : dark ? 0.42 : 0.34)   // light ink on dark reads thinner
            var squiggle = false, margin = false
            if s.level == .paragraph, let m = marginLine(s) {
                margin = true
                if m.intersects(dirty) {
                    inkColor.withAlphaComponent(hot ? 0.55 : 0.28).setFill()
                    NSBezierPath(roundedRect: m, xRadius: 0.75, yRadius: 0.75).fill()
                }
            } else {
                squiggle = true
                ink.setStroke()
                for span in squiggleSpans(s) where NSRect(x: span.x0, y: span.y - 5, width: span.x1 - span.x0, height: 10).insetBy(dx: -2, dy: 0).intersects(dirty) {
                    squigglePath(from: span.x0, to: span.x1, y: span.y).stroke()
                }
            }
            let ds = dots(s)
            let highlight = !s.showsOriginal
            for (i, r) in ds.enumerated() where r.insetBy(dx: -2, dy: -2).intersects(dirty) {
                if i == 1 && highlight { accentColor.setFill() } else { inkColor.withAlphaComponent(hot ? 0.6 : 0.34).setFill() }
                NSBezierPath(ovalIn: r).fill()
            }
            drawn[s.id] = (squiggle, margin, highlight)
        }
        lastDrawn = drawn.mapValues { (squiggle: $0.0, margin: $0.1, highlightedDot: $0.2) }
    }

    /// A thin wave, phase-locked to the view's x so overlapping squiggles coincide.
    func squigglePath(from x0: CGFloat, to x1: CGFloat, y: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = 0.9
        let wave: CGFloat = 4, amp: CGFloat = 1.1
        var x = x0
        p.move(to: NSPoint(x: x, y: y + amp * sin(2 * .pi * x / wave)))
        while x < x1 {
            x = min(x1, x + 0.5)
            p.line(to: NSPoint(x: x, y: y + amp * sin(2 * .pi * x / wave)))
        }
        return p
    }

    // MARK: saving

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: w)
    }

    /// Write pending changes now (detach, quit, tests).
    public func flush() {
        guard saveWork != nil else { return }
        saveNow()
    }

    /// Put this editor's alternatives into the shared sidecar (other features keep theirs).
    func publish() {
        session.refreshCurrentTexts(doc: doc)
        let sets = session.sets.filter(\.visible)
        shared.update { $0.alternatives = sets }
    }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        publish()
        do { try shared.save(doc: editor.state.doc.string); lastSaveError = nil } catch { lastSaveError = error }
        saveCount += 1
    }
}
