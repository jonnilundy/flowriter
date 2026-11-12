import AppKit

/// TextKit 1 layout with one line height for every line, whatever fonts a line falls back to
/// (emoji, CJK). It also draws the code block band and the inline code pill behind the text.
final class EditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var theme: Theme

    init(theme: Theme) {
        self.theme = theme
        super.init()
        delegate = self
        allowsNonContiguousLayout = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        lineFragmentRect.pointee.size.height = theme.lineHeight
        lineFragmentUsedRect.pointee.size.height = theme.lineHeight
        baselineOffset.pointee = theme.baseline
        return true
    }

    // The empty last line gets the same height as every other line.
    override func setExtraLineFragmentRect(_ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer) {
        var fragment = fragmentRect, used = usedRect
        fragment.size.height = theme.lineHeight
        used.size.height = theme.lineHeight
        super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: container)
    }

    static let codeBlockOutset: CGFloat = 10

    /// The code block bands and inline code pills in `rect` (text container coordinates), drawn
    /// with the container's origin at `origin`. The text view calls this under its text: the
    /// layout manager's own background pass is clipped to the column, and a band is wider.
    func drawCodeBackgrounds(in rect: NSRect, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let glyphs = glyphRange(forBoundingRect: rect, in: container)
        guard glyphs.length > 0 else { return }
        let chars = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        Theme.codeBackground.setFill()
        storage.enumerateAttribute(.fwCodeBlock, in: chars) { value, range, _ in
            guard value != nil else { return }
            let g = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateLineFragments(forGlyphRange: g) { fragment, _, _, _, _ in
                NSRect(x: origin.x - Self.codeBlockOutset, y: origin.y + fragment.minY,
                       width: container.size.width + 2 * Self.codeBlockOutset, height: fragment.height).fill(using: .sourceOver)
            }
        }
        let inset = max(2, ((theme.lineHeight - (theme.regular.ascender - theme.regular.descender)) / 2 - 2).rounded())
        storage.enumerateAttribute(.fwInlineCode, in: chars) { value, range, _ in
            guard value != nil else { return }
            let g = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { r, _ in
                let pill = r.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: inset)
                NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
            }
        }
    }
}

/// The page and the notes drawer are both one of these: a plain NSTextView. Its text storage is
/// the only copy of the text, undo is the system's, and Markdown shows as colour and weight on a
/// fixed line grid.
@MainActor
public final class EditorTextView: NSTextView {
    public enum Column: Equatable {
        /// A column of `Theme.columns` characters, centred in the view when that clears `reservedRight`.
        case centred
        /// The whole width of the view, inside the theme's margin (the notes drawer).
        case fill
    }

    public let highlighter: MarkdownHighlighter
    private let storage: MarkdownTextStorage
    private let editorLayout: EditorLayoutManager
    public var theme: Theme { highlighter.theme }
    public var column: Column = .centred
    /// Points at the right edge of the view the column keeps clear (a drawer over the page).
    public var reservedRight: CGFloat = 0
    /// The width the column is centred in when it is wider than the view itself (the window's
    /// width, while a drawer covers part of it). Nil: the view's own width.
    public var layoutWidth: CGFloat?
    /// The caret line stays on the vertical centre of the view.
    public var focusMode = false { didSet { if focusMode != oldValue { layoutColumn(); if focusMode { centerCaret() } } } }
    public var placeholder: String?
    /// Option-O, the one shortcut with no Command key: the window toggles the notes drawer.
    public var onToggleNotes: (() -> Void)?
    /// Option-Shift-O: the window moves the keys between the page and the notes.
    public var onSwitchNotes: (() -> Void)?
    /// This view took or gave up the keys.
    public var onFocusChange: (() -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { hasKeys = true; setNeedsCaretUpdate(); onFocusChange?() }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { hasKeys = false; setNeedsCaretUpdate(); onFocusChange?() }
        return ok
    }

    // MARK: caret

    // The caret is a layer of its own. AppKit redraws the text view for each step of its caret's
    // fade, which shows as a few coarse steps; a layer's opacity animates at the display's rate.
    public let caret = CaretView()
    private var hasKeys = false
    private var caretUpdatePending = false

    /// The caret moves at the end of this turn of the run loop: a selection can change while the
    /// text storage is mid-edit, when the layout may not be asked anything.
    private func setNeedsCaretUpdate() {
        guard !caretUpdatePending else { return }
        caretUpdatePending = true
        DispatchQueue.main.async { [weak self] in self?.updateCaret() }
    }

