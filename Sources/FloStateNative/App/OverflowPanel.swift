import AppKit
import FloCore
import FloKit

/// Flowriter Overflow: the panel on the right of the page for text you are not ready to use or delete.
///
/// The panel floats over the right margin of the page. It is an overlay on purpose: when it fits
/// the margin, nothing in the editor changes as it opens or closes, so the text column cannot move.
/// In a narrow window (margin under `minPanelWidth` plus air) the column moves left once as the
/// panel slides in, and back as it goes (EditorController.setSideReserve): the panel never covers
/// text, and typing never moves the column. It is solid, so the page never shows through. One
/// controller per editor pane; it lives as long as the pane (a theme rebuild swaps the editor
/// underneath it and the panel keeps its text).
@MainActor
final class OverflowController: NSObject, NSTextViewDelegate {
    static var animations = true
    /// Live controllers, for the menu and the save-on-quit flush.
    static let live = NSHashTable<OverflowController>.weakObjects()

    unowned let pane: EditorPaneView
    let documentPath: String
    let store: OverflowStoring
    let panel = OverflowPanelView()
    let button = OverflowToggleButton()
    private(set) var isOpen = false
    private var saveTimer: Timer?
    private var dirty = false
    private var paletteKey = ""
    private var quitObserver: NSObjectProtocol?
    private var animating = false
    /// Width at the pane's right edge the panel owns: the tab backing stops short of it so the panel's tint and
    /// hairline run up to the window top (ShellRootView.layout). Held through the slide-out.
    var reservedWidth: CGFloat { isOpen || animating ? panelWidth : 0 }
    /// A stash, remembered so the page's undo and redo carry the panel along: the page back at
    /// `before` takes `chunk` out of the panel, the page at `after` again puts it back. Every stash
    /// of the session is kept (newest last), so undoing a run of edits back past a stash works too.
    private struct StashRecord { var before: String, after: String, chunk: String, inPanel: Bool }
    private var stashes: [StashRecord] = []
    private var stashing = false
    static let maxStashRecords = 50

    /// The page's text now (the sidecar anchors its other items against it).
    private var documentText: String { pane.controller?.state.doc.string ?? pane.model.editor.file(documentPath)?.content ?? "" }

    var text: String {
        get { panel.textView.string }
        set { panel.textView.string = newValue; textChanged() }
    }

