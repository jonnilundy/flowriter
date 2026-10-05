import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// The writing space's menu bar: the items that need tabs, a sidebar or a workspace are gone,
/// ⌘W closes the window, "Search…" shows no key (WritingSpaceMenu.swift).
@MainActor
final class WritingSpaceMenuTests: XCTestCase {
    /// Runs `body` and puts the app's main menu and the Flowriter switch back as they were.
    private func scoped(_ body: () -> Void) {
        _ = NSApplication.shared
        let savedMenu = NSApp.mainMenu, savedEnabled = FlowriterSettings.enabled
        defer { FlowriterSettings.enabled = savedEnabled; NSApp.mainMenu = savedMenu }
        body()
    }

    /// The menus as FloApp builds them (FloApp.swift, in the same order).
    private func appMenu(enabled: Bool = true) -> NSMenu {
        FlowriterSettings.enabled = enabled
        let main = MainMenu.build(target: MenuRouter())
        NSApp.mainMenu = main
        GhostAttach.installMenu()
        AlternativesAttach.installMenu()
        let recents = RecentFilesStore(url: URL(fileURLWithPath: NSTemporaryDirectory() + "WritingSpaceMenuTests-recent.json"))
        FlowriterSpace.installMenus(in: main, focused: { nil }, recents: recents)
        SelectionBar.installMenu(in: main)
        OverflowMenu.installMenu(in: main)
        if FlowriterSpace.enabled { ViewTogglesView.installMenu(in: main) }
        return main
    }

    private func menu(_ main: NSMenu, _ name: String) -> NSMenu? { main.items.first { $0.title == L(name) }?.submenu }
    private func all(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }

