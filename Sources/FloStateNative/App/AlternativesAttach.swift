import AppKit
import FloCore
import FloKit

/// Flowriter: Alternatives for Markdown editor panes, the panel in the editor area, and the
/// Format menu items. Off with `FLO_ALTERNATIVES=0`.
@MainActor
enum AlternativesAttach {
    static var enabled: Bool { ProcessInfo.processInfo.environment["FLO_ALTERNATIVES"] != "0" }

    /// Called once per editor controller (EditorPaneView.makeController).
    static func attach(_ c: EditorController, path: String) {
        guard enabled, !ShellSnapshot.active, GhostAttach.markdownExtensions.contains((path as NSString).pathExtension.lowercased()) else { return }
        AlternativesLayer.attach(to: c, documentPath: path)
        // Esc in the page that nothing else used closes the panel (Esc in the panel gives the page focus first)
        c.onUnusedEscape = { [weak c] in
            var v: NSView? = c?.textView
            while let s = v, !(s is EditorAreaView) { v = s.superview }
            guard let p = (v as? EditorAreaView)?.alternativesPanel, p.isOpen else { return false }
            p.dismiss()
            return true
        }
    }

    /// The editor area's panel (created on first use).
    static func panel(_ area: EditorAreaView) -> AlternativesPanelView {
        if let p = area.alternativesPanel { return p }
        let p = AlternativesPanelView(model: area.model)
        p.area = area
        area.addSubview(p)
        area.alternativesPanel = p
        return p
    }

    static var keyArea: EditorAreaView? {
        (NSApp.keyWindow?.windowController as? ShellWindowController)?.root.area
            ?? (NSApp.mainWindow?.windowController as? ShellWindowController)?.root.area
    }

    /// The Versions panel (⌘K then v): toggle it (with a selection and the panel closed: add an alternative to it).
    static func toggle(_ area: EditorAreaView? = nil) {
        guard let a = area ?? keyArea else { return }
        let p = panel(a)
        if !p.isOpen { WritingTools.isOn = true }   // the panel works on the decorations: tools on
        if !p.isOpen, let l = a.activeFilePane?.controller?.alternatives, l.selectionRange.length > 0 {
            p.open(onSelection: l.selectionRange, in: l)
        } else {
            p.toggle()
        }
    }

    /// ⌥A "Add Alternative…": the panel on the selection (or the word at the caret). The shortcut
    /// pressed again (`fromKey`) closes the panel: from inside the panel, or from the page on the
    /// text the panel already shows (AlternativesPanelView.addShortcutCloses). On other text it moves
    /// the panel there. The menu items chosen by mouse always open (and focus the add line).
    static func addAlternative(_ area: EditorAreaView? = nil, fromKey: Bool = false) {
        guard let a = area ?? keyArea, let l = a.activeFilePane?.controller?.alternatives else { return }
        let p = panel(a)
        let r = l.selectionRange.length > 0 ? l.selectionRange : (AltText.word(in: l.text, at: l.caret) ?? l.selectionRange)
        if fromKey, p.addShortcutCloses(r, in: l) {
            p.dismiss()
            p.focusEditor()
            return
        }
        WritingTools.isOn = true   // the panel works on the decorations: tools on
        p.open(onSelection: r, in: l)
    }

    static let addTitle = "Add Alternative…"
    static let toggleTitle = "Alternatives"

    /// Append the items to the Format menu (after `NSApp.mainMenu` is built).
    static func installMenu() {
        guard enabled, let format = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == L("Format") })?.submenu,
              !format.items.contains(where: { $0.title == addTitle }) else { return }
        format.addItem(.separator())
        format.addItem(ClosureMenuItem(addTitle, key: "a", modifiers: [.option]) { addAlternative(fromKey: NSApp.currentEvent?.type == .keyDown) })
        format.addItem(ClosureMenuItem(toggleTitle) { toggle() })
    }
}
