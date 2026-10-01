import AppKit
import FloCore
import FloKit

/// Flowriter: the document's file name at the top left of the compact window, right of the traffic
/// lights and on their centre line ("letter-to-a-friend", no ".md"). Same font and muted colour as the
/// count. It truncates with "…" before it reaches the count and never moves the count or the M↓
/// toggle (they stay centred on the window). Full windows show the title in a tab: no name there.
/// Hover: the full path (home as ~) and the chrome hover fill. Click: Show in Finder, Copy Path,
/// Rename… (the app's rename prompt, ShellMenus.promptRename).
/// Save state, quiet: a 4 pt dot right after the name while there are unsaved edits; it fades
/// (150 ms) once they are on disk. The autosave writes each edit at once, in the keystroke that made
/// it (SaveEngine's throttle state is dropped after every write, and the writer is synchronous), so
/// the dot never shows while saves work: it shows when a save failed and stays until one lands. The
/// dot's room is always kept, so showing it moves nothing. A failed save also turns the name red
/// and the tooltip says why.
/// Hooks: ShellRootView (the view, one layout line), ShellWindowController.flush (refresh, window
/// title and representedURL).
@MainActor
final class FileNameView: FlippedView {
    let model: ShellModel
    private(set) var path: String?
    private(set) var name = ""
    private(set) var dirty = false
    private(set) var saveError: String?
    /// The dot is showing (or fading in); false once its fade-out starts.
    private(set) var dotShown = false
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    let dot = CALayer()
    /// Width the name may take (set by `layout(around:)`).
    private var maxTextWidth: CGFloat = 0

    static let fade: CFTimeInterval = 0.15
    static let dotSize: CGFloat = 4
    static let dotGap: CGFloat = 5
    /// Hover fill padding around the text (and the dot's room).
    static let padX: CGFloat = 6
    static let boxHeight: CGFloat = 24
    /// Air between the name's box and the count's widest expected words.
    static let air: CGFloat = 16
    /// The widest words count the name leaves room for (like ViewTogglesView.charsTemplate).
    static let wordsTemplate = "00,000 words"

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        dot.cornerRadius = Self.dotSize / 2
        dot.opacity = 0
        dot.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(dot)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    var style: TextStyle {
        let p = model.palette_
        let color: NSColor = saveError != nil ? p.saveError : hovering ? WritingToolsSwitch.hoverColor(p) : p.textIconMuted
        return TextStyle(font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: color)
    }

    /// The file name as shown: the last path component without ".md".
    static func displayName(_ path: String) -> String {
        let n = (path as NSString).lastPathComponent
        return n.lowercased().hasSuffix(".md") ? String(n.dropLast(3)) : n
    }

    /// The path with the home folder as ~.
    static func shortPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// The text as drawn (truncated with "…" to fit) and its width.
    var shownWidth: CGFloat { min(style.width(name), max(0, maxTextWidth)) }

    /// Where the dot sits, in this view.
    var dotRect: CGRect {
        CGRect(x: Self.padX + shownWidth + Self.dotGap, y: ((bounds.height - Self.dotSize) / 2).rounded(), width: Self.dotSize, height: Self.dotSize)
    }

    // MARK: state

    func refresh() {
        let f = model.editor.activeFilePath.flatMap { p in model.editor.file(p).map { (p, $0) } }
        let newPath = f?.0
        if newPath != path {
            path = newPath
            name = newPath.map(Self.displayName) ?? ""
            setDot(false, animated: false)
            superview?.needsLayout = true
        }
        guard let (p, file) = f else { return }
        dirty = file.isDirty && !file.isLoading
        let error = file.saveError
        if error != saveError { saveError = error; needsDisplay = true }
        toolTip = error.map { "Couldn’t save: \($0)\n\(Self.shortPath(p))" } ?? Self.shortPath(p)
        setAccessibilityLabel("\(name), \(Self.shortPath(p))")
        setAccessibilityValue(error != nil ? "not saved" : dirty ? "unsaved edits" : "saved")
        setDot(dirty, animated: !dirty)   // appears at once, fades out
    }

