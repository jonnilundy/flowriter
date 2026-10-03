import AppKit
import FloCore
import FloKit

/// Flowriter: the view toggle at the top of a document window, right of the count: M↓ (Markdown
/// marks: writing view on, reading view off). Only while the writing tools are on
/// (WritingTools.isOn). The icon sits at a fixed distance from the window's centre line, past the
/// widest count it expects ("000,000 chars"), so a count gaining a digit moves nothing and the
/// icon never moves the count. Quiet: the count's muted colour, a little stronger while on.
/// The state lives in ViewToggles (FloKit); the View menu has it (installMenu).
/// Hooks: ShellRootView (the view, one layout line), FloApp (the menu).
@MainActor
final class ViewTogglesView: FlippedView {
    let model: ShellModel
    let markdown = ViewToggleButton(icon: ViewToggleButton.markdownMark, ink: 20.5)   // 1.75 ... 22.25
    private var observers: [NSObjectProtocol] = []

    static let markdownKey = (key: "m", mods: NSEvent.ModifierFlags([.control, .command]), label: "⌃⌘M")

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        markdown.action = { ViewToggles.readingView.toggle() }
        markdown.setAccessibilityLabel("Markdown marks")
        addSubview(markdown)
        for name in [ViewToggles.didChange, WritingTools.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.superview?.needsLayout = true; self?.sync() }
            })
        }
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Clicks reach the two icons only: the drag strip and the count stay usable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        for b in [markdown] where !b.isHidden && b.frame.contains(p) { return b }
        return nil
    }

    static let buttonSize: CGFloat = 24
    /// Air between the widest expected count and an icon's ink (not its box: the two icons have
    /// different widths, so equal box gaps looked unequal).
    static let air: CGFloat = 14
    /// The widest count the icons leave room for. Chars run about five times words, so both
    /// cross their next digit together; past them the icons step out by a character.
    static let charsTemplate = "00,000 chars"

    /// Place the icon beside `count` (same frame as this view).
    func layout(around count: FlowriterCountView) {
        let s = count.style
        let half = (s.width(FlowriterCountView.gap) / 2).rounded()
        let mid = (bounds.width / 2).rounded()
        let right = max(s.width(Self.charsTemplate), s.width(count.chars))
        let b = Self.buttonSize, y = ((bounds.height - b) / 2).rounded()
        let inkM = (b - markdown.inkWidth) / 2
        markdown.frame = CGRect(x: (mid + half + right + Self.air - inkM).rounded(), y: y, width: b, height: b)
        sync()
    }

    func sync() {
        let p = model.palette_
        markdown.palette = p
        markdown.isOn = !ViewToggles.readingView
        markdown.toolTip = "\(ViewToggles.readingView ? "Writing view" : "Reading view")  \(Self.markdownKey.label)"
    }

    // MARK: menu

    static let readingTitle = "Reading View"
    static let trackingTitle = "Tracking Mode"
    static let trackingKey = (key: "t", mods: NSEvent.ModifierFlags([.control, .command]), label: "⌃⌘T")

    /// View menu: the toggle under Appearance, checked while on (the shortcut line does not list it).
    static func installMenu(in main: NSMenu) {
        guard let view = main.items.first(where: { $0.title == L("View") })?.submenu,
              !view.items.contains(where: { $0.title == readingTitle }) else { return }
        let reading = ClosureMenuItem(readingTitle, key: markdownKey.key, modifiers: markdownKey.mods, checked: ViewToggles.readingView) {
            ViewToggles.readingView.toggle()
        }
        // after the writing space's group (Appearance, Show Shortcut Hints) and its separator
        let at = view.items.first?.title == "Appearance" ? (view.items.firstIndex(where: \.isSeparatorItem).map { $0 + 1 } ?? 0) : 0
        let tracking = ClosureMenuItem(trackingTitle, key: trackingKey.key, modifiers: trackingKey.mods, checked: ViewToggles.tracking) {
            ViewToggles.tracking.toggle()
        }
        // Tracking Mode replaces upstream's Toggle Typewriter Scrolling (caret at 70%, not saved)
        if let old = view.items.first(where: { $0.title == L("Toggle Typewriter Scrolling") }) { view.removeItem(old) }
        view.insertItem(.separator(), at: at)
        view.insertItem(tracking, at: at)
        view.insertItem(reading, at: at)
        menuItem = reading
        trackingItem = tracking
        menuObserver = NotificationCenter.default.addObserver(forName: ViewToggles.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                menuItem?.state = ViewToggles.readingView ? .on : .off
                trackingItem?.state = ViewToggles.tracking ? .on : .off
            }
        }
    }
    private(set) static var menuItem: ClosureMenuItem?
    private(set) static var trackingItem: ClosureMenuItem?
    nonisolated(unsafe) private static var menuObserver: NSObjectProtocol?
}

/// One quiet icon toggle: the count's muted colour while off, a little stronger while on, the
/// text colour's secondary strength under the pointer.
@MainActor
final class ViewToggleButton: FlippedView {
    let icon: Icon
    /// Width of the drawn icon (strokes included, viewBox units), for optical spacing.
    let ink: CGFloat
    var inkWidth: CGFloat { ink * Self.iconSize / 24 }
    var palette: ShellPalette? { didSet { needsDisplay = true } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var action: (() -> Void)?
    static let iconSize: CGFloat = 18
    private(set) var hovering = false { didSet { needsDisplay = true } }

    init(icon: Icon, ink: CGFloat) {
        self.icon = icon
        self.ink = ink
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { action?(); return true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// Tracked here like IconButton: in the title-bar strip AppKit never delivers the mouse-up.
    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        var inside = true
        w.trackEvents(matching: [.leftMouseUp, .leftMouseDragged], timeout: NSEvent.foreverDuration, mode: .eventTracking) { e, stop in
            guard let e = e else { stop.pointee = true; return }
            inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if e.type == .leftMouseUp { stop.pointee = true }
        }
        if inside { action?() }
    }

    /// Off: the count's colour (fg 40%). On: fg 62%. Hover: fg 80%.
    var color: NSColor {
        guard let p = palette else { return .tertiaryLabelColor }
        if hovering { return p.textSecondary }
        return isOn ? p.tokens.fgBase.mixedWithTransparent(0.62).ns : p.textIconMuted
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = Self.iconSize
        icon.draw(in: CGRect(x: ((bounds.width - s) / 2).rounded(), y: ((bounds.height - s) / 2).rounded(), width: s, height: s), color: color, ctx: ctx)
    }

    /// The Markdown mark without its box: M and a down arrow, stroked.
    static let markdownMark = Icon(viewBox: 24, parts: [
        Icon.Part(d: "M2.5 17V7L7.5 12.5L12.5 7V17", stroke: true, cap: .round, join: .round),
        Icon.Part(d: "M18.5 7V16.5M15.5 13.5L18.5 16.5L21.5 13.5", stroke: true, cap: .round, join: .round),
    ], strokeWidth: 1.5)
}
