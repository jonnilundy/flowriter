import AppKit
import FloCore
import FloKit

/// Flowriter: the quiet shortcut line at the bottom centre of a document window, for memory:
///   ⌥G ghost      ⌥A alternative      ⌥O overflow
/// While the ⌘K leader is waiting for its letter (WritingKeys.swift) the line shows the leader
/// letters instead, in the same band and font:
///   g ghost      a alternative      o overflow      s stash      v versions      l link      r recent
/// SF Mono 11 in the count's muted colour. It fades out on a key in the page and back after 2 s
/// without one (opacity only, ease-out, 150 / 200 ms; instant with Reduce Motion). The pane keeps
/// its band free (EditorPaneView.scrollBox ends above it), so text never runs under it. A narrow
/// band drops hints from the right; the line never wraps. View > Show Shortcut Hints, remembered.
///
/// Other features drive it through `HintStrip` (below): show or hide it, add their own hints.

/// The shortcut line's API for other features.
///   HintStrip.setVisible(false)                       hide it (e.g. tools off); not stored
///   HintStrip.setVisible(true)                        show it again (if View > Show Shortcut Hints is on)
///   HintStrip.register(keys: "⌃⌘M", label: "marks")   add a hint (same label: replaced); after the
///                                                     built-in three unless `after:` names a label
///   HintStrip.unregister(label: "marks")              remove one
///   HintStrip.items / isVisible / isShown             read the state
/// The line shows when `isVisible` (this gate) and the user's View menu setting are both on. Hints
/// drop from the right when the window is narrow, so put the most useful ones first.
@MainActor
enum HintStrip {
    struct Item: Equatable { var keys: String; var label: String }
    static let builtIn: [Item] = [
        Item(keys: "⌥G", label: "ghost"), Item(keys: "⌥A", label: "alternative"), Item(keys: "⌥O", label: "overflow"),
    ]
    /// The letters after ⌘K, in the order the leader line shows them.
    static let leaderItems: [Item] = [
        Item(keys: "g", label: "ghost"), Item(keys: "a", label: "alternative"), Item(keys: "o", label: "overflow"),
        Item(keys: "s", label: "stash"), Item(keys: "v", label: "versions"), Item(keys: "l", label: "link"), Item(keys: "r", label: "recent"),
    ]
    private(set) static var items: [Item] = builtIn
    /// The ⌘K leader is waiting: the line shows `leaderItems`.
    private(set) static var leader = false
    /// What the line shows now.
    static var shownItems: [Item] { leader ? leaderItems : items }

    /// Switch the line to the leader letters (or back). A faded line comes back at once.
    static func setLeader(_ on: Bool) {
        guard on != leader else { return }
        leader = on
        for w in NSApp.windows {
            guard let root = (w.windowController as? ShellWindowController)?.root else { continue }
            for p in root.area.panes.values { (p as? EditorPaneView)?.hints?.leaderChanged() }
        }
    }
    private(set) static var isVisible = true
    static var isShown: Bool { isVisible && ShortcutHintsView.enabled }

    static func setVisible(_ on: Bool) {
        guard on != isVisible else { return }
        isVisible = on
        relayoutAll()
    }

    static func register(keys: String, label: String, after: String? = nil) {
        let item = Item(keys: keys, label: label)
        if let i = items.firstIndex(where: { $0.label == label }) {
            items[i] = item
        } else if let a = after, let i = items.firstIndex(where: { $0.label == a }) {
            items.insert(item, at: i + 1)
        } else {
            items.append(item)
        }
        relayoutAll()
    }

    static func unregister(label: String) {
        items.removeAll { $0.label == label }
        relayoutAll()
    }

    /// Lay out every document pane again (the band comes or goes, the line refits).
    static func relayoutAll() {
        for w in NSApp.windows {
            guard let root = (w.windowController as? ShellWindowController)?.root else { continue }
            for p in root.area.panes.values { (p as? EditorPaneView)?.applyColumnLayout() }
        }
    }
}