    /// Where the caret is drawn, in view coordinates: nil with a selection.
    public func caretRect() -> NSRect? {
        guard selectedRange().length == 0, let lm = layoutManager, let container = textContainer, let line = caretLineRect() else { return nil }
        let location = min(selectedRange().location, storage.length)
        var x = line.minX
        if storage.length > 0, !(location == storage.length && lm.extraLineFragmentTextContainer != nil) {
            if location < storage.length {
                x += lm.location(forGlyphAt: lm.glyphIndexForCharacter(at: location)).x
            } else {
                let last = lm.glyphIndexForCharacter(at: storage.length - 1)
                x = textContainerOrigin.x + lm.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container).maxX
            }
        }
        let height = (theme.regular.ascender - theme.regular.descender).rounded() + 2
        let y = line.minY + theme.baseline - theme.regular.ascender.rounded() - 1
        return backingAlignedRect(NSRect(x: x - 1, y: y, width: 2, height: height), options: .alignAllEdgesNearest)
    }

    public func updateCaret() {
        caretUpdatePending = false
        let active = hasKeys && (window?.isKeyWindow == true || AppDelegate.offScreen)
        guard active, let rect = caretRect() else { caret.isHidden = true; return }
        if caret.superview !== self { addSubview(caret) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caret.frame = rect
        caret.isHidden = false
        CATransaction.commit()
        caret.blink()
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsCaretUpdate()
    }

    public override func didChangeText() {
        super.didChangeText()
        setNeedsCaretUpdate()
    }

    /// A click below the last line puts the caret at the end of the text and stays there.
    /// AppKit's own tracking first does the same, then (as a drag) picks the nearest character
    /// in the last line that has text, so the caret jumped up a line after the click.
    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let lm = layoutManager, let container = textContainer {
            lm.ensureLayout(for: container)
            let bottom = textContainerOrigin.y + lm.usedRect(for: container).maxY
            if convert(event.locationInWindow, from: nil).y >= bottom {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: storage.length, length: 0))
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The system's caret is not drawn: `caret` stands in for it.
    public override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyChanged), name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyChanged() { setNeedsCaretUpdate() }

    private var top: CGFloat = 48
    private var left: CGFloat = 0

    public init(theme: Theme = .stored) {
        highlighter = MarkdownHighlighter(theme: theme)
        storage = MarkdownTextStorage()
        editorLayout = EditorLayoutManager(theme: theme)
        storage.addLayoutManager(editorLayout)
        let container = NSTextContainer(size: NSSize(width: theme.columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        editorLayout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        storage.highlighter = highlighter
        highlighter.isComposing = { [weak self] in self?.hasMarkedText() ?? false }
        configure()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = false
        // what you type is what the file holds
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = true
        inlinePredictionType = .no
        if #available(macOS 15.0, *) {
            mathExpressionCompletionType = .no
            writingToolsBehavior = .none
        }
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        applyTheme()
    }

    /// Fonts and colours changed (text size): style everything again.
    public func setTheme(_ theme: Theme) {
        highlighter.theme = theme
        editorLayout.theme = theme
        applyTheme()
        highlighter.restyleAll(storage)
        layoutColumn()
    }

    private func applyTheme() {
        insertionPointColor = .clear   // `caret` is the caret
        selectedTextAttributes = [.backgroundColor: Theme.selection]
        defaultParagraphStyle = highlighter.paragraphStyle(hanging: 0)
        typingAttributes = highlighter.baseAttributes
        font = theme.regular
        textColor = Theme.text
    }

    // MARK: text

    /// Replace the whole text (open, reload from disk). Not an undoable edit.
    public func load(_ text: String) {
        let selection = selectedRange()
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        undoManager?.enableUndoRegistration()
        typingAttributes = highlighter.baseAttributes
        let length = storage.length
        setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        layoutManager?.ensureLayout(for: textContainer!)
        needsDisplay = true
    }

    /// One edit through the text view's own path, so undo, the delegate and the document all see it.
    @discardableResult
    public func apply(_ edit: TextEdit) -> Bool {
        guard shouldChangeText(in: edit.range, replacementString: edit.text) else { return false }
        breakUndoCoalescing()
        storage.replaceCharacters(in: edit.range, with: edit.text)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        return true
    }

    private var plainSelection: NSRange? { hasMarkedText() ? nil : selectedRange() }

    /// NSTextView joins all typing since the last click or arrow key into one undo step, so one
    /// Undo could take back pages. A new step starts at every line break and after every pause.
    public static var undoPause: TimeInterval = 0.8
    private var lastTyped: TimeInterval = 0

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTyped > Self.undoPause, !hasMarkedText() { breakUndoCoalescing() }
        lastTyped = now
        super.insertText(string, replacementRange: replacementRange)
    }

    public override func insertNewline(_ sender: Any?) {
        breakUndoCoalescing()
        if let s = plainSelection, let edit = ListEditing.newline(in: storage.string as NSString, selection: s), apply(edit) { return }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        if let s = plainSelection, let edit = ListEditing.tab(in: storage.string as NSString, selection: s, outdent: false), apply(edit) { return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        if let s = plainSelection, let edit = ListEditing.tab(in: storage.string as NSString, selection: s, outdent: true) { apply(edit) }
    }

    public override func deleteBackward(_ sender: Any?) {
        if let s = plainSelection, let edit = ListEditing.backspace(in: storage.string as NSString, selection: s), apply(edit) { return }
        super.deleteBackward(sender)
    }

    @objc public func toggleBold(_ sender: Any?) { toggle("**") }
    @objc public func toggleItalic(_ sender: Any?) { toggle("*") }

    private func toggle(_ marker: String) {
        guard let s = plainSelection else { return }
        apply(Formatting.toggle(marker, in: storage.string as NSString, selection: s))
    }

    public override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.charactersIgnoringModifiers?.lowercased() == "o", !hasMarkedText() {
            if mods == .option, let toggle = onToggleNotes { toggle(); return }
            if mods == [.option, .shift], let jump = onSwitchNotes { jump(); return }
        }
        super.keyDown(with: event)
    }

    // MARK: column

    public override var textContainerOrigin: NSPoint { NSPoint(x: left, y: top) }

    /// Place the text column for the current view size. Called on every resize and drawer change.
    public func layoutColumn() {
        guard let container = textContainer else { return }
        let viewWidth = enclosingScrollView?.contentSize.width ?? bounds.width
        let viewHeight = enclosingScrollView?.contentSize.height ?? bounds.height
        let place: (left: CGFloat, width: CGFloat)
        switch column {
        case .centred:
            place = ColumnLayout.place(viewWidth: layoutWidth ?? viewWidth, column: theme.columnWidth, reservedRight: reservedRight, margin: theme.margin)
        case .fill:
            let padding = max(18, (2 * theme.charWidth).rounded())
            place = (padding, max(80, viewWidth - 2 * padding))
        }
        var bottom: CGFloat
        if focusMode {
            // the first and the last line can reach the centre
            top = max(24, ((viewHeight - theme.lineHeight) / 2).rounded())
            bottom = top
        } else {
            top = theme.topMargin
            bottom = column == .centred ? max(96, (viewHeight * 0.4).rounded()) : 48
        }
        left = place.left
        if container.size.width != place.width { container.size = NSSize(width: place.width, height: .greatestFiniteMagnitude) }
        // the inset is the same above and below: the origin override puts the real top in place
        textContainerInset = NSSize(width: 0, height: ((top + bottom) / 2).rounded())
        invalidateTextContainerOrigin()
        if frame.width != viewWidth { setFrameSize(NSSize(width: viewWidth, height: frame.height)) }
        sizeToFit()
        needsDisplay = true
        setNeedsCaretUpdate()
    }

    // MARK: focus mode

    public override func scrollRangeToVisible(_ range: NSRange) {
        if focusMode, range.length == 0 { centerCaret() } else { super.scrollRangeToVisible(range) }
    }

    /// The line fragment the caret is on, in view coordinates.
    public func caretLineRect() -> NSRect? {
        guard let lm = layoutManager, let container = textContainer else { return nil }
        let location = min(selectedRange().location, storage.length)
        lm.ensureLayout(for: container)
        var rect: NSRect
        if location == storage.length, lm.extraLineFragmentTextContainer != nil {
            rect = lm.extraLineFragmentRect
        } else if storage.length == 0 {
            rect = NSRect(x: 0, y: 0, width: 0, height: theme.lineHeight)
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(location, storage.length - 1))
            rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    public func centerCaret() {
        guard let clip = enclosingScrollView?.contentView, let rect = caretLineRect() else { return }
        let target = rect.midY - clip.bounds.height / 2
        let y = max(0, min(target, frame.height - clip.bounds.height)).rounded()
        guard abs(y - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: drawing

    /// A code block's band is wider than the column: redraw that much around changed text.
    public override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -EditorLayoutManager.codeBlockOutset, dy: 0), avoidAdditionalLayout: flag)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let origin = textContainerOrigin
        editorLayout.drawCodeBackgrounds(in: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), at: origin)
        super.draw(dirtyRect)
        guard storage.length == 0, let placeholder else { return }
        let y = origin.y + theme.baseline - theme.regular.ascender
        (placeholder as NSString).draw(at: NSPoint(x: origin.x, y: y), withAttributes: [.font: theme.regular, .foregroundColor: Theme.mark])
    }
}

