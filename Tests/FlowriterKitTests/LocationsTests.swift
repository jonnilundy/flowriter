import XCTest
@testable import FlowriterKit

final class LocationsTests: XCTestCase {
    func testTheFirstFolderIsTheDefault() {
        var l = Locations()
        XCTAssertNil(l.defaultFolder)
        l.add("/tmp/notes/")
        l.add("/tmp/journal")
        l.add("/tmp/notes")
        XCTAssertEqual(l.folders, ["/tmp/notes", "/tmp/journal"])
        XCTAssertEqual(l.defaultFolder, "/tmp/notes")
        l.setDefault("/tmp/journal")
        XCTAssertEqual(l.defaultFolder, "/tmp/journal")
        l.setDefault("/tmp/not-in-the-list")
        XCTAssertEqual(l.defaultFolder, "/tmp/journal")
    }

    func testRemovingTheDefaultMovesItOn() {
        var l = Locations(folders: ["/a/one", "/a/two"], defaultFolder: "/a/two")
        l.remove("/a/two")
        XCTAssertEqual(l.folders, ["/a/one"])
        XCTAssertEqual(l.defaultFolder, "/a/one")
        l.remove("/a/one")
        XCTAssertNil(l.defaultFolder)
    }

    func testSaveAndLoad() {
        let suite = "flowriter-locations-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        var l = Locations.load(d)
        XCTAssertEqual(l, Locations())
        l.add("~/Writing")
        l.add("/tmp/x")
        l.setDefault("/tmp/x")
        l.save(d)
        XCTAssertEqual(Locations.load(d), l)
        XCTAssertEqual(Locations.load(d).folders.first, NSHomeDirectory() + "/Writing")
    }

    func testTitles() {
        let l = Locations(folders: ["/a/notes", "/b/notes", "/c/journal"])
        XCTAssertEqual(l.title(for: "/c/journal"), "journal")
        XCTAssertEqual(l.title(for: "/a/notes"), "/a/notes", "two folders with one name show their paths")
        XCTAssertEqual(Locations.abbreviated(NSHomeDirectory() + "/Notes"), "~/Notes")
    }

    func testNotePaths() {
        XCTAssertEqual(Locations.notePath(in: "/n", name: "idea"), "/n/idea.md")
        XCTAssertEqual(Locations.notePath(in: "/n/", name: "  idea.md "), "/n/idea.md")
        XCTAssertEqual(Locations.notePath(in: "/n", name: "drafts/idea"), "/n/drafts/idea.md")
        XCTAssertEqual(Locations.notePath(in: "/n", name: "list.txt"), "/n/list.txt")
        XCTAssertEqual(Locations.notePath(in: "/n", name: ""), "/n/Untitled.md")
        XCTAssertNil(Locations.notePath(in: "/n", name: "../outside"), "a note never leaves its folder")
    }
}
