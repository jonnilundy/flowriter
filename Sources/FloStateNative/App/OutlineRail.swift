import AppKit
import FloCore
import FloKit

// MARK: - Outline rail (section-rail.tsx)
//
// The rail is the stack of ticks at the page's right edge. Hovering it opens the outline popup: the
// document's headings as rows. Flowriter changes to the upstream popup:
//   - it fades and scales in (180 ms) and out (130 ms) with the app's ease-out curve; a show cut
//     short by a hide (and the reverse) turns round from where it is, never from the end; with Reduce
//     Motion on it only fades;
//   - a row under the pointer has a soft highlight and the pointing hand;
//   - a click on a row (or a tick) puts the caret on that heading, scrolls it into view, gives the
//     page focus and closes the popup (it is a hover popup: it has no reason to stay once you went).

enum RailGeometry {
    static let inactiveWidth: CGFloat = 10, activeWidth: CGFloat = 20, tickGap: CGFloat = 6, edgeInset: CGFloat = 12
    static let popoverWidth: CGFloat = 260

    /// Tick rects in the editor-area coordinate space (width `w`, height `h`).
    static func ticks(count: Int, active: Int?, areaWidth w: CGFloat, areaHeight h: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let stack = CGFloat(count) + CGFloat(count - 1) * tickGap
        let right = w - Metrics.scrollbarGutter - edgeInset
        let top = h / 2 - stack / 2
        return (0..<count).map { i in
            let tw = i == active ? activeWidth : inactiveWidth
            return CGRect(x: right - 2 - tw, y: top + CGFloat(i) * (1 + tickGap), width: tw, height: 1)
        }
    }

    /// The hover zone (34px wide, stack tall, vertically centred).
    static func zone(count: Int, areaWidth w: CGFloat, areaHeight h: CGFloat) -> CGRect {
        let stack = CGFloat(count) + CGFloat(max(0, count - 1)) * tickGap
        return CGRect(x: w - Metrics.scrollbarGutter - edgeInset - activeWidth - 2, y: h / 2 - stack / 2, width: edgeInset + activeWidth + 2, height: stack)
    }
}

/// The popup's row geometry in the list's (flipped) coordinates: 13 pt text on a 19.5 pt line, 4 pt
/// between lines, 12 pt of air above the first. A row's hit band runs from the middle of the gap
/// above it to the middle of the gap below, so the bands touch and the pointer never lands between
/// two rows.
enum OutlineRows {
    static let top: CGFloat = 12, textHeight: CGFloat = 19.5, gap: CGFloat = 4, highlightInset: CGFloat = 6
    static var pitch: CGFloat { textHeight + gap }

    static func rowTop(_ i: Int) -> CGFloat { top + CGFloat(i) * pitch }

    /// The list's height for `count` rows (12 pt of air above and below).
    static func contentHeight(count: Int) -> CGFloat {
        CGFloat(count) * textHeight + CGFloat(max(0, count - 1)) * gap + 2 * top
    }

    /// The row whose band holds `y`, or nil above the first and below the last.
    static func index(atY y: CGFloat, count: Int) -> Int? {
        let r = y - top + gap / 2
        guard r >= 0 else { return nil }
        let i = Int(r / pitch)
        return i < count ? i : nil
    }

    /// The hit band of row `i`, full width.
    static func band(_ i: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: rowTop(i) - gap / 2, width: width, height: pitch)
    }

    /// The soft highlight behind row `i`.
    static func highlight(_ i: Int, width: CGFloat) -> CGRect {
        CGRect(x: highlightInset, y: rowTop(i) - 1, width: width - 2 * highlightInset, height: textHeight + 2)
    }
}

/// Where a click on a heading puts the caret.
enum HeadingJump {
    /// Where a jumped-to heading lands, in points under the page's top edge: clear of the writing
    /// space's top strip (the file name and the count, 56 pt); upstream's 24 pt elsewhere.
    @MainActor static var landing: CGFloat { FlowriterSpace.enabled ? 72 : 24 }