/// The caret: a thin bar in the accent colour that fades out and in.
@MainActor
public final class CaretView: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 1
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() { layer?.backgroundColor = Theme.accent.cgColor }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Start the blink again from full: the caret is solid while it moves or text is typed.
    public func blink() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "blink")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0, 0, 1]
        fade.keyTimes = [0, 0.45, 0.6, 0.85, 1]
        let ease = CAMediaTimingFunction(name: .easeInEaseOut), hold = CAMediaTimingFunction(name: .linear)
        fade.timingFunctions = [hold, ease, hold, ease]
        fade.duration = 1.1
        fade.repeatCount = .infinity
        layer.add(fade, forKey: "blink")
    }
}

/// Where the text column sits in a view.
public enum ColumnLayout {
    /// The column stays centred in the view while that clears `reservedRight` (a drawer) by
    /// `margin`. Past that it moves left, keeping `margin` to the drawer. When it reaches `margin`
    /// from the left edge it narrows, so the text keeps the same room on both sides.
    public static func place(viewWidth: CGFloat, column: CGFloat, reservedRight: CGFloat, margin: CGFloat) -> (left: CGFloat, width: CGFloat) {
        let free = viewWidth - reservedRight
        let width = max(120, min(column, free - 2 * margin))
        let centred = (viewWidth - width) / 2
        let left = max(margin, min(centred, free - margin - width))
        return (left.rounded(.down), width)
    }
}
