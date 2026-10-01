import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// The quick recent picker (⇧⌘O, ⌘K r) and ShellModel.openRecent behind File > Open Recent.
@MainActor
final class OpenRecentTests: XCTestCase {
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private func openedThree() async -> ShellFixture {
        let f = ShellFixture(files: ["one.md": "# One\n", "two.md": "# Two\n", "three.md": "# Three\n", "other/two.md": "# Other two\n"])
        await f.model.editor.openCompactFile(f.p("one.md"))
        f.model.openRecent(f.p("two.md")); await settle()
        f.model.openRecent(f.p("three.md")); await settle()
        return f
    }

    func testOpeningFilesBuildsTheListNewestFirstWithoutTheCurrentFile() async {
        let f = await openedThree()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("three.md"))
        XCTAssertEqual(f.model.recentMenuItems().map(\.title), ["two", "one"])
    }

    func testPickingOpensTheFileInTheSameWindowAndMovesItToTheTop() async {
        let f = await openedThree()
        f.model.openRecent(f.p("one.md")); await settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("one.md"))
        XCTAssertEqual(f.model.editor.tabs.count, 1, "one page at a time")
        XCTAssertEqual(f.model.recentMenuItems().map(\.title), ["three", "two"])
    }

    func testAFileThatWentLeavesTheListAndNothingOpens() async {
        let f = await openedThree()
        try? FileManager.default.removeItem(atPath: f.p("two.md"))
        XCTAssertEqual(f.model.recentMenuItems().map(\.title), ["one"])
        f.model.openRecent(f.p("two.md")); await settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("three.md"))
        XCTAssertFalse(f.model.recentFilesStore.load().contains { $0.path == f.p("two.md") })
    }

    func testPickerListsFilterOpenAndClose() async {
        let f = await openedThree()
        f.model.perform(.openRecent)
        XCTAssertEqual(f.model.palette?.intent, .recent)
        var v = f.model.paletteView()!
        XCTAssertEqual(v.items.map(\.title), ["two", "one"])
        XCTAssertEqual(v.placeholder, "Open a recent file...")
        f.model.setPaletteQuery("ON")
        v = f.model.paletteView()!
        XCTAssertEqual(v.items.map(\.title), ["one"])
        f.model.setPaletteQuery("zzz")
        XCTAssertEqual(f.model.paletteView()!.items, [])
        XCTAssertEqual(f.model.paletteView()!.empty, "No recent file matches.")
        f.model.setPaletteQuery("")
        f.model.movePaletteSelection(1)
        f.model.runSelectedPaletteItem()
        XCTAssertNil(f.model.palette)
        await settle()
        XCTAssertEqual(f.model.editor.activeFilePath, f.p("one.md"))
    }

    func testPickerNamesSharedFileNamesByFolder() async {
        let f = ShellFixture(files: ["notes/plan.md": "a", "drafts/plan.md": "b", "end.md": "c"])
        await f.model.editor.openCompactFile(f.p("notes/plan.md"))
        f.model.openRecent(f.p("drafts/plan.md")); await settle()
        f.model.openRecent(f.p("end.md")); await settle()
        f.model.perform(.openRecent)
        XCTAssertEqual(f.model.paletteView()!.items.map(\.title), ["plan — drafts", "plan — notes"])
    }

    func testEmptyListSaysSo() async {
        let f = ShellFixture(files: ["only.md": "x"])
        await f.model.editor.openCompactFile(f.p("only.md"))
        f.model.perform(.openRecent)
        XCTAssertEqual(f.model.paletteView()!.items, [])
        XCTAssertEqual(f.model.paletteView()!.empty, "No recent files.")
        f.model.runSelectedPaletteItem()   // Return on an empty list does nothing
        XCTAssertNotNil(f.model.palette)
    }

    func testClearMenuEmptiesTheListAndSurvivesARelaunch() async throws {
        let f = await openedThree()
        try f.model.recentFilesStore.clearMenu()
        XCTAssertEqual(f.model.recentMenuItems(), [])
        let relaunched = RecentFilesStore(appData: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)))
        XCTAssertEqual(RecentMenu.items(relaunched.menuEntries()), [])
    }
}