    /// The start of the heading's text: past the `#` marks and the spaces after them. `h.pos` is
    /// the UTF-16 offset of the line start; a stale heading (the text got shorter) is clamped.
    static func caret(for h: DocumentHeading, in text: NSString) -> Int {
        let n = text.length
        var i = min(max(0, h.pos), n)
        while i < n, text.character(at: i) == 0x23 { i += 1 }
        while i < n, text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1 }
        return i
    }
}

/// The popup's motion: fade plus a small scale about the popup's edge next to the rail. The model
/// values (`alphaValue`, an identity transform) jump to the target at once; a Core Animation
/// animation covers the way there. A new run starts from what is on screen (the presentation layer)
/// and a stale completion is dropped, so a show cut short by a hide (and the reverse) turns round
/// without a jump and never leaves a half-visible view behind.
enum OutlineMotion {
    static var animations = true
    static var reduceMotionOverride: Bool?
    static var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let showDuration: CFTimeInterval = 0.18, hideDuration: CFTimeInterval = 0.13
    static let restScale: CGFloat = 0.96
    /// Stretches every run (tests slow the motion down to photograph a frame in the middle of it).
    static var durationScale = 1.0
    static let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)   // ease-out, as the panels

    static func transform(scale s: CGFloat, anchorX: CGFloat) -> CATransform3D {
        CATransform3DMakeAffineTransform(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: anchorX * (1 - s), ty: 0))
    }
}

@MainActor
final class OutlineTransition {
    unowned let view: NSView
    private var generation = 0
    /// True from the start of a run until its animation ends (or is replaced).
    private(set) var isRunning = false
    init(view: NSView) { self.view = view }

    /// Go to `alpha` (0 or 1). `scales`: also scale between `OutlineMotion.restScale` and 1 about the
    /// point `anchorX` points right of the view's centre. `completion` runs once the run ended and
    /// was not replaced by a later run.
    func run(alpha target: CGFloat, scales: Bool, anchorX: CGFloat, duration: CFTimeInterval, completion: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        guard let layer = view.layer else { view.alphaValue = target; isRunning = false; completion?(); return }
        let inFlight = !(layer.animationKeys() ?? []).isEmpty
        let from: CATransform3D?
        let startOpacity: Float
        if inFlight, let p = layer.presentation() { startOpacity = p.opacity; from = p.transform }
        else { startOpacity = layer.opacity; from = nil }
        layer.removeAllAnimations()
        view.alphaValue = target
        let dist = abs(Float(target) - startOpacity)
        guard OutlineMotion.animations, view.window != nil, dist > 0.01 else { isRunning = false; completion?(); return }
        let d = duration * OutlineMotion.durationScale * Double(max(0.35, dist))
        let curve = OutlineMotion.curve
        func animation(_ key: String, _ a: Any, _ b: Any) -> CABasicAnimation {
            let x = CABasicAnimation(keyPath: key)
            x.fromValue = a; x.toValue = b; x.duration = d; x.timingFunction = curve
            return x
        }
        CATransaction.begin()
        isRunning = true
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.generation == gen else { return }
                self.isRunning = false
                completion?()
            }
        }
        layer.add(animation("opacity", startOpacity, Float(target)), forKey: "outline.opacity")
        if scales {
            // static states: scale rest at opacity 0, 1 at opacity 1, in between by the fade
            let s = OutlineMotion.restScale + (1 - OutlineMotion.restScale) * CGFloat(startOpacity)
            let begin = from ?? OutlineMotion.transform(scale: s, anchorX: anchorX)
            let end = OutlineMotion.transform(scale: target > 0.5 ? 1 : OutlineMotion.restScale, anchorX: anchorX)
            layer.add(animation("transform", NSValue(caTransform3D: begin), NSValue(caTransform3D: end)), forKey: "outline.transform")
        }
        CATransaction.commit()
    }

    /// The opacity on screen now (the animation's current value while one runs).
    var shownOpacity: CGFloat { CGFloat(view.layer?.presentation()?.opacity ?? view.layer?.opacity ?? Float(view.alphaValue)) }
    /// The scale on screen now.
    var shownScale: CGFloat { (view.layer?.presentation()?.transform ?? view.layer?.transform).map { CGFloat($0.m11) } ?? 1 }
}

