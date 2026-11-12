import XCTest
import AppKit
@testable import FlowriterKit

@MainActor
final class SettingsTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: Appearance.key)
    }

    override func tearDown() async throws {
        Appearance.stored = .system
    }

    func testAppearanceIsSystemUntilChosen() {
        XCTAssertEqual(Appearance.stored, .system)
        XCTAssertNil(Appearance.system.appearance)
    }

    func testChoosingAnAppearanceStoresItAndAppliesIt() {
        Appearance.stored = .dark
        XCTAssertEqual(UserDefaults.standard.string(forKey: Appearance.key), "dark")
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        Appearance.stored = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        Appearance.stored = .system
        XCTAssertNil(UserDefaults.standard.object(forKey: Appearance.key))
        XCTAssertNil(NSApp.appearance)
    }

    func testAnUnknownStoredValueIsSystem() {
        UserDefaults.standard.set("sepia", forKey: Appearance.key)
        XCTAssertEqual(Appearance.stored, .system)
    }

    func testTheAppMenuOpensSettingsWithCommandComma() {
        let item = MainMenu.build().items.first?.submenu?.items.first { $0.keyEquivalent == "," }
        XCTAssertEqual(item?.title, "Settings\u{2026}")
        XCTAssertEqual(item?.action, #selector(SettingsWindowController.show(_:)))
    }
}
