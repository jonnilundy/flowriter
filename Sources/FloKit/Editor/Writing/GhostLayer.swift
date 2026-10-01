import AppKit
import FloCore

/// Flowriter: Ghost on one editor. Keeps the ghost ranges in step with edits, draws them faded and
/// never touches the text or the layout: the fade is a TextKit 2 rendering attribute (the text
/// colour with its alpha scaled), which only changes how glyphs are painted. Hooks into the editor
/// are one line each (search "ghosts?.").
@MainActor
public final class GhostLayer: NSObject {
    unowned let editor: EditorController
    public private(set) var ranges: [GhostRange] = []
    public let store: SidecarGhostStore

    /// Share of the text colour left on an author ghost, and on a proposed one.
    public static var authorOpacity: CGFloat = 0.15
    public static var proposedOpacity: CGFloat = 0.15

    /// Called after every change to the ranges (the Lab and tests listen here).
    public var onChange: (() -> Void)?

    private var dirty = false
    private var saveItem: DispatchWorkItem?
    private var rendered = false

    public init(editor: EditorController, store: SidecarGhostStore) {
        self.editor = editor
        self.store = store
        super.init()
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
    }
    private var quitObserver: NSObjectProtocol?
    deinit { if let o = quitObserver { NotificationCenter.default.removeObserver(o) } }

    /// Attach to `editor` and load what was saved for the document.
    @discardableResult
    public static func attach(to editor: EditorController, store: SidecarGhostStore) -> GhostLayer {
        editor.ghosts?.detach()
        SidecarEditHook.ensure(on: editor, documentPath: store.session.documentURL.path)
        let l = GhostLayer(editor: editor, store: store)
        editor.ghosts = l
        l.documentReplaced()
        return l
    }

    public func detach() {
        flushSave()
        clearRendering()
        if editor.ghosts === self { editor.ghosts = nil }
    }

    // MARK: hooks (called by the editor)

    /// `load()` swapped the whole text (open, external reload): take the ghosts from the shared
    /// session (the editor's SidecarEditHook loaded or re-anchored it just before).
    func documentReplaced() {
        let text = editor.state.doc.string
        ranges = store.ghostRanges(doc: text)
        undoStack = []; redoStack = []
        snapshots = [:]; snapshotOrder = []
        remember()
        dirty = false
        applyRendering()
        onChange?()
    }

    /// After every state change. `edit` is the text change the editor's SidecarEditHook has
    /// already applied to the shared anchors (nil: only the selection moved); the ghost ranges
    /// are read back from the session, repainted, and saved when they moved. Text typed at the
    /// start or end of a ghost stays outside it, text typed inside joins it; a ghost whose text is
    /// gone is dropped (the sidecar's anchor rule). Undo and redo put back the ghosts the text had
    /// when it last looked like this, so undoing a deletion brings its ghost back.
    func stateDidChange(_ edit: SidecarEdit?) {
        if let e = edit {
            if !e.history { redoStack = [] }
            var moved = store.ghostRanges(doc: e.new.string)
            if e.history, let snap = snapshots[Self.key(e.new.units)], snap != moved {
                moved = snap
                store.saveGhostRanges(snap, doc: e.new.string)   // the shared session takes them back too
            }
            if moved != ranges { ranges = moved; dirty = true }
            remember()
        }
        guard !ranges.isEmpty || rendered else { return }
        applyRendering()
        if dirty { dirty = false; scheduleSave(); onChange?() }
    }

    // MARK: saving