final class OutlineRailView: FlippedView {
    let model: ShellModel   // strong: AppKit can still lay a view out after its window controller (the other owner) is gone
    var headings: [DocumentHeading] = [] { didSet { strip.needsDisplay = true } }
    var activeIndex: Int? { didSet { if oldValue != activeIndex { strip.needsDisplay = true; popover?.listChanged() } } }
    /// A heading was chosen (a row or a tick was clicked).
    var onSelect: ((DocumentHeading) -> Void)?
    private(set) var popover: OutlinePopoverView?
    let strip: TickStripView
    private let stripTransition: OutlineTransition

    init(model: ShellModel) {
        self.model = model
        strip = TickStripView()
        stripTransition = OutlineTransition(view: strip)
        super.init(frame: .zero)
        strip.rail = self
        strip.autoresizingMask = [.width, .height]
        addSubview(strip)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Open or opening: a popup that is on its way out does not count.
    var isOpen: Bool { popover.map { $0.phase != .hiding } ?? false }

    var tickRects: [CGRect] { RailGeometry.ticks(count: headings.count, active: activeIndex, areaWidth: bounds.width, areaHeight: bounds.height) }

    override func layout() {
        super.layout()
        strip.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let p = popover, p.phase != .hiding, p.frame.contains(local) { return p.hitTest(convert(local, to: p.superview)) ?? p }
        return RailGeometry.zone(count: headings.count, areaWidth: bounds.width, areaHeight: bounds.height).contains(local) && !isOpen ? self : nil
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        let z = RailGeometry.zone(count: headings.count, areaWidth: bounds.width, areaHeight: bounds.height)
        if !headings.isEmpty { addTrackingArea(NSTrackingArea(rect: z, options: [.mouseEnteredAndExited, .activeAlways], owner: self)) }
    }
    override func mouseEntered(with event: NSEvent) { openPopover() }
    override func mouseExited(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let pop = popover, pop.frame.contains(p) { return }
        closePopover()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}   // a tick acts on mouse up
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tickRects.firstIndex(where: { $0.insetBy(dx: 0, dy: -3).contains(p) }) { choose(headings[i]) }
    }

    /// A click on a heading: jump there, then the popup has done its job.
    func choose(_ h: DocumentHeading) {
        onSelect?(h)
        closePopover()
    }

    func openPopover() {
        guard !headings.isEmpty else { return }
        if let pop = popover {
            // on its way out: turn round from where it is
            if pop.phase == .hiding { pop.present(); fadeTicks(away: true) }
            return
        }
        let pop = OutlinePopoverView(rail: self)
        popover = pop
        addSubview(pop)
        pop.layoutFor(bounds)
        pop.present()
        fadeTicks(away: true)
    }

    func closePopover() {
        guard let pop = popover, pop.phase != .hiding else { return }
        pop.dismiss { [weak self, weak pop] in
            guard let self = self, let pop = pop, self.popover === pop else { return }
            pop.removeFromSuperview()
            self.popover = nil
        }
        fadeTicks(away: false)
    }

    /// The ticks sit under the popup: they fade out as it comes in and back as it goes.
    private func fadeTicks(away: Bool) {
        stripTransition.run(alpha: away ? 0 : 1, scales: false, anchorX: 0, duration: away ? OutlineMotion.showDuration : OutlineMotion.hideDuration)
    }

