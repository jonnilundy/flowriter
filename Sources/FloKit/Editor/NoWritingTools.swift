import AppKit

/// Flowriter has no AI: Apple's Writing Tools (the round button beside a selection, the Edit menu
/// "Writing Tools" item, the right-click entry) are off everywhere. Every text view the app makes
/// calls `NoWritingTools.configure`; the shared field editors are covered per window; any menu item
/// that AppKit adds for Writing Tools is removed as it is added.
public enum NoWritingTools {
    nonisolated(unsafe) private static var installed = false

    /// Writing Tools off on one text view (macOS 15+; earlier systems have none).
    public static func configure(_ tv: NSTextView) {
        MainActor.assumeIsolated {
            if #available(macOS 15.0, *) {
                tv.writingToolsBehavior = .none
                tv.allowedWritingToolsResultOptions = []
            }
        }
    }

    /// True for an item AppKit adds for Writing Tools (the Edit menu entry, the context menu entry).
    public static func isWritingToolsItem(_ item: NSMenuItem) -> Bool {
        if let a = item.action, NSStringFromSelector(a).lowercased().contains("writingtools") { return true }
        if item.identifier?.rawValue.lowercased().contains("writingtools") == true { return true }
        let t = item.title.lowercased()
        return t == "writing tools" || t == "show writing tools"
    }

    /// Removes Writing Tools items from a menu (and its submenus).
    public static func strip(_ menu: NSMenu) {
        for item in menu.items.reversed() {
            if isWritingToolsItem(item) { menu.removeItem(item); continue }
            if let sub = item.submenu { strip(sub) }
        }
        // a separator left at an end or doubled up
        while let f = menu.items.first, f.isSeparatorItem { menu.removeItem(f) }
        while let l = menu.items.last, l.isSeparatorItem { menu.removeItem(l) }
    }

    /// Menu items found in `menu` (and submenus) that belong to Writing Tools. Used by the self tests.
    public static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            (isWritingToolsItem(item) ? [item] : []) + (item.submenu.map { items(in: $0) } ?? [])
        }
    }

    /// The window's shared field editor (find, rename, add-version and settings fields).
    public static func configureFieldEditor(of window: NSWindow) {
        if let fe = window.fieldEditor(true, for: nil) as? NSTextView { configure(fe) }
    }

    /// Once at launch: field editors per window, and the menu item sweep.
    public static func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated { configureFieldEditor(of: w) }
        }
        nc.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { n in
            guard let menu = n.object as? NSMenu,
                  let i = n.userInfo?["NSMenuItemIndex"] as? Int, menu.items.indices.contains(i) else { return }
            MainActor.assumeIsolated {
                let item = menu.items[i]
                if isWritingToolsItem(item) { menu.removeItem(item) } else if let sub = item.submenu { strip(sub) }
            }
        }
    }
}
