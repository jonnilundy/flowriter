import AppKit
import FloCore
import FloKit

/// Flowriter: the Alternatives panel, floating over the left margin of the page (⌘K v). A plain,
/// quiet list in the hint line's small monospace: the tabs are words (Word  Sentence  Paragraph,
/// the open one in the text colour and italic), each version is a line with a bullet, `●` for the
/// one shown in the page and `○` for the others (a small bot head for AI versions, filled when
/// shown), and the last line is `+ add a version`. No boxes: hover and the shown version are
/// colour only. The original is always the first line (versions keep the order they were made
/// in, and removing the original makes the oldest left the original), so it needs no caption.
/// Up / Down show each version in the page; typing goes into the add line and Return adds it;
/// Delete removes the shown version. While the panel has focus its target stays put; otherwise
/// it follows the caret. The add line, focused, is an empty version line (a hollow bullet, no
/// placeholder), so a writer can just type.
///
/// Sessions: "Add Alternative…" (menu, shortcut, the selection bar's alt) opens on the selection
/// with the empty line focused; Return adds the version and leaves a new empty line; Esc closes
/// the panel and gives the page its selection back (an empty line never typed into adds nothing).
/// The selection bar's versions opens on the set's versions with the shown one highlighted: Up /
/// Down move, Return applies (closes), Esc closes; focus back to the page either way.
///
/// Like the Overflow panel on the right it is an overlay: opaque, a hairline on its inner edge,
/// only as wide as the margin (220 pt at least), and opening or closing it leaves the text column
/// where it is. When the margin is narrower than that (a narrow window), the column moves over
/// once as the panel slides in (EditorController.setSideReserve), so the panel never covers text.
@MainActor
final class AlternativesPanelView: FlippedView, NSTextFieldDelegate {
    static var animations = true
    /// Content starts below the window buttons and the drag strip (the Overflow text sits there too).
    private var contentTop: CGFloat { Metrics.chromeDragHeight }
    private var animating = false
    weak var area: EditorAreaView?
    let model: ShellModel
    private(set) var isOpen = false
    private(set) var level: AlternativeLevel = .word
    let input = AlternativesInputField()
    private(set) weak var alts: AlternativesLayer?
    private var observers: [NSObjectProtocol] = []

    /// What a tab points at: an existing set, or the text a first version would be added to.
    struct Target: Equatable { var level: AlternativeLevel; var setId: String?; var range: NSRange }
    private(set) var targets: [AlternativeLevel: Target] = [:]

    struct Row { var variantId: String?; var text: String; var author: SidecarAuthor; var current: Bool; var original: Bool; var rect: NSRect = .zero }
    private(set) var rows: [Row] = []
    private var hoverRow: Int?
    private(set) var tabRects: [(AlternativeLevel, NSRect)] = []

