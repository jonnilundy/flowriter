import AppKit
import FloCore
import FloKit

/// Flowriter: the word count at the top is the writing tools switch. A click flips
/// `WritingTools.isOn` (FloKit, persisted). Off (the default on first launch): a plain page, no
/// alternatives squiggles, dots or margin lines, no hover swaps. On: the two view toggles appear
/// either side of the count (ViewTogglesBar.swift); they are the on state, so the count carries no
/// mark of its own. Nothing reflows either way: the decorations are drawn over the text.
/// The shortcuts work with tools off; the Alternatives ones (⌘K v, Opt-A) turn
/// tools on (AlternativesAttach). Turning tools off leaves open panels open: closing one can move
/// the column in a narrow window, and a click on the count must not move text.
/// The shortcut hint line (HintStrip, ShortcutHints.swift) shows only with tools on.
/// Hooks: FlowriterCountView (hit test, click, hover), AlternativesLayer (draw, hit),
/// AlternativesAttach (shortcuts), SelfTestRunner.run (prepareForSelfTest).
@MainActor
enum WritingToolsSwitch {
    private static var observer: NSObjectProtocol?

    /// Once per process (every count view calls it).
    static func install() {
        guard observer == nil else { return }
        HintStrip.setVisible(WritingTools.isOn)   // the shortcut line is a writing tool too
        observer = NotificationCenter.default.addObserver(forName: WritingTools.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
    }

    /// WritingTools.isOn changed (a click, a shortcut, another window).
    static func changed() {
        HintStrip.setVisible(WritingTools.isOn)
        for wc in NSApp.windows.compactMap({ $0.windowController as? ShellWindowController }) {
            wc.root.flowriterCount.needsDisplay = true
        }
    }

    // MARK: the count

    static func hitTest(_ v: FlowriterCountView, _ point: NSPoint) -> NSView? {
        guard !v.isHidden, !v.text.isEmpty else { return nil }
        return v.clickRect.contains(v.convert(point, from: v.superview)) ? v : nil
    }

    static func clicked(_ v: FlowriterCountView, _ e: NSEvent) {
        guard v.clickRect.contains(v.convert(e.locationInWindow, from: nil)) else { return }
        WritingTools.isOn.toggle()
    }

    /// Hover: the muted count a little closer to the text colour (slightly brighter, not loud).
    static func hoverColor(_ p: ShellPalette) -> NSColor {
        p.textIconMuted.blended(withFraction: 0.28, of: p.fgBase) ?? p.textSecondary
    }

    // MARK: self tests

    /// The tools scenarios start from a first launch (no stored value); every other scenario runs
    /// with tools on, as it did before the switch existed (their checks read the decorations).
    static func prepareForSelfTest(_ scenario: String) {
        if scenario == "tools" { UserDefaults.standard.removeObject(forKey: "FlowriterWritingToolsOn") }
        else if !scenario.hasPrefix("restart-tools") { WritingTools.isOn = true }
    }
}

extension FlowriterCountView {
    /// What takes the click: the two counts with 8 pt of air each side (clear of the view toggles).
    var clickRect: NSRect {
        let s = style, o = origins
        let x1 = o.chars + s.width(chars)
        return NSRect(x: o.words - 8, y: (bounds.height - 24) / 2, width: x1 - o.words + 16, height: 24)
    }
}
