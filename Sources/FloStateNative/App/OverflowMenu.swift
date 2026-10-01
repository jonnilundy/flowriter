import AppKit
import FloCore
import FloKit

/// Flowriter Overflow: the menu, shortcuts and the editor's context-menu item.
///   Show / Hide Overflow      Option-O
///   Stash in Overflow         ⌘K then s          (also in the editor's right-click menu)
@MainActor
enum OverflowMenu {
    static let toggleTitles = ("Show Overflow", "Hide Overflow")
    static let stashTitle = "Stash in Overflow"
    private static let delegate = Delegate()

    /// The focused window's Overflow (the active editor pane's).
    static var current: OverflowController? {
        (NSApp?.keyWindow?.windowController as? ShellWindowController)?.root.area.activeFilePane?.overflow
    }

    static func installMenu(in main: NSMenu) {
        let menu = NSMenu(title: "Overflow")
        menu.autoenablesItems = false
        menu.delegate = delegate
        menu.addItem(ClosureMenuItem(toggleTitles.0, key: "o", modifiers: [.option]) { current?.toggle() })
        menu.addItem(ClosureMenuItem(stashTitle) { current?.stashSelection() })
        let top = NSMenuItem(title: "Overflow", action: nil, keyEquivalent: "")
        top.submenu = menu
        let at = main.items.firstIndex { $0.submenu === NSApp?.windowsMenu } ?? main.items.count
        main.insertItem(top, at: at)
        delegate.menuNeedsUpdate(menu)
    }

    /// The editor's context menu gets "Stash in Overflow" after the paste items, only with a selection.
    static func attachContextMenu(to c: EditorController) {
        c.contextMenuExtras = { [weak c] menu in
            guard let c = c, !c.state.selection.main.empty else { return }
            let item = ClosureMenuItem(stashTitle) { OverflowMenu.current?.stashSelection() }
            let at = min(menu.items.count, (menu.items.firstIndex { $0.isSeparatorItem }) ?? menu.items.count)
            menu.insertItem(.separator(), at: at)
            menu.insertItem(item, at: at + 1)
        }
    }

    final class Delegate: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            MainActor.assumeIsolated {
                let o = OverflowMenu.current
                menu.items.first?.title = o?.isOpen == true ? OverflowMenu.toggleTitles.1 : OverflowMenu.toggleTitles.0
                // Stash stays enabled: key equivalents skip this update, so a stale "disabled" would block
                // the shortcut. With no selection, stashSelection() just beeps.
            }
        }
    }
}