    init(pane: EditorPaneView, documentPath: String, store: OverflowStoring? = nil) {
        self.pane = pane
        self.documentPath = documentPath
        self.store = store ?? OverflowStoreFactory.make()
        super.init()
        panel.textView.delegate = self
        panel.textView.onUseInPage = { [weak self] in _ = self?.useSelectionInPage() }
        button.target = self
        button.action = #selector(toggleClicked)
        pane.addSubview(panel)
        pane.addSubview(button)
        let saved = self.store.load(documentPath: documentPath, documentText: documentText)
        panel.textView.string = saved.text
        isOpen = saved.open
        panel.isHidden = !isOpen
        button.isActive = isOpen
        OverflowController.live.add(self)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit { if let o = quitObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: open / close

    @objc private func toggleClicked() { toggle() }

    func toggle() { setOpen(!isOpen) }

    func setOpen(_ open: Bool, animated: Bool? = nil) {
        guard open != isOpen else { return }
        let animated = animated ?? OverflowController.animations
        isOpen = open
        button.isActive = open
        defer { (pane.superview as? EditorAreaView)?.updateRail() }
        pane.updateSideReserve(animated: animated)   // a narrow window: the column moves over
        pane.superview?.superview?.needsLayout = true   // the tab backing makes room for the panel
        dirty = true
        scheduleSave()
        let w = panelWidth
        if open {
            panel.isHidden = false
            panel.frame = panelFrame(open: false)
            if animated {
                animating = true
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    panel.animator().frame = panelFrame(open: true)
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated { self?.animating = false; self?.layout(); self?.pane.superview?.superview?.needsLayout = true }
                })
            } else {
                panel.frame = panelFrame(open: true)
            }
        } else {
            // the page comes back to focus when the panel that had it goes away
            if panel.window?.firstResponder === panel.textView, let c = pane.controller { panel.window?.makeFirstResponder(c.textView) }
            if animated {
                animating = true
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    panel.animator().frame = NSRect(x: pane.bounds.width, y: 0, width: w, height: pane.bounds.height)
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated { if let s = self { s.animating = false; if !s.isOpen { s.panel.isHidden = true }; s.layout(); s.pane.superview?.superview?.needsLayout = true } }
                })
            } else {
                panel.isHidden = true
            }
        }
        if !animated { layout() }
    }

    // MARK: stash and use

    /// Move the page's selection into the panel. One transaction, so one undo puts it back.
    @discardableResult
    func stashSelection() -> Bool {
        guard let c = pane.controller else { return false }
        let r = c.state.selection.main
        guard !r.empty, let plan = OverflowStash.plan(doc: c.state.doc.string, from: min(r.from, r.to), to: max(r.from, r.to)) else { NSSound.beep(); return false }
        let before = c.state.doc.string
        let cut = Change(from: plan.remove.location, to: NSMaxRange(plan.remove))
        // the editor's SidecarEditHook moves the anchors (ghosts, alternatives) with the cut;
        // the older stash records must not react to this edit
        stashing = true
        c.run { t in t.dispatch(TransactionSpec(changes: [cut])); return true }
        stashing = false
        let tv = panel.textView
        let existing = tv.string
        let add = existing.isEmpty ? plan.stashed : OverflowStash.append(plan.stashed, to: existing)
        // typed through the panel's own text system so its undo covers the stash
        let whole = NSRange(location: 0, length: (existing as NSString).length)
        if tv.shouldChangeText(in: whole, replacementString: add) {
            tv.textStorage?.replaceCharacters(in: whole, with: add)
            tv.didChangeText()
        }
        tv.scrollRangeToVisible(NSRange(location: (tv.string as NSString).length, length: 0))
        // the page undo that restores `before` also takes this chunk back out (and redo puts it back)
        let after = c.state.doc.string
        stashes.removeAll { $0.before == before && $0.after == after }   // the same stash again: one record
        stashes.append(StashRecord(before: before, after: after, chunk: plan.stashed, inPanel: true))
        if stashes.count > Self.maxStashRecords { stashes.removeFirst() }
        setOpen(true)
        return true
    }

    /// Panel selection into the page at its caret (replacing the page's selection), removed from the panel.
    @discardableResult
    func useSelectionInPage() -> Bool {
        let tv = panel.textView
        let sel = tv.selectedRange()
        guard sel.length > 0, let c = pane.controller else { return false }
        let s = (tv.string as NSString).substring(with: sel)
        let page = c.state.selection.main
        let from = min(page.from, page.to), to = max(page.from, page.to)
        let put = Change(from: from, to: to, insert: s)
        let end = from + s.utf16.count
        c.run { t in t.dispatch(TransactionSpec(changes: [put], selection: .single(end, end))); return true }
        if tv.shouldChangeText(in: sel, replacementString: "") {
            tv.textStorage?.replaceCharacters(in: sel, with: "")
            tv.didChangeText()
        }
        return true
    }

    /// The page text changed. An undo that brings the page back to what it was before a stash
    /// takes the stashed chunk out of the panel; the redo that brings the page back to just after
    /// it puts the chunk back. Other edits leave the panel alone.
    func pageChanged(_ doc: String) {
        guard !stashing, !stashes.isEmpty else { return }
        let n = doc.utf8.count
        for i in stashes.indices.reversed() {
            let r = stashes[i]
            if r.inPanel, r.before.utf8.count == n, doc == r.before {
                stashes[i].inPanel = false
                setPanelText(OverflowStash.remove(r.chunk, from: panel.textView.string))
                return
            }
            if !r.inPanel, r.after.utf8.count == n, doc == r.after {
                stashes[i].inPanel = true
                setPanelText(OverflowStash.append(r.chunk, to: panel.textView.string))
                return
            }
        }
    }

    private func setPanelText(_ s: String) {
        let tv = panel.textView
        let whole = NSRange(location: 0, length: (tv.string as NSString).length)
        guard tv.string != s, tv.shouldChangeText(in: whole, replacementString: s) else { return }
        tv.textStorage?.replaceCharacters(in: whole, with: s)
        tv.didChangeText()
    }

    // MARK: layout

    static let minPanelWidth: CGFloat = 220

    /// The page column's right edge in pane coordinates (nil without an editor).
    var columnRight: CGFloat? {
        guard let tv = pane.controller?.textView, let tc = tv.textContainer else { return nil }
        return tv.convert(NSPoint(x: tv.textContainerOrigin.x + tc.size.width, y: 0), to: pane).x
    }

    /// Wide enough to read, never wider than the margin right of the centred page column (with
    /// air). Below `minPanelWidth` of margin the column moves over instead (EditorPaneView.updateSideReserve).
    var panelWidth: CGFloat {
        let widest = min(360, max(280, pane.bounds.width * 0.3))
        guard let c = pane.controller else { return widest }
        let right = c.scrollView.convert(NSPoint(x: c.centredTextSpan.right, y: 0), from: c.textView).x
        return min(widest, max(Self.minPanelWidth, (pane.bounds.width - right - EditorController.panelAir).rounded(.down)))
    }

    func panelFrame(open: Bool) -> NSRect {
        NSRect(x: open ? pane.bounds.width - panelWidth : pane.bounds.width, y: 0, width: panelWidth, height: pane.bounds.height)
    }

    /// Called from the pane's layout (every resize and column pass).
    func layout() {
        applyPalette()
        if !animating { panel.frame = panelFrame(open: isOpen) }
        let footerShown = (pane.superview as? EditorAreaView).map { !$0.footer.isHidden } ?? false
        let bottom: CGFloat = footerShown ? Metrics.footerHeight + 4 : 16
        button.frame = NSRect(x: pane.bounds.width - 16 - OverflowToggleButton.size, y: pane.bounds.height - bottom - OverflowToggleButton.size,
                              width: OverflowToggleButton.size, height: OverflowToggleButton.size)
        panel.inset = panelWidth < 280 ? 28 : 44
        panel.layoutContents()
    }

    /// Theme: colours follow the editor's palette; the font is the page's size, smaller, monospaced.
    func applyPalette() {
        let model = pane.model
        let pal = model.palette_
        let c = pane.controller
        let fg = c?.theme.foreground ?? pal.fgBase
        let size = max(11, ((c?.theme.baseSize ?? 16) * 0.78).rounded())
        let key = "\(model.mode)|\(fg.hashValue)|\(c?.theme.background.hashValue ?? 0)|\(size)"
        guard key != paletteKey else { return }
        paletteKey = key
        // opaque: the page must never show through the panel
        let base = (c?.theme.background ?? pal.bg).withAlphaComponent(1)
        let bg = base.blended(withFraction: 0.035, of: fg) ?? base
        let font = c?.theme.font(size: size, weight: 400, mono: true) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        panel.style(background: bg, hairline: fg.withAlphaComponent(0.09), text: fg.withAlphaComponent(0.52),
                    hint: fg.withAlphaComponent(0.34), font: font, hintFont: NSFont.monospacedSystemFont(ofSize: max(10, size - 2), weight: .regular),
                    selection: c?.theme.selectionColor ?? .selectedTextBackgroundColor)
        button.idleColor = fg.withAlphaComponent(0.34)
        button.hoverColor = fg.withAlphaComponent(0.7)
        button.refreshTint()
    }

    // MARK: saving

    func textDidChange(_ notification: Notification) { panel.textView.needsDisplay = true; textChanged() }

    private func textChanged() {
        dirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Write now (the timer, toggling, quitting, and tests call this).
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard dirty else { return }
        dirty = false
        store.save(OverflowData(text: text, open: isOpen), documentPath: documentPath, documentText: documentText)
    }
}

