import XCTest
@testable import FloCore

final class NewNoteLocationTests: XCTestCase {
    var tmp: String!

    override func setUp() {
        tmp = NSTemporaryDirectory() + "flo-newnote-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp + "/locked")
        try? FileManager.default.removeItem(atPath: tmp)
    }

    func testUnsetKeepsTodaysFolder() {
        let c = NewNoteLocation.choose(defaultLocation: "", fallback: "/w")
        XCTAssertEqual(c, .init(directory: "/w", usedDefault: false, problem: nil))
        XCTAssertEqual(NewNoteLocation.choose(defaultLocation: "  ", fallback: nil).directory, nil)
    }

    func testSetFolderWins() {
        let c = NewNoteLocation.choose(defaultLocation: tmp + "/", fallback: "/w")
        XCTAssertEqual(c, .init(directory: tmp, usedDefault: true, problem: nil))
    }

    func testMissingFolderFallsBack() {
        let c = NewNoteLocation.choose(defaultLocation: tmp + "/gone", fallback: "/w")
        XCTAssertEqual(c, .init(directory: "/w", usedDefault: false, problem: .missing))
        // a file is not a folder
        FileManager.default.createFile(atPath: tmp + "/f.md", contents: Data())
        XCTAssertEqual(NewNoteLocation.choose(defaultLocation: tmp + "/f.md", fallback: "/w").problem, .missing)
    }

    func testReadOnlyFolderFallsBack() throws {
        try FileManager.default.createDirectory(atPath: tmp + "/locked", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp + "/locked")
        try XCTSkipIf(getuid() == 0, "root can write anywhere")
        let c = NewNoteLocation.choose(defaultLocation: tmp + "/locked", fallback: "/w")
        XCTAssertEqual(c, .init(directory: "/w", usedDefault: false, problem: .notWritable))
    }

    func testNameStaysInsideTheFolder() {
        XCTAssertEqual(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: " Ideas "), "/d/Ideas.md")
        XCTAssertEqual(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "x.md"), "/d/x.md")
        XCTAssertEqual(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "drafts/idea"), "/d/drafts/idea.md")
        XCTAssertEqual(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "/abs/idea"), "/d/abs/idea.md")
        XCTAssertEqual(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "./a//b"), "/d/a/b.md")
        XCTAssertNil(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "../escape"))
        XCTAssertNil(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "a/../../escape"))
        XCTAssertNil(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: ".."))
        XCTAssertNil(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "  "))
        XCTAssertNil(NewNoteLocation.confinedCreatePath(directory: "/d", rawName: "/"))
    }

    func testAbbreviated() {
        XCTAssertEqual(NewNoteLocation.abbreviated("/h/me/Notes", home: "/h/me"), "~/Notes")
        XCTAssertEqual(NewNoteLocation.abbreviated("/h/me", home: "/h/me"), "~")
        XCTAssertEqual(NewNoteLocation.abbreviated("/h/meow/Notes", home: "/h/me"), "/h/meow/Notes")
        XCTAssertEqual(NewNoteLocation.normalized("~/Notes/"), NSHomeDirectory() + "/Notes")
    }
}
