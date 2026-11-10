import AppKit

/// The notes drawer: a second editor at the right edge of the window, beside the page. Drag its
/// left edge to set the width.
@MainActor
final class NotesDrawerView: NSView {
    static let widthKey = "FlowriterNotesWidth"
    static let minWidth: CGFloat = 200

    let textView = EditorTextView()
    let scroll = NSScrollView()
    /// Called while the edge is dragged, with the width the pointer asks for.
    var onResize: ((CGFloat) -> Void)?
    private var dragStart: (x: CGFloat, width: CGFloat)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        textView.column = .fill(18)
        textView.placeholder = "Notes"
        textView.isContinuousSpellCheckingEnabled = false
        textView.setAccessibilityLabel("Notes")
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    static var storedWidth: CGFloat {
        let w = UserDefaults.standard.double(forKey: widthKey)
        return w >= Double(minWidth) ? CGFloat(w) : 340
    }

    override func layout() {
        super.layout()
        // the scroll view starts right of the drag edge, so the edge keeps its own pointer
        scroll.frame = NSRect(x: edge.width, y: 0, width: max(0, bounds.width - edge.width), height: bounds.height)
        textView.layoutColumn()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.drawerBackground.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: the drag edge

    private var edge: NSRect { NSRect(x: 0, y: 0, width: 6, height: bounds.height) }

    override func resetCursorRects() { addCursorRect(edge, cursor: .resizeLeftRight) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        return edge.contains(convert(point, from: superview)) ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = edge.contains(convert(event.locationInWindow, from: nil)) ? (event.locationInWindow.x, bounds.width) : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        onResize?(start.width + (start.x - event.locationInWindow.x))
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { UserDefaults.standard.set(Double(bounds.width), forKey: Self.widthKey) }
        dragStart = nil
    }
}

@MainActor
final class RootView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); onLayout?() }
    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill() }
}