    /// The opacity the ticks are drawn with now (0 while the popup is fully in).
    var tickOpacity: CGFloat { stripTransition.shownOpacity }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isOpen { closePopover(); return }
        super.keyDown(with: event)
    }

    func headingMenu(_ h: DocumentHeading) -> NSMenu {
        ShellMenus.menu([ClosureMenuItem(L("Copy heading link")) { [weak model] in model?.copyToPasteboard(DocumentHeadings.headingLink(h)) }])
    }

    func dump() -> [[String: Any]] {
        tickRects.enumerated().map { i, r in
            ["rect": convertToRootRect(r).dumpArray, "title": headings[i].text, "active": i == activeIndex]
        }
    }

    /// The ticks: their own layer, so they can fade against the popup.
    final class TickStripView: FlippedView {
        weak var rail: OutlineRailView?
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let rail = rail else { return }
            let c = rail.model.palette_.textPrimary
            // ScrollFade: a 70vh window centred on the rail, 48px fades at both ends.
            let vh = window?.contentView?.bounds.height ?? bounds.height
            let top = bounds.height / 2 - vh * 0.35, bottom = bounds.height / 2 + vh * 0.35
            for (i, r) in rail.tickRects.enumerated() {
                let y = r.midY
                guard y >= top, y <= bottom else { continue }
                let fade = min(1, (y - top) / 48) * min(1, (bottom - y) / 48)
                c.withAlphaComponent((i == rail.activeIndex ? 1 : 0.35) * fade).setFill()
                r.fill()
            }
        }
    }
}

/// The outline popover: 260px card, rows 13px/1.5, gap 4, indent by level.
final class OutlinePopoverView: FlippedView {
    enum Phase { case showing, shown, hiding }

    unowned let rail: OutlineRailView
    let scroll = NSScrollView()
    let list = FlippedView()
    private(set) var phase: Phase = .showing
    private(set) var hovered: Int? { didSet { if hovered != oldValue { drawer.needsDisplay = true } } }
    private var transition: OutlineTransition!
    private var scrollObserver: NSObjectProtocol?

    init(rail: OutlineRailView) {
        self.rail = rail
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0   // present() brings it in
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        transition = OutlineTransition(view: self)
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = false
        scroll.documentView = list
        addSubview(scroll)
        list.addSubview(drawer)
        // rows move under a still pointer when the list scrolls
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHoverFromPointer() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = scrollObserver { NotificationCenter.default.removeObserver(o) } }
    private(set) lazy var drawer = ListDrawer(owner: self)

    var rowStyle: TextStyle { TextStyle(font: UIFonts.ui(rail.model.values), color: rail.model.palette_.textMuted, kern: -0.13) }
    var indent: CGFloat { CGFloat(rail.model.values.editorOutlineIndentPerLevel) }

    // MARK: motion

    /// The point the popup scales about, in its own coordinates relative to its centre: its right
    /// edge (the side next to the rail's ticks).
    private var anchorX: CGFloat { RailGeometry.popoverWidth / 2 }

    func present() {
        phase = .showing
        transition.run(alpha: 1, scales: !OutlineMotion.reduceMotion, anchorX: anchorX, duration: OutlineMotion.showDuration) { [weak self] in
            self?.phase = .shown
        }
        if !transition.isRunning { phase = .shown }
    }

    /// Fade out; `completion` runs when it is gone (the rail then removes it).
    func dismiss(completion: @escaping () -> Void) {
        phase = .hiding
        hovered = nil
        transition.run(alpha: 0, scales: !OutlineMotion.reduceMotion, anchorX: anchorX, duration: OutlineMotion.hideDuration, completion: completion)
    }

    /// The opacity on screen now.
    var shownOpacity: CGFloat { transition.shownOpacity }
    var shownScale: CGFloat { transition.shownScale }
    var isAnimating: Bool { transition.isRunning }

    // MARK: layout and drawing