@MainActor
final class ShortcutHintsView: FlippedView {
    static let gap = "      "   // six spaces: each hint reads as a unit
    /// The leader line has more, shorter items: the old three spaces keep all six on a narrow window.
    static let leaderGap = "   "
    static var currentGap: String { HintStrip.leader ? leaderGap : gap }
    /// Height of the band kept free at the bottom of the pane.
    static let band: CGFloat = 52
    /// The line's centre above the pane's bottom edge: the Overflow button's centre line (16 + 28 / 2),
    /// so the two sit on one line.
    static let centreFromBottom: CGFloat = 30
    static let sidePadding: CGFloat = 16
    static let idleDelay: CFTimeInterval = 2
    static let fadeOut: TimeInterval = 0.15
    static let fadeIn: TimeInterval = 0.2

    // MARK: setting

    static let defaultsKey = "FlowriterShortcutHints"
    static let menuTitle = "Show Shortcut Hints"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Flip the setting and lay out every document pane again.
    static func setEnabled(_ on: Bool) {
        enabled = on
        HintStrip.relayoutAll()
    }

    /// View > Show Shortcut Hints (after Appearance).
    static func installMenu(in view: NSMenu, at index: Int) {
        let item = ClosureMenuItem(menuTitle, checked: enabled) {}
        item.keyEquivalent = ""
        item.handler = { [weak item] in
            setEnabled(!enabled)
            item?.state = enabled ? .on : .off
        }
        view.insertItem(item, at: index)
    }

    // MARK: view

    let model: ShellModel
    /// The hints drawn at the current width (tests read it).
    private(set) var shown: [String] = []
    /// Faded out after a key (or fading).
    private(set) var isFaded = false
    /// Fade-outs so far (tests: one per burst of typing).
    private(set) var fadeCount = 0
    private var lastKey: CFTimeInterval = 0
    private var idleTimer: Timer?

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true   // the fade is layer opacity: nothing else redraws
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { idleTimer?.invalidate() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var style: TextStyle {
        TextStyle(font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: model.palette_.textIconMuted)
    }

    /// The longest run of hints from the left that fits `width`.
    func fitting(_ width: CGFloat) -> [String] {
        let s = style
        var out: [String] = []
        for h in HintStrip.shownItems {
            let next = out + ["\(h.keys) \(h.label)"]
            if s.width(next.joined(separator: Self.currentGap)) > width - 2 * Self.sidePadding { break }
            out = next
        }
        return out
    }

    var line: String { shown.joined(separator: Self.currentGap) }

    /// The leader started or ended: refit the line, and bring a faded line back (a leader hint
    /// that is invisible is no hint).
    func leaderChanged() {
        let s = fitting(bounds.width)
        if s != shown { shown = s }
        needsDisplay = true
        if HintStrip.leader {
            idleTimer?.invalidate(); idleTimer = nil
            if isFaded { setFaded(false) }
        }
    }

    override func layout() {
        super.layout()
        let s = fitting(bounds.width)
        if s != shown { shown = s; needsDisplay = true }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let s = fitting(newSize.width)
        if s != shown { shown = s; needsDisplay = true }
    }

    /// The line's rect in view coordinates (tests check it against the text).
    var textRect: CGRect {
        let s = style, w = s.width(line), lh: CGFloat = 16
        return CGRect(x: ((bounds.width - w) / 2).rounded(), y: (bounds.height - Self.centreFromBottom - lh / 2).rounded(), width: w, height: lh)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !shown.isEmpty else { return }
        let r = textRect
        style.draw(line, x: r.minX, lineTop: r.minY, lineHeight: r.height, in: ctx)
    }

    // MARK: fade

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A key reached the page: fade out, and come back once no key has come for `idleDelay`.
    func keyPressed() {
        lastKey = CACurrentMediaTime()
        if !isFaded { setFaded(true) }
        if idleTimer == nil { arm(after: Self.idleDelay) }
    }

    private func arm(after s: CFTimeInterval) {
        idleTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, s), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleCheck() }
        }
    }

    private func idleCheck() {
        idleTimer = nil
        let quiet = CACurrentMediaTime() - lastKey
        if quiet >= Self.idleDelay - 0.01 { setFaded(false) } else { arm(after: Self.idleDelay - quiet) }
    }

    private func setFaded(_ f: Bool) {
        isFaded = f
        if f { fadeCount += 1 }
        let target: CGFloat = f ? 0 : 1
        if Self.reduceMotion || window == nil || isHidden {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = f ? Self.fadeOut : Self.fadeIn
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)   // ease-out
            animator().alphaValue = target
        }
    }
}
