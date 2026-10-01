import AppKit
import FloCore
import FloKit

/// Flowriter: the selection bar. A small quiet row of words floating above a settled selection of
/// one word or more:   ghost   alt   stash   (versions)
///   ghost     ghost the selection (on ghost text it reads "revive"); the caret goes to its end
///   alt       Add Alternative: the Alternatives panel with an empty version line, focused
///   stash     move the selection to the Overflow panel; the caret stays at the cut
///   versions  only when the selection is in an alternative set: the panel on its versions,
///             Up / Down move, Return applies, Esc closes
/// Each action leaves focus where the next keystroke belongs: the page after ghost and stash, the
/// new version line after alt.
///
/// It is an overlay in the pane, above the scroll view: showing or hiding it never moves text. It
/// shows only when the selection settles (after the mouse-up, or 500 ms after the last key), holds a
/// word, the page has focus in the key window and the writing tools are on. It hides on a key, a
/// click elsewhere, a scroll, the window losing key, Esc (which also keeps it away from that range)
/// and after any action. Labels in the count's face and muted colour, no dividers; hover brings a
/// label to the text colour on a faint rounded fill. Appears in 120 ms (fade and a 2 pt rise),
/// disappears in a 100 ms fade; fade only with Reduce Motion.
/// View > Show Selection Bar, on by default, remembered (FlowriterSelectionBar).
/// Hooks: EditorPaneView.makeController (attach), FloApp (menu), AlternativesPanel (suppress).
@MainActor
final class SelectionBar {
    enum Action: String { case ghost, revive, alt, stash, versions }

    // MARK: setting

    static let defaultsKey = "FlowriterSelectionBar"
    static let menuTitle = "Show Selection Bar"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
    /// Self tests: only the selection-bar scenarios see the bar (elsewhere it would sit over the
    /// other suites' clicks and screenshots). SelfTestRunner.run sets it.
    static var selfTestOff = false

    static func setEnabled(_ on: Bool) {
        enabled = on
        if !on { all().forEach { $0.hide(animated: false) } }
    }

    /// View > Show Selection Bar (after Show Shortcut Hints).
    static func installMenu(in main: NSMenu) {
        guard FlowriterSpace.enabled, let view = main.items.first(where: { $0.title == L("View") })?.submenu,
              !view.items.contains(where: { $0.title == menuTitle }) else { return }
        let item = ClosureMenuItem(menuTitle, checked: enabled) {}
        item.keyEquivalent = ""
        item.handler = { [weak item] in
            setEnabled(!enabled)
            item?.state = enabled ? .on : .off
        }
        let at = view.items.firstIndex { $0.title == ShortcutHintsView.menuTitle }.map { $0 + 1 } ?? 0
        view.insertItem(item, at: at)
    }

    /// Every bar in the app's windows.
    static func all() -> [SelectionBar] {
        NSApp.windows.compactMap { ($0.windowController as? ShellWindowController)?.root.area }
            .flatMap { $0.panes.values.compactMap { ($0 as? EditorPaneView)?.selectionBar } }
    }

    // MARK: timing and placement

    static let keyboardSettle: TimeInterval = 0.5
    /// Air between the bar and the line it sits above (or below).
    static let lineGap: CGFloat = 8
    static let appear: TimeInterval = 0.12, disappear: TimeInterval = 0.10
    static let rise: CGFloat = 2
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: state

    let view: SelectionBarView
    private(set) weak var pane: EditorPaneView?
    private(set) weak var controller: EditorController?
    /// The bar is up (or fading in) for `shownRange`.
    private(set) var isShown = false
    private(set) var shownRange: NSRange?
    /// Esc (or an action) put it away for this range: it stays away until the selection changes.
    private(set) var dismissed: NSRange?
    private var settleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private var clipY: CGFloat = 0

    private init(pane: EditorPaneView) {
        self.pane = pane
        view = SelectionBarView(model: pane.model)
        view.bar = self
    }