    private func scheduleSave() {
        saveItem?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flushSave() } }
        saveItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Write the ranges now.
    public func flushSave() {
        guard saveItem != nil else { return }
        saveItem?.cancel(); saveItem = nil
        _ = try? store.session.save(doc: editor.state.doc.string)
    }

    // MARK: commands

    /// Ghost the selection (or, for a caret, nothing).
    @discardableResult
    public func ghost(from: Int, to: Int) -> Bool {
        let len = editor.state.doc.length
        let a = max(0, min(from, to)), b = min(len, max(from, to))
        guard b > a else { return false }
        record(GhostMath.ghost(ranges, from: a, to: b))
        return true
    }

    /// Revive, whole, every author ghost `[from, to)` touches (a caret: the ghost it sits in). A
    /// ghost is one thing to the writer, so Revive never leaves part of one behind.
    @discardableResult
    public func revive(from: Int, to: Int) -> Bool {
        revive(GhostMath.touching(ranges, from: from, to: to))
    }

    /// Revive from a right click at `pos`: the ghost under the click and, when the click is inside
    /// the selection, every ghost the selection touches. One undo step brings them all back.
    @discardableResult
    public func revive(at pos: Int) -> Bool {
        var hit = GhostMath.touching(ranges, from: pos, to: pos)
        let s = editor.state.selection.main
        let a = min(s.anchor, s.head), b = max(s.anchor, s.head)
        if b > a, pos >= a, pos <= b { hit += GhostMath.touching(ranges, from: a, to: b) }
        return revive(hit)
    }

    private func revive(_ hit: [GhostRange]) -> Bool {
        guard !hit.isEmpty else { return false }
        record(ranges.filter { !hit.contains($0) })
        return true
    }

    /// Accept or reject a proposed ghost (the Lab calls these): accept deletes the text, reject revives it.
    public func reject(_ g: GhostRange) { record(ranges.filter { $0 != g }) }

    /// The shortcut: with a caret in a ghost, or a selection that is ghost text (only ghosts and
    /// the white space between or after them), revive those ghosts whole; else ghost the selection.
    @discardableResult
    public func toggle() -> Bool {
        let s = editor.state.selection.main
        let a = min(s.anchor, s.head), b = max(s.anchor, s.head)
        if a == b || selectionIsGhostText(from: a, to: b) { return revive(from: a, to: b) }
        return ghost(from: a, to: b)
    }

    func selectionIsGhostText(from: Int, to: Int) -> Bool {
        GhostMath.isGhostText(ranges, from: from, to: to, in: editor.state.doc.units)
    }

    /// Replace the ranges (the Lab's trim tool passes proposed ghosts this way).
    public func set(_ new: [GhostRange]) {
        let n = GhostMath.normalize(new)
        guard n != ranges else { return }
        ranges = n
        dirty = false
        store.saveGhostRanges(n, doc: editor.state.doc.string)   // into the session now, to disk with it
        remember()
        applyRendering()
        onChange?()
    }

    // MARK: undo snapshots

    /// The ghosts for each document text seen this session (latest wins), so an undo or redo back
    /// to a text restores its ghosts, including ones the edit dropped with their text.
    private struct DocKey: Hashable { let length: Int; let hash: Int }
    private static func key(_ units: [UInt16]) -> DocKey {
        var h = Hasher()
        units.withUnsafeBufferPointer { h.combine(bytes: UnsafeRawBufferPointer($0)) }
        return DocKey(length: units.count, hash: h.finalize())
    }
    private var snapshots: [DocKey: [GhostRange]] = [:]
    private var snapshotOrder: [DocKey] = []
    static let maxSnapshots = 400

    private func remember() {
        if ranges.isEmpty && snapshots.isEmpty { return }   // no ghosts yet: nothing to restore
        let k = Self.key(editor.state.doc.units)
        if snapshots[k] == nil { snapshotOrder.append(k) }
        snapshots[k] = ranges
        if snapshotOrder.count > Self.maxSnapshots { snapshots[snapshotOrder.removeFirst()] = nil }
    }

    // MARK: undo

    /// A ghost change made by the writer, kept so Cmd-Z can undo it. It applies only while the text
    /// is what it was when the change was made, so it interleaves with text undo in the right order.
    private struct Op { var doc: [UInt16]; var before: [GhostRange]; var after: [GhostRange] }
    private var undoStack: [Op] = []
    private var redoStack: [Op] = []

    private func record(_ new: [GhostRange]) {
        let before = ranges
        set(new)
        guard ranges != before else { return }
        undoStack.append(Op(doc: editor.state.doc.units, before: before, after: ranges))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
    }

    /// Cmd-Z: undo the last ghost change when no text change came after it. False hands Cmd-Z to the text history.
    func undoGhost() -> Bool {
        guard let op = undoStack.last, op.doc == editor.state.doc.units else { return false }
        undoStack.removeLast()
        redoStack.append(op)
        set(op.before)
        return true
    }

    /// Cmd-Shift-Z: redo a ghost change undone at this very text.
    func redoGhost() -> Bool {
        guard let op = redoStack.last, op.doc == editor.state.doc.units else { return false }
        redoStack.removeLast()
        undoStack.append(op)
        set(op.after)
        return true
    }

    /// Words in the document outside ghosts.
    public func wordCount() -> Int { GhostMath.wordCount(editor.state.doc.string, ghosts: ranges) }

    // MARK: context menu

    /// Title of the ghost item for a right click at doc offset `pos`, nil for none.
    public func menuTitle(at pos: Int) -> String? {
        if let g = GhostMath.ghost(at: pos, in: ranges) { return g.origin == .author ? "Revive" : nil }
        let s = editor.state.selection.main
        let a = min(s.anchor, s.head), b = max(s.anchor, s.head)
        guard b > a && pos >= a && pos <= b else { return nil }
        return selectionIsGhostText(from: a, to: b) ? "Revive" : "Ghost it"
    }

    /// Put "Ghost it" or "Revive" at the top of the editor menu.
    func augment(_ menu: NSMenu, at pos: Int) {
        guard let title = menuTitle(at: pos) else { return }
        let it = NSMenuItem(title: L(title), action: #selector(menuFired(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = pos
        menu.insertItem(it, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func menuFired(_ sender: NSMenuItem) {
        guard let pos = sender.representedObject as? Int else { return }
        if menuTitle(at: pos) == "Revive" { revive(at: pos) } else if GhostMath.ghost(at: pos, in: ranges) == nil { toggle() }
    }

    // MARK: painting

    /// Proposed ghosts (Lab trim waiting for a decision): a thin dotted underline in the accent
    /// colour under each line of the range. Drawn in the text view, after the text (FloTextView.draw).
    func draw(_ dirty: NSRect) {
        let proposed = ranges.filter { $0.origin == .proposed }
        guard !proposed.isEmpty else { return }
        let len = editor.state.doc.length
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        for g in proposed {
            for r in editor.segmentRects(max(0, min(g.from, len)), max(0, min(g.to, len))) where r.insetBy(dx: 0, dy: -4).intersects(dirty) {
                let y = r.maxY - 2.5
                let line = NSBezierPath()
                line.move(to: NSPoint(x: r.minX, y: y)); line.line(to: NSPoint(x: r.maxX, y: y))
                line.lineWidth = 1
                line.setLineDash([1, 2.5], count: 2, phase: 0)
                line.lineCapStyle = .round
                line.stroke()
            }
        }
    }

    private func clearRendering() {
        guard rendered, let tlm = editor.textView.textLayoutManager else { return }
        for k in Self.keys { tlm.removeRenderingAttribute(k, for: tlm.documentRange) }
        rendered = false
        editor.textView.needsDisplay = true
    }
    private static let keys: [NSAttributedString.Key] = [.foregroundColor]

    /// Set the faded colour on every ghost, run by run so headings, links and code keep their own colour.
    func applyRendering() {
        guard let tv = editor.textView as NSTextView?, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let storage = tv.textStorage else { return }
        clearRendering()
        guard !ranges.isEmpty else { return }
        func textRange(_ r: NSRange) -> NSTextRange? {
            guard let a = tcm.location(tcm.documentRange.location, offsetBy: r.location),
                  let b = tcm.location(a, offsetBy: r.length) else { return nil }
            return NSTextRange(location: a, end: b)
        }
        for g in ranges {
            let span = NSRange(location: max(0, g.from), length: max(0, min(g.to, storage.length) - max(0, g.from)))
            guard span.length > 0 else { continue }
            let factor = g.origin == .author ? Self.authorOpacity : Self.proposedOpacity
            storage.enumerateAttribute(.foregroundColor, in: span, options: []) { v, run, _ in
                let base = (v as? NSColor) ?? NSColor.textColor
                let faded = base.withAlphaComponent(base.alphaComponent * factor)
                guard let tr = textRange(run) else { return }
                let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: faded]
                tlm.setRenderingAttributes(attrs, for: tr)
            }
        }
        rendered = true
        tv.needsDisplay = true
    }
}