// MARK: - panel view

@MainActor
final class OverflowPanelView: NSView, NSTextStorageDelegate {
    static let hintHeight: CGFloat = 44
    let scroll = NSScrollView()
    let textView = OverflowTextView()
    private var hairlineColor = NSColor.separatorColor
    /// Font, colour and line height for every character, whatever put it there (typing, paste, stash, drop).
    private var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var backgroundColor = NSColor.windowBackgroundColor

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 44, height: 72)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // Like the page (EditorController.configure): what you type is what the panel holds. A macOS
        // inline prediction is marked text over the word being typed (the typed letters plus the grey
        // rest); in build 69 the typed word went away with the prediction, so typing seemed to do nothing.
        textView.inlinePredictionType = .no
        if #available(macOS 15.0, *) { textView.mathExpressionCompletionType = .no }
        NoWritingTools.configure(textView)
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = false
        textView.setAccessibilityLabel("Overflow")
        textView.textStorage?.delegate = self
        addSubview(scroll)
    }

    /// Adds the base attributes (never replaces the run's own): text being composed (marked text from
    /// an input method or the accent menu) keeps what the text system put on it, and gets the base
    /// look when it is committed, which is an edit too.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), editedRange.length > 0 else { return }
        MainActor.assumeIsolated {
            guard !textView.hasMarkedText() else { return }
            textStorage.addAttributes(baseAttributes, range: editedRange)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func style(background: NSColor, hairline: NSColor, text: NSColor, hint hintColor: NSColor, font: NSFont, hintFont: NSFont, selection: NSColor) {
        backgroundColor = background
        hairlineColor = hairline
        textView.font = font
        textView.textColor = text
        textView.insertionPointColor = text.withAlphaComponent(0.9)
        textView.selectedTextAttributes = [.backgroundColor: selection]
        textView.typingAttributes = [.font: font, .foregroundColor: text]
        textView.placeholderColor = hintColor
        // paragraph rhythm: the page's line height, a little extra between paragraphs
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.45
        ps.paragraphSpacing = 0
        textView.defaultParagraphStyle = ps
        baseAttributes = [.font: font, .foregroundColor: text, .paragraphStyle: ps]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        }
        needsDisplay = true
    }

    /// Left and right text inset (smaller when the panel is narrow).
    var inset: CGFloat = 44 {
        didSet { if inset != oldValue { textView.textContainerInset = NSSize(width: inset, height: 72) } }
    }

    func layoutContents() {
        let h = Self.hintHeight
        scroll.frame = NSRect(x: 1, y: 0, width: max(0, bounds.width - 1), height: max(0, bounds.height - h))
    }

    override func layout() { super.layout(); layoutContents() }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        hairlineColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// Plain text, editable. Right-click adds "Move into page".
