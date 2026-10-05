import XCTest
@testable import FloCore

final class NoteLocationsTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let loc = NoteLocation(nickname: "Journal", path: "~/Writing/journal")
        XCTAssertEqual(loc.encoded, "Journal|~/Writing/journal")
        XCTAssertEqual(NoteLocation.decode(loc.encoded), loc)
    }

    func testBarInNicknameIsReplacedAndPathMayHoldBars() {
        let loc = NoteLocation(nickname: "A|B", path: "/x/y|z")
        XCTAssertEqual(loc.nickname, "A/B")
        XCTAssertEqual(NoteLocation.decode(loc.encoded)?.path, "/x/y|z")
    }

    func testDecodeBareAndEmpty() {
        XCTAssertEqual(NoteLocation.decode("/tmp/notes"), NoteLocation(path: "/tmp/notes"))
        XCTAssertEqual(NoteLocation.decode("|/tmp/notes")?.nickname, "")
        XCTAssertNil(NoteLocation.decode(""))
        XCTAssertNil(NoteLocation.decode("Nick|"))
    }

    func testDisplayNameFallsBackToFolderName() {
        XCTAssertEqual(NoteLocation(nickname: "Blog", path: "/a/b").displayName, "Blog")
        XCTAssertEqual(NoteLocation(path: "/a/journal/").displayName, "journal")
        XCTAssertEqual(NoteLocation(path: "/").displayName, "/")
    }

    func testFullPathUsesTildeForHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(NoteLocation(path: home + "/Writing").fullPath, "~/Writing")
        XCTAssertEqual(NoteLocation(path: "~/Writing").fullPath, "~/Writing")
        XCTAssertEqual(NoteLocation(path: "/var/tmp").fullPath, "/var/tmp")
    }

    func testParseDropsDuplicateFoldersFirstWins() {
        let list = NoteLocations.parse(["One|/a/b", "Two|/a/b/", "Three|/c", "garbage|"])
        XCTAssertEqual(list.map(\.nickname), ["One", "Three"])
    }

    func testAllAddsTheDefaultWhenTheListLacksIt() {
        let lines = ["Journal|/a/journal"]
        XCTAssertEqual(NoteLocations.all(lines: lines, defaultPath: "").map(\.displayName), ["Journal"])
        XCTAssertEqual(NoteLocations.all(lines: lines, defaultPath: "/b/blog").map(\.displayName), ["blog", "Journal"])
        // the default is already listed: no second copy, and its nickname stays
        XCTAssertEqual(NoteLocations.all(lines: lines, defaultPath: "/a/journal/").map(\.displayName), ["Journal"])
    }

    func testDefaultLocation() {
        let list = NoteLocations.parse(["Journal|/a/journal", "Blog|/b/blog"])
        XCTAssertEqual(NoteLocations.defaultLocation(in: list, defaultPath: "/b/blog")?.nickname, "Blog")
        XCTAssertNil(NoteLocations.defaultLocation(in: list, defaultPath: ""))
        XCTAssertNil(NoteLocations.defaultLocation(in: list, defaultPath: "/elsewhere"))
    }

    func testAddingAndRemovingTheDefault() {
        let a = NoteLocation(nickname: "A", path: "/a")
        let list = NoteLocations.adding(a, to: [])
        XCTAssertEqual(NoteLocations.adding(NoteLocation(nickname: "Again", path: "/a/"), to: list), list)
        XCTAssertEqual(NoteLocations.defaultPath(afterRemoving: a, defaultPath: "/a"), "")
        XCTAssertEqual(NoteLocations.defaultPath(afterRemoving: a, defaultPath: "/other"), "/other")
    }

    func testProblem() throws {
        let dir = NSTemporaryDirectory() + "noteloc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertNil(NoteLocations.problem(NoteLocation(path: dir)))
        XCTAssertEqual(NoteLocations.problem(NoteLocation(path: dir + "/nope")), .missing)
    }

    func testSettingsValuesReadTheList() {
        let values = SettingsValues(["files.note-locations": .list(["Journal|/a/journal", "Blog|/b/blog"]),
                                     "files.default-note-location": .string("/b/blog")])
        XCTAssertEqual(values.noteLocations.map(\.nickname), ["Journal", "Blog"])
        XCTAssertEqual(values.defaultNoteLocation?.nickname, "Blog")
    }
}