    deinit {
        settleTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    /// Called from EditorPaneView.makeController (also after a theme rebuild: a new controller).
    static func attach(to c: EditorController, pane: EditorPaneView) {
        guard FlowriterSpace.enabled, !ShellSnapshot.active else { return }
        let bar = pane.selectionBar ?? SelectionBar(pane: pane)
        pane.selectionBar = bar
        bar.bind(c)
    }

    private func bind(_ c: EditorController) {
        hide(animated: false)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        controller = c
        pane?.addSubview(view)   // on top of the scroll view and the Overflow panel
        clipY = c.scrollView.contentView.bounds.minY
        let nc = NotificationCenter.default
        func on(_ name: Notification.Name, _ object: AnyObject?, _ f: @escaping @MainActor (SelectionBar, Notification) -> Void) {
            observers.append(nc.addObserver(forName: name, object: object, queue: .main) { [weak self] n in
                MainActor.assumeIsolated { if let s = self { f(s, n) } }
            })
        }
        on(NSTextView.didChangeSelectionNotification, c.textView) { s, _ in s.selectionChanged() }
        on(NSText.didChangeNotification, c.textView) { s, _ in s.hide() }
        on(NSView.boundsDidChangeNotification, c.scrollView.contentView) { s, _ in s.scrolled() }
        on(NSWindow.didResignKeyNotification, nil) { s, n in if n.object as AnyObject? === s.view.window { s.cancel() } }
        on(NSWindow.didResizeNotification, nil) { s, n in if n.object as AnyObject? === s.view.window { s.hide() } }
        on(WritingTools.didChange, nil) { s, _ in if !WritingTools.isOn { s.cancel() } }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
                // nil = eaten: `self?.handle(e) ?? e` would turn the eaten Esc back into the event
                MainActor.assumeIsolated { guard let self = self else { return e }; return self.handle(e) }
            }
        }
    }

    // MARK: events

    /// Keys and clicks in this window, before they reach a view. Esc on a shown bar is eaten.
    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let w = view.window, (e.window ?? NSApp.keyWindow) === w else { return e }
        switch e.type {
        case .keyDown:
            let plain = e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if e.keyCode == 53 && plain {
                let shown = isShown
                if isShown || settleTimer != nil { dismissed = currentRange() }
                cancel()
                return shown ? nil : e
            }
            cancel()   // a selection key re-arms the timer through the selection change
        default:
            if isShown, view.frame.contains(view.superview?.convert(e.locationInWindow, from: nil) ?? .zero) { return e }
            cancel()
        }
        return e
    }

    private func currentRange() -> NSRange? { controller.map { $0.textView.selectedRange() } }

    private func selectionChanged() {
        guard let c = controller else { return }
        let r = c.textView.selectedRange()
        if isShown, shownRange == r { return }
        cancel()
        guard r.length > 0 else { dismissed = nil; return }
        let mouseTypes: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        if let t = NSApp.currentEvent?.type, mouseTypes.contains(t) || NSEvent.pressedMouseButtons & 1 != 0 {
            afterMouseUp()
        } else {
            settleTimer = Timer.scheduledTimer(withTimeInterval: Self.keyboardSettle, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleTimer = nil; self?.tryShow() }
            }
        }
    }

    /// Mouse selections: once the mouse is up. The default run loop mode never runs inside the
    /// text view's drag loop, so this waits out the drag.
    private func afterMouseUp() {
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.settleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.settleTimer = nil; self?.afterMouseUp() }
                    }
                } else {
                    self.tryShow()
                }
            }
        }
    }

    private func scrolled() {
        guard let y = controller?.scrollView.contentView.bounds.minY else { return }
        if y != clipY { clipY = y; hide() }
    }

    /// Put it away and forget a pending show.
    func cancel() {
        settleTimer?.invalidate()
        settleTimer = nil
        hide()
    }

    /// Keep it away from `r` (the Alternatives panel gives the page its selection back).
    func suppress(_ r: NSRange) {
        dismissed = r
        cancel()
    }

    // MARK: show

    /// Why the bar may not show now (nil: it may).
    func blocker(for r: NSRange) -> String? {
        guard let c = controller, let w = view.window else { return "no editor" }
        if !Self.enabled { return "setting off" }
        if Self.selfTestOff { return "self test" }
        if !WritingTools.isOn { return "tools off" }
        if !w.isKeyWindow { return "window not key" }
        if w.firstResponder !== c.textView { return "page not focused" }
        if r.length == 0 || c.textView.selectedRanges.count != 1 { return "no single selection" }
        if r == dismissed { return "dismissed" }
        let ns = c.state.doc.string as NSString
        guard NSMaxRange(r) <= ns.length, ns.substring(with: r).rangeOfCharacter(from: .alphanumerics) != nil else { return "no word" }
        return nil
    }

    /// The actions for the selection, in order.
    func actions(for r: NSRange) -> [Action] {
        guard let c = controller else { return [] }
        var out: [Action] = []
        if let g = c.ghosts {
            out.append(GhostMath.isGhostText(g.ranges, from: r.location, to: NSMaxRange(r), in: c.state.doc.units) ? .revive : .ghost)
        }
        if c.alternatives != nil { out.append(.alt) }
        if pane?.overflow != nil { out.append(.stash) }
        if versionSet(r) != nil { out.append(.versions) }
        return out
    }

    /// The alternative set the selection starts in (or ends in).
    func versionSet(_ r: NSRange) -> AlternativeSet? {
        guard let l = controller?.alternatives else { return nil }
        return l.session.innermost(at: r.location) ?? l.session.innermost(at: NSMaxRange(r))
    }

    func tryShow() {
        guard let r = currentRange(), blocker(for: r) == nil else { return }
        let acts = actions(for: r)
        guard !acts.isEmpty, let f = frame(for: r, size: view.prepare(acts)) else { return }
        show(r, at: f)
    }

    private func show(_ r: NSRange, at f: NSRect) {
        isShown = true
        shownRange = r
        view.hovered = nil
        view.needsDisplay = true
        let animated = view.window != nil && !SelectionBarView.instant
        let start = animated && !Self.reduceMotion ? f.offsetBy(dx: 0, dy: Self.rise) : f   // flipped: +y is lower
        view.frame = start
        view.alphaValue = animated ? 0 : 1
        view.isHidden = false
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.appear
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
            if start != f { view.animator().frame = f }
        }
    }

    func hide(animated: Bool = true) {
        guard isShown else { return }
        isShown = false
        shownRange = nil
        view.hovered = nil
        guard animated, view.window != nil, !SelectionBarView.instant else { view.alphaValue = 0; view.isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.disappear
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if let s = self, !s.isShown { s.view.isHidden = true } }
        })
    }

    // MARK: geometry

    /// The selection's line boxes in pane coordinates, top to bottom (one rect per visual line part).
    func lineRects(_ r: NSRange) -> [NSRect] {
        guard let c = controller, let pane = pane, let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager,
              let a = tcm.location(tcm.documentRange.location, offsetBy: r.location), let b = tcm.location(a, offsetBy: r.length),
              let tr = NSTextRange(location: a, end: b) else { return [] }
        let o = c.textView.textContainerOrigin
        var out: [NSRect] = []
        tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, f, _, _ in
            if f.height > 0 { out.append(pane.convert(f.offsetBy(dx: o.x, dy: o.y), from: c.textView)) }
            return true
        }
        return out.sorted { $0.minY < $1.minY }
    }

    /// One visual line: the union of the parts sharing the first (or last) part's line.
    static func line(_ rects: [NSRect], first: Bool) -> NSRect? {
        guard let edge = first ? rects.first : rects.last else { return nil }
        return rects.filter { abs($0.midY - edge.midY) < edge.height / 2 }.reduce(edge) { $0.union($1) }
    }

    /// The text column in pane coordinates (where the bar is clamped).
    var column: (left: CGFloat, right: CGFloat)? {
        guard let c = controller, let pane = pane, let tc = c.textView.textContainer else { return nil }
        let x0 = c.textView.textContainerOrigin.x + c.gutterWidth, x1 = c.textView.textContainerOrigin.x + tc.size.width
        return (pane.convert(NSPoint(x: x0, y: 0), from: c.textView).x, pane.convert(NSPoint(x: x1, y: 0), from: c.textView).x)
    }

    /// The visible band of the page in pane coordinates: below the window's top strip (count and
    /// toggles), above the bottom of the scroll view.
    var visibleBand: (top: CGFloat, bottom: CGFloat)? {
        guard let c = controller, let pane = pane, let content = pane.window?.contentView else { return nil }
        let strip = pane.convert(NSPoint(x: 0, y: content.bounds.height - Metrics.chromeDragHeight), from: nil).y
        return (max(c.scrollView.frame.minY, strip), c.scrollView.frame.maxY)
    }

    /// Centred over the first line, `lineGap` above it; below the last line when there is no room
    /// above; clamped to the text column and the visible band.
    func frame(for r: NSRange, size: NSSize) -> NSRect? {
        let rects = lineRects(r)
        guard let first = Self.line(rects, first: true), let last = Self.line(rects, first: false),
              let col = column, let band = visibleBand else { return nil }
        var x = first.midX - size.width / 2
        if col.right - col.left >= size.width { x = min(max(x, col.left), col.right - size.width) }
        var y = first.minY - Self.lineGap - size.height
        if y < band.top { y = last.maxY + Self.lineGap }
        y = min(max(y, band.top), band.bottom - size.height)
        let scale = pane?.window?.backingScaleFactor ?? 2
        return NSRect(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale, width: size.width, height: size.height)
    }

    // MARK: actions

    func run(_ a: Action) {
        guard let c = controller, let pane = pane, let r = currentRange(), r.length > 0 else { return }
        dismissed = r
        cancel()
        let w = view.window
        switch a {
        case .ghost, .revive:
            _ = c.ghosts?.toggle()
            w?.makeFirstResponder(c.textView)
            c.textView.setSelectedRange(NSRange(location: min(NSMaxRange(r), c.state.doc.length), length: 0))
        case .stash:
            _ = pane.overflow?.stashSelection()
            w?.makeFirstResponder(c.textView)
        case .alt:
            AlternativesAttach.addAlternative(pane.superview as? EditorAreaView)
        case .versions:
            guard let l = c.alternatives, let s = versionSet(r), let area = pane.superview as? EditorAreaView else { return }
            AlternativesAttach.panel(area).openVersions(s, in: l)
        }
    }
}

