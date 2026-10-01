import XCTest
@testable import FloCore

/// File > Open Recent: order, the ten-row cap, dedupe, files that are gone, names, the cleared state.
final class RecentMenuTests: XCTestCase {
    private func entries(_ paths: [String]) -> [RecentEntry] { paths.enumerated().map { RecentEntry(path: $0.element, openedAt: UInt64(100 - $0.offset)) } }
    private let all: (String) -> Bool = { _ in true }

    func testNewestFirstAsStored() {
        let rows = RecentMenu.items(entries(["/n/c.md", "/n/a.md", "/n/b.md"]), home: "/h", exists: all)
        XCTAssertEqual(rows.map(\.title), ["c", "a", "b"])
    }

    func testCapsAtTenRows() {
        let rows = RecentMenu.items(entries((0..<25).map { "/n/file-\($0).md" }), home: "/h", exists: all)
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.first?.title, "file-0")
        XCTAssertEqual(rows.last?.title, "file-9")
    }

    func testTheCurrentFileIsLeftOutAndTheCapStillFills() {
        let paths = (0..<12).map { "/n/file-\($0).md" }
        let rows = RecentMenu.items(entries(paths), current: "/n/file-0.md", home: "/h", exists: all)
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.first?.title, "file-1")
        XCTAssertFalse(rows.contains { $0.path == "/n/file-0.md" })
    }

    func testDuplicatePathsShowOnce() {
        let rows = RecentMenu.items(entries(["/n/a.md", "/n/b.md", "/n/a.md"]), home: "/h", exists: all)
        XCTAssertEqual(rows.map(\.path), ["/n/a.md", "/n/b.md"])
    }

    func testFilesThatAreGoneAreDropped() {
        let rows = RecentMenu.items(entries(["/n/a.md", "/n/gone.md", "/n/b.md"]), home: "/h", exists: { !$0.hasSuffix("gone.md") })
        XCTAssertEqual(rows.map(\.title), ["a", "b"])
    }

    func testMissingFilesDoNotUseUpTheCap() {
        let paths = (0..<14).map { "/n/file-\($0).md" }
        let rows = RecentMenu.items(entries(paths), home: "/h", exists: { !$0.hasSuffix("file-1.md") && !$0.hasSuffix("file-2.md") })
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.map(\.title).prefix(3), ["file-0", "file-3", "file-4"])
    }

    func testNamesDropMdOnly() {
        XCTAssertEqual(RecentMenu.displayName("/n/Letter.md"), "Letter")
        XCTAssertEqual(RecentMenu.displayName("/n/Letter.MD"), "Letter")
        XCTAssertEqual(RecentMenu.displayName("/n/Letter.markdown"), "Letter")
        XCTAssertEqual(RecentMenu.displayName("/n/todo.txt"), "todo.txt")
        XCTAssertEqual(RecentMenu.displayName("/n/.md"), ".md")
        XCTAssertEqual(RecentMenu.displayName("/n/a.b.md"), "a.b")
    }

    func testSharedNamesGetTheirFolder() {
        let rows = RecentMenu.items(entries(["/w/notes/plan.md", "/w/drafts/plan.md", "/w/drafts/other.md"]), home: "/h", exists: all)
        XCTAssertEqual(rows.map(\.title), ["plan — notes", "plan — drafts", "other"])
        XCTAssertEqual(rows.map(\.name), ["plan", "plan", "other"])
        XCTAssertEqual(rows.map(\.folder), ["notes", "drafts", nil])
    }

    func testTheFolderIsAddedOnlyWhileTheNameIsShared() {
        // the second "plan" is the current file: left out, so the first one is unique again
        let rows = RecentMenu.items(entries(["/w/notes/plan.md", "/w/drafts/plan.md"]), current: "/w/drafts/plan.md", home: "/h", exists: all)
        XCTAssertEqual(rows.map(\.title), ["plan"])
    }

    func testTooltipHasTheTildePath() {
        let rows = RecentMenu.items(entries(["/h/docs/a.md", "/elsewhere/b.md"]), home: "/h", exists: all)
        XCTAssertEqual(rows.map(\.tooltip), ["~/docs/a.md", "/elsewhere/b.md"])
        XCTAssertEqual(rows.map(\.parentTooltip), ["~/docs", "/elsewhere"])
        XCTAssertEqual(RecentMenu.tildePath("/h", home: "/h"), "~")
        XCTAssertEqual(RecentMenu.tildePath("/hx/a.md", home: "/h"), "/hx/a.md")
    }

    func testClearedEntriesAreLeftOut() {
        var e = entries(["/n/a.md", "/n/b.md"])
        e[0].hidden = true
        XCTAssertEqual(RecentMenu.items(e, home: "/h", exists: all).map(\.title), ["b"])
    }

    // MARK: store

    func testStorePersistsOrderAndClearMenuKeepsTheEntries() throws {
        let dir = AppTestFS.makeTempDir("recent-menu")
        defer { AppTestFS.remove(dir) }
        for n in ["one", "two", "three"] { AppTestFS.write("\(dir)/\(n).md", n) }
        let url = URL(fileURLWithPath: dir + "/data/recent_files.json")
        let store = RecentFilesStore(url: url)
        try store.record(dir + "/one.md", now: Date(timeIntervalSince1970: 100))
        try store.record(dir + "/two.md", now: Date(timeIntervalSince1970: 101))
        try store.record(dir + "/three.md", now: Date(timeIntervalSince1970: 102))
        try store.record(dir + "/one.md", now: Date(timeIntervalSince1970: 103))
        // a new store object on the same file: what a relaunch sees
        let again = RecentFilesStore(url: url)
        XCTAssertEqual(RecentMenu.items(again.menuEntries()).map(\.title), ["one", "three", "two"])
        try again.clearMenu()
        XCTAssertEqual(RecentMenu.items(again.menuEntries()), [])
        XCTAssertEqual(again.load().map { $0.path }.first, dir + "/one.md", "the last document is still known (the app reopens it)")
        XCTAssertEqual(RecentFilesStore(url: url).menuEntries(), [], "the cleared state survives a relaunch")
        // opening a file again shows it again, the rest stay cleared
        try again.record(dir + "/two.md", now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(RecentMenu.items(again.menuEntries()).map(\.title), ["two"])
    }

    func testEntriesWithoutTheHiddenKeyKeepTheOldFileFormat() throws {
        let dir = AppTestFS.makeTempDir("recent-menu")
        defer { AppTestFS.remove(dir) }
        AppTestFS.write(dir + "/a.md", "a")
        let store = RecentFilesStore(url: URL(fileURLWithPath: dir + "/recent_files.json"))
        try store.record(dir + "/a.md", now: Date(timeIntervalSince1970: 5))
        XCTAssertFalse(AppTestFS.read(dir + "/recent_files.json")!.contains("hidden"))
    }
}
