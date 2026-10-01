import AppKit
import FloCore
import FloKit

/// Flowriter: turn Ghost on for a Markdown editor pane. Off with `FLO_GHOST=0`.
@MainActor
enum GhostAttach {
    /// The file types the writing features attach to.
    static let markdownExtensions: Set<String> = ["md", "mdx", "markdown"]

    /// Called once per editor controller (EditorPaneView.makeController).
    static func attach(_ c: EditorController, path: String) {
        guard ProcessInfo.processInfo.environment["FLO_GHOST"] != "0", !ShellSnapshot.active,
              markdownExtensions.contains((path as NSString).pathExtension.lowercased()) else { return }
        GhostLayer.attach(to: c, store: SidecarGhostStore(documentPath: path))
    }

    static let menuTitle = "Ghost it / Revive"

    /// Format menu: Ghost it / Revive, ⌥G (the key monitor takes the key first, WritingKeys.swift).
    static func installMenu() {
        guard ProcessInfo.processInfo.environment["FLO_GHOST"] != "0", let format = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == L("Format") })?.submenu,
              !format.items.contains(where: { $0.title == menuTitle }) else { return }
        format.addItem(ClosureMenuItem(menuTitle, key: "g", modifiers: [.option]) {
            _ = AlternativesAttach.keyArea?.activeFilePane?.controller?.ghosts?.toggle()
        })
    }
}
