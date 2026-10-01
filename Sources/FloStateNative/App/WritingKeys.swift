import AppKit
import FloCore
import FloKit

/// Flowriter: the writing shortcuts, one modifier or two keys deep (a split keyboard finds three
/// and four key chords hard).
///   ⌥G  Ghost it / Revive       ⌥A  Add Alternative…       ⌥O  Show / Hide Overflow
/// and the ⌘K leader: ⌘K, then one plain letter within 2 s:
///   g ghost   a alternative   o overflow   s stash   v versions   l link
/// Esc or the timeout ends the leader. Any other key ends it and goes on to the page as typed (a
/// typed letter is never swallowed). While the leader waits, the shortcut line shows the letters
/// (HintStrip.setLeader). The window's key monitor (ShellWindowController.handleKey) calls `route`
/// before the menus and the text views see the event, so no ©, å or ø reaches the page or the
/// Overflow panel. The Format and Overflow menus carry the same three ⌥ key equivalents for show.
/// ⌘K was Search… (File menu) and still is outside a text view; in the page and the Overflow panel
/// it starts the leader. Insert Link lives on the leader's l (and the Format menu).
@MainActor
enum WritingKeys {
    enum Action: Equatable { case ghost, alternative, overflow, stash, versions, link }

    static let leaderTimeout: TimeInterval = 2
    static let letters: [String: Action] = ["g": .ghost, "a": .alternative, "o": .overflow, "s": .stash, "v": .versions, "l": .link]

    private(set) static var leaderWindow: NSWindow?
    static var leaderActive: Bool { leaderWindow != nil }
    nonisolated(unsafe) private static var timer: Timer?

    /// The text views that take the shortcuts: the page and the Overflow panel.
    static func inWritingText(_ w: NSWindow?) -> Bool {
        let fr = w?.firstResponder
        return fr is FloTextView || fr is OverflowTextView
    }

    private static func modifiers(_ e: NSEvent) -> NSEvent.ModifierFlags {
        e.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    private static func letter(_ e: NSEvent) -> String? {
        guard let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1 else { return nil }
        return c
    }

    /// True when the event is taken (the monitor swallows it); false: it goes on as usual.
    static func route(_ e: NSEvent, in wc: ShellWindowController) -> Bool {
        guard FlowriterSpace.enabled, e.type == .keyDown, let w = wc.window else { return false }
        let mods = modifiers(e)
        if leaderActive {
            guard leaderWindow === w else { endLeader(); return false }
            endLeader()
            if e.keyCode == 53 { return true }   // Esc
            // one plain letter (Caps Lock is not a modifier here); everything else goes on as typed
            if mods.isEmpty, !e.isARepeat, let l = letter(e), let a = letters[l] { run(a, in: wc); return true }
            return false
        }
        guard inWritingText(w) else { return false }
        if mods == [.command], letter(e) == "k" { beginLeader(in: w); return true }
        if mods == [.option] {
            switch letter(e) {
            case "g": if !e.isARepeat { run(.ghost, in: wc) }; return true   // a held key swallows, never types ©
            case "a": if !e.isARepeat { run(.alternative, in: wc) }; return true
            case "o": if !e.isARepeat { run(.overflow, in: wc) }; return true
            default: break
            }
        }
        return false
    }

    // MARK: leader

    static func beginLeader(in w: NSWindow) {
        leaderWindow = w
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: leaderTimeout, repeats: false) { _ in
            MainActor.assumeIsolated { endLeader() }
        }
        HintStrip.setLeader(true)
    }

    static func endLeader() {
        guard leaderActive else { return }
        timer?.invalidate(); timer = nil
        leaderWindow = nil
        HintStrip.setLeader(false)
    }

    // MARK: actions

    static func run(_ a: Action, in wc: ShellWindowController) {
        let area = wc.root.area
        guard let pane = area.activeFilePane else { NSSound.beep(); return }
        switch a {
        case .ghost:
            if pane.controller?.ghosts?.toggle() != true { NSSound.beep() }
        case .alternative:
            AlternativesAttach.addAlternative(area)   // the Format menu's Add Alternative…
        case .overflow:
            if let o = pane.overflow { o.toggle() } else { NSSound.beep() }
        case .stash:
            _ = pane.overflow?.stashSelection()   // beeps itself without a selection
        case .versions:
            AlternativesAttach.toggle(area)
        case .link:
            // the Format menu's Insert Link: the editor keymap's Mod-k (Formatting.insertLink)
            guard let c = pane.controller, wc.window?.firstResponder === c.textView, c.handleKey("Mod-k") else { NSSound.beep(); return }
        }
    }
}