/// The bar itself: a 26 pt rounded row, the page surface lifted a touch, a hairline, labels only.
@MainActor
final class SelectionBarView: FlippedView {
    weak var bar: SelectionBar?
    let model: ShellModel
    /// Tests: no fade (frames and screenshots right away).
    static var instant = false

    static let height: CGFloat = 26
    static let radius: CGFloat = 7
    static let padX: CGFloat = 10
    static let gapX: CGFloat = 14
    static let hoverHeight: CGFloat = 18
    static let hoverInset: CGFloat = 5

    private(set) var items: [(action: SelectionBar.Action, rect: NSRect)] = []
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        alphaValue = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Selection actions")
    }
    required init?(coder: NSCoder) { fatalError() }

    static func label(_ a: SelectionBar.Action) -> String { a.rawValue }

    var palette: ShellPalette { model.palette_ }
    var style: TextStyle { TextStyle(font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: palette.textIconMuted) }

    /// Lay out the labels for `actions`; returns the bar's size.
    func prepare(_ actions: [SelectionBar.Action]) -> NSSize {
        let s = style
        var x = Self.padX
        items = actions.map { a in
            let w = ceil(s.width(Self.label(a)))
            defer { x += w + Self.gapX }
            return (a, NSRect(x: x, y: 0, width: w, height: Self.height))
        }
        let width = (items.last?.rect.maxX ?? 0) + Self.padX
        needsDisplay = true
        return NSSize(width: width, height: Self.height)
    }

    var labels: [String] { items.map { Self.label($0.action) } }

    /// Fill and line: the page's surface, lifted with the card token in dark mode (light mode's card
    /// is transparent: the hairline and the shadow lift it); the hairline is the subtle line token.
    var colors: (fill: NSColor, line: NSColor) {
        let t = palette.tokens
        let base = t.bgBase.ns.withAlphaComponent(1)
        let card = t.surfaceCard
        let fill = card.a > 0 ? (base.blended(withFraction: CGFloat(card.a), of: RGBA(r: card.r, g: card.g, b: card.b, a: 1).ns) ?? base) : base
        return (fill, t.lineSubtler.ns)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hair = 1 / (window?.backingScaleFactor ?? 2)
        let col = colors
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: hair / 2, dy: hair / 2), xRadius: Self.radius, yRadius: Self.radius)
        col.fill.setFill()
        shape.fill()
        col.line.setStroke()
        shape.lineWidth = hair
        shape.stroke()
        let s = style, p = palette
        for (i, it) in items.enumerated() {
            let hot = i == hovered
            if hot {
                p.tokens.fgBase.mixedWithTransparent(p.mode == .dark ? 0.08 : 0.05).ns.setFill()
                NSBezierPath(roundedRect: hoverRect(it.rect), xRadius: 5, yRadius: 5).fill()
            }
            var st = s
            if hot { st.color = p.textPrimary }
            st.draw(Self.label(it.action), x: it.rect.minX, lineTop: 0, lineHeight: Self.height, in: ctx)
        }
    }

    func hoverRect(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX - Self.hoverInset, y: ((Self.height - Self.hoverHeight) / 2).rounded(), width: r.width + 2 * Self.hoverInset, height: Self.hoverHeight)
    }

    /// A very soft shadow in light mode; none in dark mode (it only muddies a dark page).
    override func layout() {
        super.layout()
        updateShadow()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadow()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
        needsDisplay = true
    }
    private func updateShadow() {
        guard let l = layer else { return }
        l.masksToBounds = false
        if palette.mode == .dark {
            l.shadowOpacity = 0
        } else {
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.07
            l.shadowRadius = 5
            l.shadowOffset = CGSize(width: 0, height: l.isGeometryFlipped ? 1.5 : -1.5)
            l.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        }
    }

    // MARK: mouse

    func index(at p: NSPoint) -> Int? { items.firstIndex { hoverRect($0.rect).insetBy(dx: -Self.gapX / 2 + Self.hoverInset, dy: -4).contains(p) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bar?.isShown == true else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Tracked here: the run happens on a mouse-up over the same label.
    override func mouseDown(with event: NSEvent) {
        guard let w = window, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        var up: NSPoint?
        w.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: NSEvent.foreverDuration, mode: .eventTracking) { e, stop in
            guard let e = e else { stop.pointee = true; return }
            let p = convert(e.locationInWindow, from: nil)
            hovered = index(at: p)
            if e.type == .leftMouseUp { up = p; stop.pointee = true }
        }
        if let p = up, index(at: p) == i { bar?.run(items[i].action) }
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}
