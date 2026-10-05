import AppKit
import FloCore

/// Flowriter: the menu bar of the writing space. A writing window holds one document: no tabs,
/// no sidebar, no workspace. Upstream's items for those do nothing here (ShellModel.perform guards
/// them on `root != nil` or `!isCompact`), so this removes them from the built menu.
/// `MainMenu.build`, the `ShellAction` cases and `perform` stay as they are: FLO_SPACE=0 runs the
/// upstream shell with the full menu.
/// Two fixes go with it. Close Tab was ⌘W and a silent no-op, so the standard Close Window takes
/// ⌘W (performClose through the responder chain; the window's close path flushes dirty text,
/// ShellModel.windowWillClose). "Search…" showed ⌘K, but in the page ⌘K is the leader key
/// (WritingKeys), so the item keeps its action and loses the key.
/// Hook: FlowriterSpace.installMenus, last.
@MainActor
enum WritingSpaceMenu {
    /// Titles removed from the File, View and Window menus, as MainMenu builds them (before L()).
    /// Toggle Typewriter Scrolling is here too: ViewTogglesView.installMenu removes it later, but
    /// its separator must go in the same pass or a doubled one would be left behind.
    static let removedTitles = [
        "New Tab", "Close Tab", "Show Previous Tab", "Show Next Tab", "Go to Tab",
        "Toggle Sidebar", "Toggle Typewriter Scrolling", "Search in All Notes…", "Previous File", "Next File",
    ]

    static func install(in main: NSMenu) {
        guard FlowriterSpace.enabled else { return }
        let gone = Set(removedTitles.map { L($0) })
        for name in ["File", "View", "Window"] {
            guard let menu = main.items.first(where: { $0.title == L(name) })?.submenu else { continue }
            for item in menu.items where gone.contains(item.title) { menu.removeItem(item) }
            tidySeparators(menu)
        }
        if let file = main.items.first(where: { $0.title == L("File") })?.submenu,
           let search = file.items.first(where: { $0.title == L("Search…") }) {
            search.keyEquivalent = ""
            search.keyEquivalentModifierMask = []
        }
        if let window = main.items.first(where: { $0.title == L("Window") })?.submenu,
           let close = window.items.first(where: { $0.title == L("Close Window") }) {
            close.keyEquivalent = "w"
            close.keyEquivalentModifierMask = [.command]
        }
    }

    /// No separator at the top or the bottom, and never two in a row (hidden items do not count).
    static func tidySeparators(_ menu: NSMenu) {
        var last: NSMenuItem?   // the last visible item kept
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem, last == nil || last!.isSeparatorItem { menu.removeItem(item) } else { last = item }
        }
        while let end = menu.items.last(where: { !$0.isHidden }), end.isSeparatorItem { menu.removeItem(end) }
    }
}
