import AppKit
import FloCore

/// Flowriter: File > Open Recent, under Open…. Up to ten recent documents, newest first, each the
/// file name without ".md" (a name two rows share gets its folder, muted: "notes — drafts"), the
/// ~ path as the tooltip; a separator and Clear Menu. The window's own document and files that are
/// gone are left out. The rows are built when the menu opens (menuNeedsUpdate), so they are always
/// current. A pick opens the document in the focused window, as Open… does (ShellModel.openRecent);
/// with no window it opens a document window. ⇧⌘O and ⌘K r open the same list as a picker
/// (the palette's recent intent). The list is the app's global recent files (recent_files.json).
@MainActor
final class OpenRecentMenu: NSObject, NSMenuDelegate {
    static let shared = OpenRecentMenu()
    static let title = "Open Recent"
    static let clearTitle = "Clear Menu"

    /// The focused window's shell (nil: no window).
    var focused: () -> ShellModel? = { nil }
    /// A pick with no window open.
    var openWithoutWindow: (String) -> Void = { _ in }
    var store: RecentFilesStore?

    /// Insert the submenu right under `after` (Open…) in the File menu.
    static func install(in file: NSMenu, after: NSMenuItem, store: RecentFilesStore,
                        focused: @escaping () -> ShellModel?, openWithoutWindow: @escaping (String) -> Void) {
        let me = shared
        me.store = store
        me.focused = focused
        me.openWithoutWindow = openWithoutWindow
        guard !file.items.contains(where: { $0.title == title }) else { return }
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        sub.delegate = me
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        file.insertItem(item, at: file.index(of: after) + 1)
        me.rebuild(sub)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    func rows() -> [RecentMenuItem] {
        guard let store else { return [] }
        return RecentMenu.items(store.menuEntries(), current: focused()?.editor.activeFilePath)
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let rows = rows()
        for r in rows {
            let it = ClosureMenuItem(r.title) { [weak self] in self?.open(r.path) }
            if let folder = r.folder {
                let font = NSFont.menuFont(ofSize: 0)
                let s = NSMutableAttributedString(string: r.name, attributes: [.font: font])
                s.append(NSAttributedString(string: " — " + folder, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                it.attributedTitle = s
            }
            it.toolTip = r.tooltip
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let clear = ClosureMenuItem(Self.clearTitle) { [weak self] in self?.clear() }
        clear.isEnabled = !rows.isEmpty
        menu.addItem(clear)
    }

    func open(_ path: String) {
        if let m = focused() { m.openRecent(path) } else { openWithoutWindow(path) }
    }

    func clear() {
        try? store?.clearMenu()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