final class OverflowTextView: NSTextView {
    var onUseInPage: (() -> Void)?
    var placeholderColor = NSColor.tertiaryLabelColor
    static let placeholder = "Spare paragraphs, notes, links, an outline."

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event) ?? NSMenu()
        NoWritingTools.strip(m)
        if selectedRange().length > 0 {
            let item = NSMenuItem(title: "Move into page", action: #selector(useInPage(_:)), keyEquivalent: "")
            item.target = self
            m.insertItem(item, at: 0)
            m.insertItem(.separator(), at: 1)
        }
        return m
    }

    @objc func useInPage(_ sender: Any?) { onUseInPage?() }

    /// Dragging text out of the panel into the page moves it (the panel keeps nothing behind);
    /// holding Option copies. Dragging out of the app copies.
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .withinApplication else { return .copy }
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(useInPage(_:)) { return selectedRange().length > 0 }
        return super.validateUserInterfaceItem(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let f = font else { return }
        let w = max(0, bounds.width - 2 * textContainerOrigin.x)
        (Self.placeholder as NSString).draw(in: NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: w, height: 200),
                                            withAttributes: [.font: f, .foregroundColor: placeholderColor])
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - toggle button

@MainActor
final class OverflowToggleButton: NSButton {
    static let size: CGFloat = 28
    var idleColor = NSColor.tertiaryLabelColor
    var hoverColor = NSColor.secondaryLabelColor
    var isActive = false { didSet { refreshTint() } }
    private var hovering = false { didSet { refreshTint() } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Overflow")?.withSymbolConfiguration(cfg)
        toolTip = "Overflow (\u{2325}\u{2318}O)"
        setAccessibilityLabel("Toggle Overflow")
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }

    func refreshTint() { contentTintColor = (hovering || isActive) ? hoverColor : idleColor }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

extension EditorPaneView {
    /// Called from makeController (once per editor, so also after a theme rebuild): the pane keeps one
    /// OverflowController; the panel goes back on top of the new scroll view.
    func attachOverflow(to c: EditorController) {
        guard !ShellSnapshot.active else { return }
        SidecarEditHook.ensure(on: c, documentPath: path)   // anchors follow stashes and moves back
        OverflowMenu.attachContextMenu(to: c)
        if let o = overflow {
            addSubview(o.panel)
            addSubview(o.button)
            o.layout()
        } else {
            overflow = OverflowController(pane: self, documentPath: path)
        }
    }
}