/// One window per document: the page, and the notes drawer beside it.
@MainActor
public final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    public static let focusKey = "FlowriterFocusMode"
    static func notesOpenKey(_ path: String) -> String { "FlowriterOverflowOpen." + path }

    public let editor = EditorTextView()
    let editorScroll = NSScrollView()
    let drawer = NotesDrawerView()
    let root = RootView()
    private let countLabel = NSTextField(labelWithString: "")
    private let notesButton = NSButton()
    public private(set) var notesOpen = false
    private var notesWidth = NotesDrawerView.storedWidth
    private var countTimer: Timer?
    private var loading = false

    var doc: Document? { document as? Document }
    /// A document made outside NSDocumentController (snapshots, tests) has no other owner. `close()` ends the cycle.
    var keptDocument: Document?

    public init(document: Document) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 420, height: 300)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("FlowriterDocument")
        if !window.setFrameUsingName("FlowriterDocument") { window.center() }

        editorScroll.documentView = editor
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.borderType = .noBorder
        editor.delegate = self
        editor.onToggleNotes = { [weak self] in self?.toggleNotes(nil) }
        editor.onSwitchNotes = { [weak self] in self?.switchPageAndNotes(nil) }
        editor.focusMode = Self.focusModeDefault
        editor.setAccessibilityLabel("Page")
        drawer.textView.delegate = self
        drawer.textView.onToggleNotes = { [weak self] in self?.toggleNotes(nil) }
        drawer.textView.onSwitchNotes = { [weak self] in self?.switchPageAndNotes(nil) }
        drawer.onResize = { [weak self] w in self?.setNotesWidth(w) }
        drawer.isHidden = true
        root.addSubview(editorScroll)
        root.addSubview(drawer)
        root.onLayout = { [weak self] in self?.layoutContent() }
        window.contentView = root
        installTitlebarItems(in: window)

        load(document)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Focus mode as stored (the earlier app called it Tracking Mode and kept it under another key).
    static var focusModeDefault: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: focusKey) != nil { return d.bool(forKey: focusKey) }
        return d.bool(forKey: "FlowriterTrackingMode")
    }

    private func load(_ document: Document) {
        loading = true
        editor.load(document.diskText)
        drawer.textView.load(document.notes)
        loading = false
        document.liveText = { [weak self] in self?.editor.string ?? "" }
        document.onReload = { [weak self] text in self?.reload(text) }
        document.onReplaceText = { [weak self] text in
            guard let editor = self?.editor, text != editor.string else { return }
            let caret = min(editor.selectedRange().location, (text as NSString).length)
            editor.apply(TextEdit(range: NSRange(location: 0, length: (editor.string as NSString).length), text: text,
                                  selection: NSRange(location: caret, length: 0)))
        }
        if let path = document.fileURL?.path { notesOpen = UserDefaults.standard.bool(forKey: Self.notesOpenKey(path)) }
        drawer.isHidden = !notesOpen
        updateCount()
        window?.makeFirstResponder(editor)
    }

    /// The file changed on disk and was read again: show it, keeping the caret and the scroll place.
    private func reload(_ text: String) {
        guard text != editor.string else { return }
        let y = editorScroll.contentView.bounds.origin.y
        loading = true
        editor.load(text)
        loading = false
        let maxY = max(0, editor.frame.height - editorScroll.contentView.bounds.height)
        editorScroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        updateCount()
    }

    // MARK: layout

    private func layoutContent() {
        let b = root.bounds
        let maxWidth = max(NotesDrawerView.minWidth, b.width - 260)
        let w = notesOpen ? min(max(NotesDrawerView.minWidth, notesWidth), maxWidth) : 0
        editorScroll.frame = b
        editorScroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: w)
        drawer.frame = NSRect(x: b.width - w, y: 0, width: w, height: b.height)
        editor.reservedRight = w
        editor.layoutColumn()
    }

    private func setNotesWidth(_ w: CGFloat) {
        notesWidth = w
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }

    private func installTitlebarItems(in window: NSWindow) {
        countLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = Theme.mark
        countLabel.alignment = .right
        notesButton.isBordered = false
        notesButton.bezelStyle = .regularSquare
        notesButton.imagePosition = .imageOnly
        notesButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Notes")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        notesButton.contentTintColor = Theme.mark
        notesButton.toolTip = "Notes (\u{2325}O)"
        notesButton.target = self
        notesButton.action = #selector(toggleNotes(_:))
        notesButton.setAccessibilityLabel("Toggle Notes")
        let stack = NSStackView(views: [countLabel, notesButton])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: text view delegate

    public func undoManager(for view: NSTextView) -> UndoManager? {
        // the page's undo is the document's (it drives "edited" and saving); the notes keep their own
        view === editor ? doc?.undoManager : notesUndo
    }
    private let notesUndo = UndoManager()

    public func textDidChange(_ notification: Notification) {
        guard !loading, let view = notification.object as? EditorTextView else { return }
        if view === editor {
            doc?.textDidChange()
            countTimer?.invalidate()
            countTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCount() }
            }
        } else {
            doc?.setNotes(view.string)
        }
    }

    private func updateCount() {
        countTimer = nil
        let text = editor.string as NSString
        var words = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let w = f.string(from: NSNumber(value: words)) ?? "\(words)"
        let c = f.string(from: NSNumber(value: (editor.string as String).count)) ?? "0"
        countLabel.stringValue = "\(w) \(words == 1 ? "word" : "words")   \(c) chars"
    }

    // MARK: actions

    @objc public func toggleNotes(_ sender: Any?) { setNotesOpen(!notesOpen) }

    public func setNotesOpen(_ open: Bool) {
        guard open != notesOpen else { return }
        notesOpen = open
        drawer.isHidden = !open
        notesButton.contentTintColor = open ? Theme.secondary : Theme.mark
        if let path = doc?.fileURL?.path {
            if open { UserDefaults.standard.set(true, forKey: Self.notesOpenKey(path)) } else { UserDefaults.standard.removeObject(forKey: Self.notesOpenKey(path)) }
        }
        // the page takes the keys back when the drawer that had them goes away
        if !open, window?.firstResponder === drawer.textView { window?.makeFirstResponder(editor) }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }

    /// Move the keys between the page and the notes (the drawer opens for it).
    @objc public func switchPageAndNotes(_ sender: Any?) {
        if window?.firstResponder === drawer.textView {
            window?.makeFirstResponder(editor)
        } else {
            setNotesOpen(true)
            window?.makeFirstResponder(drawer.textView)
        }
    }

    /// The selection moves to the other side: from the page to the end of the notes, or from the
    /// notes into the page at its caret. Each side undoes its own half.
    @objc public func moveSelectionAcross(_ sender: Any?) {
        let fromNotes = window?.firstResponder === drawer.textView
        let source = fromNotes ? drawer.textView : editor, target = fromNotes ? editor : drawer.textView
        let selection = source.selectedRange()
        guard selection.length > 0, !source.hasMarkedText() else { NSSound.beep(); return }
        let moved = (source.string as NSString).substring(with: selection).trimmingCharacters(in: .newlines)
        guard !moved.isEmpty else { return }
        source.apply(TextEdit(range: selection, text: "", selection: NSRange(location: selection.location, length: 0)))
        if fromNotes {
            let at = target.selectedRange()
            target.apply(TextEdit(range: at, text: moved, selection: NSRange(location: at.location + (moved as NSString).length, length: 0)))
        } else {
            setNotesOpen(true)
            let existing = target.string
            let joint = existing.isEmpty ? "" : existing.hasSuffix("\n\n") ? "" : existing.hasSuffix("\n") ? "\n" : "\n\n"
            let end = (existing as NSString).length
            let insert = joint + moved
            target.apply(TextEdit(range: NSRange(location: end, length: 0), text: insert, selection: NSRange(location: end + (insert as NSString).length, length: 0)))
        }
    }

    @objc public func toggleFocusMode(_ sender: Any?) {
        let on = !editor.focusMode
        UserDefaults.standard.set(on, forKey: Self.focusKey)
        for case let c as DocumentWindowController in NSApp.windows.compactMap(\.windowController) { c.editor.focusMode = on }
    }

    @objc public func biggerText(_ sender: Any?) { Self.setFontSize(editor.theme.fontSize + 1) }
    @objc public func smallerText(_ sender: Any?) { Self.setFontSize(editor.theme.fontSize - 1) }
    @objc public func actualSize(_ sender: Any?) { Self.setFontSize(Theme.defaultFontSize) }

    static func setFontSize(_ size: CGFloat) {
        let size = min(40, max(9, size))
        UserDefaults.standard.set(Double(size), forKey: Theme.fontSizeKey)
        let theme = Theme(fontSize: size)
        for case let c as DocumentWindowController in NSApp.windows.compactMap(\.windowController) {
            c.editor.setTheme(theme)
            c.drawer.textView.setTheme(theme)
            c.root.needsLayout = true
        }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFocusMode(_:)): item.state = editor.focusMode ? .on : .off
        case #selector(toggleNotes(_:)): item.title = notesOpen ? "Hide Notes" : "Show Notes"
        case #selector(moveSelectionAcross(_:)):
            let fromNotes = window?.firstResponder === drawer.textView
            item.title = fromNotes ? "Move Selection to Page" : "Move Selection to Notes"
            return (fromNotes ? drawer.textView : editor).selectedRange().length > 0
        default: break
        }
        return true
    }

    // MARK: window

    public func windowWillClose(_ notification: Notification) { doc?.flushNotes() }
}

extension DocumentWindowController: NSMenuItemValidation {}