    /// How the panel was opened: plain (⌥⌘A), or a session that Esc ends by closing it and giving
    /// the page back its selection (the range is the page selection when it opened).
    enum Session: Equatable { case none, add(NSRange), versions(NSRange) }
    private(set) var session: Session = .none
    /// The add line had focus at the last draw (it then shows as an empty version line).
    private var inputEditing = false

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        isHidden = true
        input.delegate = self
        input.panel = self
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.lineBreakMode = .byTruncatingTail
        input.cell?.isScrollable = true
        input.setAccessibilityLabel("New version")
        addSubview(input)
        observers.append(NotificationCenter.default.addObserver(forName: AlternativesLayer.didChange, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self = self, self.isOpen else { return }
                if n.object as AnyObject? === self.activeLayer { self.refresh() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self = self, self.isOpen, n.object as AnyObject? === self.window else { return }
                if self.activeLayer !== self.layer { self.refresh() }   // another tab became active
                self.focusChanged()
            }
        })
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var activeLayer: AlternativesLayer? { area?.activeFilePane?.controller?.alternatives }
    var palette: ShellPalette { model.palette_ }
    /// The panel's chrome font: SF Mono in the writing space (the page's face, one step smaller
    /// since monospace sets wider), the app's UI font in the upstream shell.
    func panelFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        FlowriterSpace.enabled ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight) : UIFonts.ui(model.values, size: size, weight: weight)
    }

    /// The versions and the add line: SF Mono 12 in the writing space, one step above the hint
    /// line's 11 so a word is still easy to read; the tabs are the hint line's size.
    var rowFont: NSFont { panelFont(13) }
    var tabFont: NSFont { panelFont(12) }

    func restyle() {
        input.font = rowFont
        input.textColor = palette.textPrimary
        input.placeholderAttributedString = inputEditing ? nil : NSAttributedString(string: "add a version", attributes: [
            .foregroundColor: palette.textMuted, .font: rowFont])
        needsDisplay = true
    }

    /// The add line is being edited (the field or its field editor has focus).
    var inputHasFocus: Bool {
        guard let fr = window?.firstResponder else { return false }
        if fr === input { return true }
        if let t = fr as? NSTextView, t.isFieldEditor, t.delegate === input { return true }
        return false
    }

    /// Focus moved (checked on every window update): the add line's look, and a session ends when
    /// the panel loses focus some other way (a click in the page).
    private func focusChanged() {
        let editing = inputHasFocus
        if editing != inputEditing { inputEditing = editing; restyle() }
        if session != .none && !hasFocus { session = .none }
    }

    // MARK: open / close

    func toggle() { isOpen ? close() : open() }

    /// Open on the text under the caret, on the smallest level that has versions there.
    func open() {
        session = .none
        setOpen(true)
        retarget(pin: false)
        if let l = alts, let s = l.session.innermost(at: l.caret) { level = s.level }
        refresh()
        window?.makeFirstResponder(rows.count > 1 ? self : input)
    }

    /// "Add Alternative…": open on the selection (its level read from its shape), field focused.
    func open(onSelection r: NSRange, in l: AlternativesLayer) {
        let t = AltText.trimmed(r, in: l.text)
        guard t.length > 0 else { open(); return }
        setOpen(true)
        alts = l
        retarget(pin: false)
        level = AltText.level(of: t, in: l.text)
        let existing = l.session.sets.first { $0.level == level && $0.from == t.location && $0.to == NSMaxRange(t) }
        targets[level] = Target(level: level, setId: existing?.id, range: t)
        input.stringValue = ""
        window?.makeFirstResponder(input)   // focus first: a focused panel keeps its targets
        session = .add(l.selectionRange)
        refresh()
        focusChanged()
    }

    /// The selection bar's versions: the panel on `s`, its shown version highlighted, the list focused.
    func openVersions(_ s: AlternativeSet, in l: AlternativesLayer) {
        let page = l.selectionRange
        setOpen(true)
        alts = l
        retarget(pin: false)
        level = s.level
        targets[level] = Target(level: level, setId: s.id, range: NSRange(location: s.from, length: s.to - s.from))
        input.stringValue = ""
        window?.makeFirstResponder(self)
        session = .versions(page)
        refresh()
        focusChanged()
    }

    func close() {
        let hadFocus = hasFocus
        session = .none
        setOpen(false)
        if hadFocus, let c = area?.activeFilePane?.controller { window?.makeFirstResponder(c.textView) }
    }

    /// End a session: close, focus the page, give it its selection back (on the target's current
    /// text when the selection was on it and it has versions now). The selection bar stays away
    /// from that range.
    func endSession() {
        var restore: NSRange?
        switch session {
        case .none: break
        case .add(let r), .versions(let r): restore = r
        }
        if let r = restore, r.length > 0, let l = alts, let id = targets[level]?.setId, let s = l.set(id) {
            restore = NSRange(location: s.from, length: s.to - s.from)
        }
        input.stringValue = ""
        session = .none
        let pane = area?.activeFilePane
        setOpen(false)
        guard let c = pane?.controller else { return }
        window?.makeFirstResponder(c.textView)
        if let r = restore, NSMaxRange(r) <= c.state.doc.length {
            pane?.selectionBar?.suppress(r)
            c.textView.setSelectedRange(r)
        }
    }

    private func setOpen(_ v: Bool) {
        guard v != isOpen else { return }
        isOpen = v
        guard let area = area else { isHidden = !v; return }
        let animated = Self.animations && window != nil
        let open = openFrame(in: area), closed = open.offsetBy(dx: -open.width, dy: 0)
        for p in area.panes.values { (p as? EditorPaneView)?.updateSideReserve(animated: animated) }
        if v {
            isHidden = false
            frame = animated ? closed : open
            refresh()
            guard animated else { return }
            animating = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                animator().frame = open
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.animating = false; self?.area?.needsLayout = true }
            })
        } else if animated {
            animating = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                animator().frame = closed
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { if let s = self { s.animating = false; if !s.isOpen { s.isHidden = true } } }
            })
        } else {
            isHidden = true
        }
    }

    /// Only as wide as the margin left of the page (the centred column's gutter, where heading
    /// marks hang), 220 pt at least, the Overflow panel's widest at most.
    func panelWidth(in area: EditorAreaView) -> CGFloat {
        let widest = min(360, max(280, area.bounds.width * 0.3))
        guard let pane = area.activeFilePane, let c = pane.controller else { return widest }
        let margin = c.scrollView.convert(NSPoint(x: c.centredTextSpan.left - c.gutterWidth, y: 0), from: c.textView).x
        return min(widest, max(OverflowController.minPanelWidth, margin.rounded(.down)))
    }

    func openFrame(in area: EditorAreaView) -> NSRect {
        NSRect(x: 0, y: 0, width: panelWidth(in: area), height: area.bounds.height)
    }

    var hasFocus: Bool {
        guard let fr = window?.firstResponder else { return false }
        if fr === self || fr === input { return true }
        if let t = fr as? NSTextView, t.isFieldEditor, t.delegate === input { return true }
        return false
    }

    /// The panel's frame in the area (called from its layout): over the panes, which keep their frames.
    func layoutIn(_ area: EditorAreaView) {
        guard isOpen, !animating else { return }
        let f = openFrame(in: area)
        if frame != f { frame = f }
        refresh()
    }

    // MARK: target + rows

    /// The targets for the caret (not while the panel has focus: then they stay put).
    private func retarget(pin: Bool) {
        alts = activeLayer
        guard let l = alts else { targets = [:]; return }
        var out: [AlternativeLevel: Target] = [:]
        for lv in AlternativeLevel.allCases {
            if pin, var t = targets[lv] {
                if let id = t.setId {
                    if let s = l.set(id) { t.range = NSRange(location: s.from, length: s.to - s.from) }
                    else { t.setId = nil }   // its last version was removed: the text stays as a candidate
                }
                out[lv] = t
                continue
            }
            if let s = l.set(level: lv, at: l.caret) {
                out[lv] = Target(level: lv, setId: s.id, range: NSRange(location: s.from, length: s.to - s.from))
            } else if let r = AltText.range(lv, in: l.text, at: l.caret) {
                out[lv] = Target(level: lv, setId: nil, range: r)
            }
        }
        targets = out
    }

    func refresh() {
        guard isOpen else { return }
        let rebound = activeLayer !== alts
        retarget(pin: hasFocus && !rebound)
        rows = []
        if let l = alts, let t = targets[level] {
            if let id = t.setId, let s = l.set(id) {
                rows = s.variants.map { v in
                    Row(variantId: v.id, text: l.text(of: v, in: s), author: v.author, current: v.id == s.currentId, original: v.id == s.originalId)
                }
            } else if NSMaxRange(t.range) <= l.text.length {
                rows = [Row(variantId: nil, text: l.text.substring(with: t.range), author: .me, current: true, original: true)]
            }
        }
        input.isEnabled = alts != nil && targets[level] != nil
        layoutRows()
        needsDisplay = true
    }

    /// The list's columns: the tabs and the bullets start `pad` from the panel's side, the text
    /// of every line (versions and the add line) starts at `textX`, and nothing comes closer than
    /// `pad` to the other side.
    static let pad: CGFloat = 18
    private var pad: CGFloat { AlternativesPanelView.pad }
    /// Centre of the bullet column.
    var markX: CGFloat { pad + 3 }
    var textX: CGFloat { pad + 16 }
    private var textW: CGFloat { bounds.width - textX - pad - 14 }   // 14: room for the × on hover
    private var lineHeight: CGFloat { ceil(rowFont.pointSize * 1.35) }
    private let rowGap: CGFloat = 5
    /// Where the add line's text starts (the field's text cell plus the cell's 2 pt padding).
    var fieldTextX: CGFloat { input.frame.minX + (input.cell?.titleRect(forBounds: input.bounds).minX ?? 0) + 2 }
    /// Top of the tab words, and of the first version.
    private var tabsY: CGFloat { contentTop + 14 }
    private var listY: CGFloat { tabsY + 16 + 18 }

    private func layoutRows() {
        var y = listY
        for i in rows.indices {
            let h = textHeight(rows[i].text)
            // the hit area is the full width and half the gap above and below
            rows[i].rect = NSRect(x: 0, y: y - rowGap / 2, width: bounds.width, height: h + rowGap)
            y += h + rowGap
        }
        let fh = lineHeight + 4
        input.frame = NSRect(x: textX - 2, y: y + 1 - 2, width: bounds.width - textX + 2 - pad, height: fh)
    }

    private func rowAttrs(_ r: Row, hover: Bool = false) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        return [.font: rowFont, .foregroundColor: r.current || hover ? palette.textPrimary : palette.textSecondary, .paragraphStyle: p]
    }

    private func textHeight(_ s: String) -> CGFloat {
        let r = (s as NSString).boundingRect(with: NSSize(width: textW, height: 10_000), options: [.usesLineFragmentOrigin],
                                              attributes: rowAttrs(Row(variantId: nil, text: s, author: .me, current: true, original: false)))
        // 4 lines at most (the last one ends in …): the list stays scannable, and Up / Down
        // shows the whole version in the page
        return min(ceil(r.height), 4 * lineHeight)
    }

    // MARK: drawing

    /// Opaque (the page never shows through), the Overflow panel's tint and hairline.
    var colors: (background: NSColor, hairline: NSColor) {
        let t = area?.activeFilePane?.controller?.theme
        let fg = t?.foreground ?? palette.fgBase
        let base = (t?.background ?? palette.bg).withAlphaComponent(1)
        return (base.blended(withFraction: 0.035, of: fg) ?? base, fg.withAlphaComponent(0.09))
    }

    override func draw(_ dirtyRect: NSRect) {
        let col = colors
        col.background.setFill()
        bounds.fill()
        col.hairline.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        // tabs: plain words, the open one in the text colour and italic (same advance in a
        // monospace face, so switching tabs never moves them), no underline, no rule
        tabRects = []
        var x = pad
        func title(_ lv: AlternativeLevel, on: Bool) -> NSAttributedString {
            let f = on ? NSFontManager.shared.convert(tabFont, toHaveTrait: .italicFontMask) : tabFont
            return NSAttributedString(string: lv.title, attributes: [.font: f, .foregroundColor: on ? palette.textPrimary : palette.textMuted])
        }
        // the three tabs keep the panel's side padding at its 220 pt minimum: the gap between them
        // shrinks (18 pt down to 8), measured with every tab in the open style
        let widest = AlternativeLevel.allCases.reduce(CGFloat(0)) { $0 + ceil(title($1, on: true).size().width) }
        let gap = min(18, max(8, ((bounds.width - 2 * pad - widest) / CGFloat(AlternativeLevel.allCases.count - 1)).rounded(.down)))
        for lv in AlternativeLevel.allCases {
            let title = title(lv, on: lv == level)
            let sz = title.size()
            let r = NSRect(x: x, y: tabsY, width: ceil(sz.width), height: 16)
            title.draw(at: NSPoint(x: r.minX, y: r.minY + (r.height - sz.height) / 2))
            tabRects.append((lv, r.insetBy(dx: -6, dy: -6)))
            x = r.maxX + gap
        }

        // versions: one bullet line each, colour only for the shown one and for hover
        let mid = firstLineMid
        for (i, r) in rows.enumerated() {
            let hover = i == hoverRow && !r.current
            let top = r.rect.minY + rowGap / 2
            drawMark(r.author, at: NSPoint(x: markX, y: top + mid), current: r.current, hover: hover)
            (r.text as NSString).draw(with: NSRect(x: textX, y: top, width: textW, height: r.rect.height - rowGap),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: rowAttrs(r, hover: hover))
            if i == hoverRow, r.variantId != nil, rows.count > 1 {
                let xr = removeRect(r)
                ("×" as NSString).draw(at: NSPoint(x: xr.minX, y: top), withAttributes: rowAttrs(Row(variantId: nil, text: "", author: .me, current: false, original: false))
                    .merging([.foregroundColor: palette.textMuted]) { $1 })
            }
        }

        // the add line, focused: an empty version line (a hollow bullet, the caret on the text column)
        if !input.isHidden && inputEditing {
            let fieldTop = input.frame.minY + (input.frame.height - lineHeight) / 2
            drawMark(.me, at: NSPoint(x: markX, y: fieldTop + mid), current: false, hover: false)
        }
        // the add line, not focused: a muted + in the bullet column, the field's text on the versions' column
        if !input.isHidden && !inputEditing {
            let plus = "+" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: rowFont, .foregroundColor: palette.textMuted]
            let sz = plus.size(withAttributes: attrs)
            let fieldTop = input.frame.minY + (input.frame.height - lineHeight) / 2
            plus.draw(at: NSPoint(x: (markX - sz.width / 2).rounded(), y: fieldTop + (lineHeight - sz.height) / 2), withAttributes: attrs)
        }
    }

    /// Middle of the x-height of a row's first line, measured with the same text system the row
    /// draws with (the mark sits there).
    private var firstLineMid: CGFloat {
        let attrs = rowAttrs(Row(variantId: nil, text: "x", author: .me, current: true, original: false))
        let storage = NSTextStorage(string: "x", attributes: attrs)
        let lm = NSLayoutManager(), tc = NSTextContainer(size: NSSize(width: 200, height: 100))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc); storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        let frag = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let baseline = frag.minY + lm.location(forGlyphAt: 0).y
        return baseline - rowFont.xHeight / 2
    }

    private func removeRect(_ r: Row) -> NSRect { NSRect(x: bounds.width - pad - 8, y: r.rect.minY + rowGap / 2, width: 10, height: lineHeight) }

    /// The writer's versions: `●` for the one shown in the page, `○` for the others. AI versions:
    /// a small bot head, filled when shown, outlined otherwise.
    private func drawMark(_ a: SidecarAuthor, at c: NSPoint, current: Bool, hover: Bool) {
        let col = current ? palette.textPrimary : hover ? palette.textSecondary : palette.textMuted
        col.setStroke(); col.setFill()
        switch a {
        case .me:
            let d: CGFloat = 5.5
            if current {
                NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
            } else {
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - d / 2 + 0.5, y: c.y - d / 2 + 0.5, width: d - 1, height: d - 1))
                ring.lineWidth = 1
                ring.stroke()
            }
        case .ai:
            let headRect = NSRect(x: c.x - 4, y: c.y - 2.5, width: 8, height: 6.5)
            let antenna = NSBezierPath()
            antenna.move(to: NSPoint(x: c.x, y: headRect.minY)); antenna.line(to: NSPoint(x: c.x, y: headRect.minY - 1.8))
            antenna.lineWidth = 1
            antenna.stroke()
            NSBezierPath(ovalIn: NSRect(x: c.x - 0.9, y: headRect.minY - 3.4, width: 1.8, height: 1.8)).fill()
            let eyes = [NSRect(x: c.x - 2.3, y: c.y, width: 1.5, height: 1.5), NSRect(x: c.x + 0.8, y: c.y, width: 1.5, height: 1.5)]
            if current {
                NSBezierPath(roundedRect: headRect, xRadius: 1.8, yRadius: 1.8).fill()
                colors.background.setFill()
                eyes.forEach { NSBezierPath(ovalIn: $0).fill() }
            } else {
                let head = NSBezierPath(roundedRect: headRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.6, yRadius: 1.6)
                head.lineWidth = 1
                head.stroke()
                eyes.forEach { NSBezierPath(ovalIn: $0).fill() }
            }
        }
    }

    // MARK: actions

    func setLevel(_ lv: AlternativeLevel) {
        guard lv != level else { return }
        level = lv
        refresh()
    }

    /// Show the version `step` rows away (Up / Down).
    func step(_ step: Int) {
        guard let l = alts, let id = targets[level]?.setId else { return }
        l.cycle(id, by: step)
        refresh()
    }

    func show(row i: Int) {
        guard let l = alts, let id = targets[level]?.setId, rows.indices.contains(i), let v = rows[i].variantId else { return }
        l.show(v, in: id)
        refresh()
    }

    /// Delete: remove the shown version (the original, or the next one, takes its place).
    func removeShown() {
        guard let i = rows.firstIndex(where: \.current) else { return }
        remove(row: i)
    }

    func remove(row i: Int) {
        guard let l = alts, let id = targets[level]?.setId, rows.indices.contains(i), let v = rows[i].variantId else { return }
        l.remove(v, from: id)
        refresh()
    }

    /// Return in the field: add its text as a version of the target and show it.
    @discardableResult
    func addFromInput() -> Bool {
        let s = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let l = alts, let t = targets[level] else { return false }
        guard let ids = l.addVersion(s, level: t.level, range: t.range) else { return false }
        targets[level]?.setId = ids.0
        input.stringValue = ""
        refresh()
        return true
    }

    func focusEditor() {
        if let c = area?.activeFilePane?.controller { window?.makeFirstResponder(c.textView) }
    }

    // MARK: keys

    override var acceptsFirstResponder: Bool { isOpen }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with e: NSEvent) {
        if handlePanelKey(e) { return }
        if let c = e.characters, !c.isEmpty, e.modifierFlags.intersection([.command, .control]).isEmpty,
           c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            window?.makeFirstResponder(input)
            input.currentEditor()?.insertText(c)
            return
        }
        super.keyDown(with: e)
    }

    private func handlePanelKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch e.keyCode {
        case 126: step(-1); return true              // Up
        case 125: step(1); return true               // Down
        case 123: cycleLevel(-1); return true        // Left
        case 124: cycleLevel(1); return true         // Right
        case 51, 117: removeShown(); return true     // Delete, forward delete
        case 36, 76:                                 // Return, Enter: applies in a versions session
            if case .versions = session { endSession() } else { window?.makeFirstResponder(input) }
            return true
        case 48: window?.makeFirstResponder(input); return true   // Tab
        case 53: if session != .none { endSession() } else { focusEditor() }; return true   // Escape
        default: return false
        }
    }

    func cycleLevel(_ d: Int) {
        let all = AlternativeLevel.allCases
        let i = all.firstIndex(of: level)!
        setLevel(all[(i + d + all.count) % all.count])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): addFromInput(); return true
        case #selector(NSResponder.moveUp(_:)): step(-1); return true
        case #selector(NSResponder.moveDown(_:)): step(1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if session != .none { endSession() }   // an uncommitted line is dropped
            else if input.stringValue.isEmpty { focusEditor() } else { input.stringValue = "" }
            return true
        case #selector(NSResponder.insertBacktab(_:)): window?.makeFirstResponder(self); return true
        default: return false
        }
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let t = tabRects.first(where: { $0.1.contains(p) }) { setLevel(t.0); window?.makeFirstResponder(self); return }
        if let i = rows.firstIndex(where: { $0.rect.contains(p) }) {
            window?.makeFirstResponder(self)
            if i == hoverRow, removeRect(rows[i]).insetBy(dx: -3, dy: -3).contains(p), rows.count > 1 { remove(row: i) } else { show(row: i) }
            return
        }
        window?.makeFirstResponder(self)
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h = rows.firstIndex { $0.rect.contains(p) }
        if h != hoverRow { hoverRow = h; needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) { if hoverRow != nil { hoverRow = nil; needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Alternatives" }
}

/// The panel's add line (Return adds a version): a borderless field, text centred vertically, no side inset.
final class AlternativesInputField: NSTextField {
    weak var panel: AlternativesPanelView?
    override class var cellClass: AnyClass? { get { CenteredFieldCell.self } set {} }
}

final class CenteredFieldCell: NSTextFieldCell {
    func inset(_ r: NSRect) -> NSRect {
        let h = cellSize(forBounds: r).height
        return NSRect(x: r.minX, y: r.minY + max(0, (r.height - h) / 2), width: r.width, height: h)
    }
    override func titleRect(forBounds r: NSRect) -> NSRect { inset(r) }
    override func drawingRect(forBounds r: NSRect) -> NSRect { inset(super.drawingRect(forBounds: r)) }
    override func edit(withFrame r: NSRect, in v: NSView, editor t: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(r), in: v, editor: t, delegate: delegate, event: event)
    }
    override func select(withFrame r: NSRect, in v: NSView, editor t: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: inset(r), in: v, editor: t, delegate: delegate, start: start, length: length)
    }
}
