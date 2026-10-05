import XCTest
@testable import FloCore
@testable import FloStateNative

/// The pure edits behind the Writing locations editor (no views).
final class LocationsEditorTests: XCTestCase {
    func state(_ lines: [String], default d: String = "") -> LocationsState {
        LocationsState(locations: NoteLocations.parse(lines), defaultPath: d)
    }

    func testToggleDefaultSetsThenClears() {
        var s = state(["A|/a", "B|/b"])
        XCTAssertFalse(s.isDefault(0))
        s.toggleDefault(at: 1)
        XCTAssertEqual(s.defaultPath, "/b")
        XCTAssertTrue(s.isDefault(1) && !s.isDefault(0))
        s.toggleDefault(at: 0)   // another row takes the default
        XCTAssertEqual(s.defaultPath, "/a")
        s.toggleDefault(at: 0)   // the default again: none
        XCTAssertEqual(s.defaultPath, "")
        XCTAssertNil(s.storedDefault)
    }

    func testDefaultMatchesByFolderNotSpelling() {
        let s = state(["A|/a/b"], default: "/a/b/")
        XCTAssertTrue(s.isDefault(0))
    }

    func testRenameCleansAndReportsChange() {
        var s = state(["|/a"])
        XCTAssertTrue(s.rename(at: 0, to: " Jour|nal \n"))
        XCTAssertEqual(s.locations[0].nickname, "Jour/nal")
        XCTAssertFalse(s.rename(at: 0, to: "Jour/nal"), "same nickname: nothing to write")
        XCTAssertTrue(s.rename(at: 0, to: ""), "an empty nickname goes back to the folder name")
        XCTAssertEqual(s.locations[0].displayName, "a")
    }

    func testChangeFolderKeepsNicknameAndDefault() {
        var s = state(["Journal|/a", "Blog|/b"], default: "/a")
        XCTAssertTrue(s.changeFolder(at: 0, to: "/c/"))
        XCTAssertEqual(s.locations.map(\.encoded), ["Journal|/c", "Blog|/b"])
        XCTAssertEqual(s.defaultPath, "/c")
        XCTAssertFalse(s.changeFolder(at: 0, to: "/b"), "another row already has that folder")
        XCTAssertFalse(s.changeFolder(at: 0, to: "/c"), "the same folder")
        XCTAssertTrue(s.changeFolder(at: 1, to: "/d"))
        XCTAssertEqual(s.defaultPath, "/c", "a non-default row does not touch the default")
    }

    func testRemoveClearsADefaultOnlyWhenItWasTheDefault() {
        var s = state(["A|/a", "B|/b"], default: "/a")
        s.remove(at: 1)
        XCTAssertEqual(s.defaultPath, "/a")
        s.remove(at: 0)
        XCTAssertEqual(s.defaultPath, "")
        XCTAssertTrue(s.locations.isEmpty)
        XCTAssertNil(s.storedLines, "an empty list is reset, not stored")
    }

    func testAddSkipsAFolderAlreadyListed() {
        var s = state(["A|/a"])
        XCTAssertFalse(s.add(path: "/a/"))
        XCTAssertTrue(s.add(path: "/b/"))
        XCTAssertEqual(s.storedLines, ["A|/a", "|/b"])
    }

    func testImplicitDefaultIsInTheListThatGetsStored() {
        // a default from before the list existed: the values show it as the first location
        let values = SettingsValues(["files.default-note-location": .string("/old")])
        var s = LocationsState(values)
        XCTAssertEqual(s.locations.map(\.encoded), ["|/old"])
        XCTAssertTrue(s.isDefault(0))
        XCTAssertTrue(s.add(path: "/new"))
        XCTAssertEqual(s.storedLines, ["|/old", "|/new"])
        XCTAssertEqual(s.storedDefault, "/old")
    }

    func testStructureIgnoresNicknamesButSeesDefaultAndProblems() {
        let tmp = NSTemporaryDirectory() + "loc-structure-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var s = state(["A|\(tmp)", "B|\(tmp)/gone"])
        let before = s.structure()
        XCTAssertTrue(before[0].hasSuffix("|false|ok") && before[1].hasSuffix("|false|missing"), "\(before)")
        s.rename(at: 0, to: "Renamed")
        XCTAssertEqual(s.structure(), before, "typing a nickname does not rebuild the rows")
        s.toggleDefault(at: 0)
        XCTAssertNotEqual(s.structure(), before)
    }
}