    private func setDot(_ on: Bool, animated: Bool) {
        if on == dotShown && dot.opacity == (on ? 1 : 0) { return }
        dotShown = on
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(Self.fade)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        dot.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    // MARK: layout

    /// Place the name beside the traffic lights, clear of `count` (same row as this view's parent).
    func layout(around count: FlowriterCountView, in root: NSView) {
        let s = count.style
        let half = (s.width(FlowriterCountView.gap) / 2).rounded()
        let words = max(s.width(Self.wordsTemplate), s.width(count.words))
        let countLeft = count.frame.minX + (count.bounds.width / 2).rounded() - half - words
        // the traffic lights, in root points (fallback: the count's line)
        var left: CGFloat = 92 - Self.padX, mid = count.frame.midY
        if let w = window, let zoom = w.standardWindowButton(.zoomButton), let close = w.standardWindowButton(.closeButton),
           zoom.superview != nil, !zoom.isHidden {
            let z = root.convert(zoom.convert(zoom.bounds, to: nil), from: nil)
            let c = root.convert(close.convert(close.bounds, to: nil), from: nil)
            left = (z.maxX + Self.air - Self.padX).rounded()
            mid = c.midY
        }
        let right = countLeft - Self.air
        let room = Self.dotGap + Self.dotSize
        maxTextWidth = max(0, right - left - Self.padX * 2 - room)
        let width = Self.padX * 2 + min(style.width(name), maxTextWidth) + room
        let h = Self.boxHeight
        frame = CGRect(x: left, y: (mid - h / 2).rounded(), width: name.isEmpty ? 0 : width, height: h)
        let p = model.palette_
        dot.backgroundColor = p.textIconMuted.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = dotRect
        CATransaction.commit()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !name.isEmpty else { return }
        if hovering { model.palette_.surfaceSubtle.setFill(); roundedPath(bounds, 6).fill() }
        let lh: CGFloat = 16
        style.draw(name, x: Self.padX, lineTop: (bounds.height - lh) / 2, lineHeight: lh, maxWidth: maxTextWidth, in: ctx)
    }

    // MARK: mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || name.isEmpty ? nil : super.hitTest(point) }
    /// Native menus open on mouse down (and the title-bar strip never delivers the mouse-up).
    override func mouseDown(with event: NSEvent) { showMenu() }
    override func accessibilityPerformPress() -> Bool { showMenu(); return true }

    func menu() -> NSMenu? {
        guard let p = path else { return nil }
        let model = model
        var items: [NSMenuItem] = [
            ClosureMenuItem("Show in Finder") { model.revealInFinder(p) },
            ClosureMenuItem("Copy Path") { model.copyToPasteboard(p) },
        ]
        if let entry = WorkspaceFS.fileEntry(p, extensions: model.settings.supportedExtensions) {
            items.append(.separator())
            items.append(ClosureMenuItem("Rename…") { ShellMenus.promptRename(model: model, entry: entry) })
        }
        return ShellMenus.menu(items)
    }

    func showMenu() {
        guard let m = menu() else { return }
        hovering = true
        m.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.maxY + 4), in: self)
        hovering = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }
}

extension FileNameView {
    /// Mission Control, the Window menu and the Dock name the window by its file; representedURL
    /// gives the window its document (the title bar text itself stays hidden). Full windows keep
    /// the tab title.
    static func titleWindow(_ window: NSWindow?, _ model: ShellModel) {
        guard let w = window else { return }
        let p = model.editor.activeFilePath
        let url = p.map { URL(fileURLWithPath: $0) }
        if w.representedURL != url { w.representedURL = url }
        if model.isCompact, let p = p { let t = displayName(p); if w.title != t { w.title = t } }
    }
}

extension ShellPalette {
    /// A save failed: the red the tab strip's error dot uses.
    var saveError: NSColor { NSColor(srgbRed: 1, green: 0x5f / 255.0, blue: 0x57 / 255.0, alpha: 1) }
}