    func layoutFor(_ area: CGRect) {
        let n = rail.headings.count
        let contentH = OutlineRows.contentHeight(count: n)
        let maxH = (window?.contentView?.bounds.height ?? area.height) * 0.7
        let h = min(maxH, contentH)
        frame = CGRect(x: area.width - Metrics.scrollbarGutter - RailGeometry.edgeInset - RailGeometry.popoverWidth - 4,
                       y: area.height / 2 - h / 2, width: RailGeometry.popoverWidth, height: h)
        scroll.frame = bounds
        list.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentH)
        drawer.frame = list.bounds
        // open scrolled so the active row is centred
        if let a = rail.activeIndex {
            let target = max(0, min(contentH - h, OutlineRows.rowTop(a) - h / 2 + OutlineRows.textHeight / 2))
            scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
        }
        window?.invalidateCursorRects(for: drawer)
    }

    /// The active heading changed.
    func listChanged() { drawer.needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let p = rail.model.palette_
        p.surfaceCard.setFill(); bounds.fill()
        p.cardUnderlay.setFill(); bounds.fill(using: .sourceOver)
        p.lineSubtler.setStroke()
        let path = roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5), 15.5)
        path.lineWidth = 1
        path.stroke()
    }

    /// The row under a point in the popup's own coordinates (the list's, through the scroll).
    func rowIndex(at p: CGPoint) -> Int? {
        let inList = list.convert(p, from: self)
        return OutlineRows.index(atY: inList.y, count: rail.headings.count)
    }

    /// The row under the pointer now (after a scroll, with no mouse event).
    private func refreshHoverFromPointer() {
        guard phase != .hiding, let w = window else { return }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        hovered = bounds.contains(p) ? rowIndex(at: p) : nil
    }

    /// Hover as a real mouse move sets it (the tests drive it with a move event).
    func setHover(from event: NSEvent) {
        guard phase != .hiding else { return }
        hovered = rowIndex(at: convert(event.locationInWindow, from: nil))
    }

    /// The highlight rect of the hovered row in the popup's coordinates (nil: none).
    var hoverRect: CGRect? {
        guard let i = hovered else { return nil }
        return list.convert(OutlineRows.highlight(i, width: list.bounds.width), to: self)
    }

    /// The pointing hand over every row's band (list coordinates), the arrow elsewhere.
    var cursorRects: [(rect: CGRect, cursor: NSCursor)] {
        rail.headings.indices.map { (OutlineRows.band($0, width: list.bounds.width), NSCursor.pointingHand) }
    }

    final class ListDrawer: FlippedView {
        unowned let owner: OutlinePopoverView
        init(owner: OutlinePopoverView) { self.owner = owner; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let p = owner.rail.model.palette_
            for (i, h) in owner.rail.headings.enumerated() {
                var s = owner.rowStyle
                let isActive = i == owner.rail.activeIndex
                if i == owner.hovered {
                    // a soft rounded highlight (the sidebar rows' hover token); the shown section keeps its blue
                    p.surfaceSubtle.setFill()
                    roundedPath(OutlineRows.highlight(i, width: bounds.width), 7).fill()
                }
                if isActive { s.color = p.accent } else if i == owner.hovered { s.color = p.textPrimary }
                let x = 16 + CGFloat(max(0, h.level - 2)) * owner.indent
                s.draw(h.text, x: x, lineTop: OutlineRows.rowTop(i), lineHeight: OutlineRows.textHeight, maxWidth: bounds.width - 16 - x, in: ctx)
            }
        }

        override func resetCursorRects() {
            for c in owner.cursorRects { addCursorRect(c.rect, cursor: c.cursor) }
        }

        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { owner.setHover(from: event) }
        override func mouseMoved(with event: NSEvent) { owner.setHover(from: event) }
        override func mouseExited(with event: NSEvent) {
            owner.setHoverNone()
            let rail = owner.rail
            let p = rail.convert(event.locationInWindow, from: nil)
            if !RailGeometry.zone(count: rail.headings.count, areaWidth: rail.bounds.width, areaHeight: rail.bounds.height).contains(p)
                && !owner.frame.contains(p) { rail.closePopover() }
        }
        override func mouseDown(with event: NSEvent) {}   // the click acts on mouse up
        override func mouseUp(with event: NSEvent) {
            guard owner.phase != .hiding, let i = owner.rowIndex(at: owner.convert(event.locationInWindow, from: nil)) else { return }
            owner.rail.choose(owner.rail.headings[i])
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard owner.phase != .hiding, let i = owner.rowIndex(at: owner.convert(event.locationInWindow, from: nil)) else { return nil }
            return owner.rail.headingMenu(owner.rail.headings[i])
        }
    }

    fileprivate func setHoverNone() { hovered = nil }
}