    private func label(_ i: NSMenuItem) -> String {
        guard !i.keyEquivalent.isEmpty else { return "" }
        let m = i.keyEquivalentModifierMask
        let names: [Character: String] = ["\t": "Tab", String(UnicodeScalar(NSUpArrowFunctionKey)!).first!: "Up", String(UnicodeScalar(NSDownArrowFunctionKey)!).first!: "Down",
                                          String(UnicodeScalar(NSLeftArrowFunctionKey)!).first!: "Left", String(UnicodeScalar(NSRightArrowFunctionKey)!).first!: "Right"]
        let key = i.keyEquivalent.count == 1 ? (names[i.keyEquivalent.first!] ?? i.keyEquivalent.uppercased()) : i.keyEquivalent
        return (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + key
    }

    private func tree(_ m: NSMenu, indent: String = "") -> [String] {
        m.items.flatMap { i -> [String] in
            let line = i.isSeparatorItem ? "\(indent)----" : "\(indent)\(i.title)\(label(i).isEmpty ? "" : "   \(label(i))")\(i.isHidden ? "   (hidden)" : "")"
            return [line] + (i.submenu.map { tree($0, indent: indent + "    ") } ?? [])
        }
    }

    /// (key, modifiers) as AppKit matches it: an upper-case key implies Shift.
    private func chord(_ i: NSMenuItem) -> String? {
        guard !i.keyEquivalent.isEmpty else { return nil }
        var m = i.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
        if i.keyEquivalent != i.keyEquivalent.lowercased() { m.insert(.shift) }
        return "\(m.rawValue)-\(i.keyEquivalent.lowercased())"
    }

    func testTheRemovedItemsAreGone() {
        scoped {
            let main = appMenu()
            let titles = Set(all(main).map(\.title))
            for t in WritingSpaceMenu.removedTitles { XCTAssertFalse(titles.contains(L(t)), "\(t) is gone") }
            for n in 1...9 { XCTAssertFalse(titles.contains(L("Tab %d", n)), "Tab \(n) is gone") }
            // none of their keys is left on any item
            let keys = Set(all(main).compactMap(chord))
            XCTAssertFalse(keys.contains("\(NSEvent.ModifierFlags.command.rawValue)-t"), "no item on ⌘T")
            XCTAssertFalse(keys.contains("\(NSEvent.ModifierFlags.command.rawValue)-\\"), "no item on ⌘\\")
        }
    }

    func testNoLeadingTrailingOrDoubledSeparators() {
        scoped {
            let main = appMenu()
            for name in ["File", "View", "Window"] {
                let items = menu(main, name)!.items.filter { !$0.isHidden }
                XCTAssertFalse(items.first?.isSeparatorItem ?? true, "\(name): no separator first")
                XCTAssertFalse(items.last?.isSeparatorItem ?? true, "\(name): no separator last")
                XCTAssertFalse(zip(items, items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem }, "\(name): no doubled separator")
            }
        }
    }

    func testTheWorkingItemsStay() {
        scoped {
            let main = appMenu()
            let file = menu(main, "File")!, view = menu(main, "View")!, window = menu(main, "Window")!
            let fileTitles = file.items.map(\.title), viewTitles = view.items.map(\.title)
            for t in ["New Note", "Open…", "Open Recent", "Go to Today", "Search…"] { XCTAssertTrue(fileTitles.contains(L(t)), "File: \(t)") }
            for t in ["Appearance", "Reading View", "Tracking Mode", "Increase Font Size", "Decrease Font Size", "Reset Font Size",
                      "Collapse All Headings", "Expand All Headings", "Back", "Forward"] { XCTAssertTrue(viewTitles.contains(L(t)), "View: \(t)") }
            XCTAssertTrue(viewTitles.contains(ShortcutHintsView.menuTitle), "View: Show Shortcut Hints")
            for t in ["Minimize", "Enter Full Screen", "Close Window"] { XCTAssertTrue(window.items.map(\.title).contains(L(t)), "Window: \(t)") }
            XCTAssertEqual(label(view.items.first { $0.title == "Tracking Mode" }!), "⌃⌘T")
            XCTAssertEqual(label(view.items.first { $0.title == "Reading View" }!), "⌃⌘M")
            XCTAssertEqual(label(view.items.first { $0.title == L("Increase Font Size") }!), "⌘=")
            XCTAssertEqual(label(file.items.first { $0.title == L("Open…") }!), "⌘O")
            XCTAssertEqual(label(file.items.first { $0.title == L("New Note") }!), "⌘N")
            let raw = MainMenu.build(target: MenuRouter())
            XCTAssertEqual(menu(main, "Edit")!.items.count, menu(raw, "Edit")!.items.count, "Edit is whole")
            XCTAssertEqual(menu(main, "Format")!.items.filter { $0.title == L("Bold") }.count, 1, "Format is there")
        }
    }

    func testCloseWindowTakesCommandW() {
        scoped {
            let main = appMenu()
            guard let close = menu(main, "Window")!.items.first(where: { $0.title == L("Close Window") }) else { XCTAssertTrue(false, "Close Window exists"); return }
            XCTAssertEqual(close.keyEquivalent, "w")
            XCTAssertEqual(close.keyEquivalentModifierMask, [.command])
            XCTAssertEqual(close.action, #selector(NSWindow.performClose(_:)), "closes the key window through the responder chain")
            XCTAssertNil(close.target, "no fixed target")
            XCTAssertEqual(all(main).filter { chord($0) == chord(close) }.count, 1, "no other item on ⌘W")
        }
    }

    func testSearchKeepsItsActionAndLosesItsKey() {
        scoped {
            let main = appMenu()
            guard let search = menu(main, "File")!.items.first(where: { $0.title == L("Search…") }) else { XCTAssertTrue(false, "Search… exists"); return }
            XCTAssertEqual(search.keyEquivalent, "")
            XCTAssertTrue(search.action != nil && search.representedObject != nil, "still routes .search")
        }
    }

    func testNoTwoItemsShareAKey() {
        scoped {
            let main = appMenu()
            var seen: [String: String] = [:]
            for i in all(main) {
                guard let c = chord(i) else { continue }
                XCTAssertTrue(seen[c] == nil, "\(i.title) and \(seen[c] ?? "") share \(label(i))")
                seen[c] = i.title
            }
        }
    }

    func testUpstreamModeAndTheBuiltMenuAreUntouched() {
        scoped {
            // MainMenu.build still has every upstream item
            let raw = MainMenu.build(target: MenuRouter())
            let titles = Set(all(raw).map(\.title))
            for t in WritingSpaceMenu.removedTitles { XCTAssertTrue(titles.contains(L(t)), "upstream: \(t)") }
            XCTAssertEqual(label(menu(raw, "File")!.items.first { $0.title == L("Close Tab") }!), "⌘W")
            XCTAssertEqual(label(menu(raw, "File")!.items.first { $0.title == L("Search…") }!), "⌘K")
            // FLO_SPACE=0: the install does nothing
            let upstream = appMenu(enabled: false)
            XCTAssertTrue(all(upstream).contains { $0.title == L("New Tab") }, "upstream mode keeps New Tab")
            XCTAssertEqual(label(menu(upstream, "Window")!.items.first { $0.title == L("Close Window") }!), "")
        }
    }

    func testPrintTheMenuTree() {
        scoped {
            let main = appMenu()
            for name in ["File", "Edit", "Format", "View", "Window"] {
                print("\(name)\n" + tree(menu(main, name)!, indent: "    ").joined(separator: "\n"))
            }
        }
    }
}
