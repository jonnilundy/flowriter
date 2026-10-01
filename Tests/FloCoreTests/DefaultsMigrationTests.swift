import XCTest
@testable import FloCore

/// Flowriter: the one-time copy of the defaults written under the bundle id before the rename.
final class DefaultsMigrationTests: XCTestCase {
    var oldName = "", newName = ""
    var old: UserDefaults!, new: UserDefaults!

    override func setUp() {
        let id = UUID().uuidString
        oldName = "flowriter-test-old-\(id)"
        newName = "flowriter-test-new-\(id)"
        old = UserDefaults(suiteName: oldName)
        new = UserDefaults(suiteName: newName)
    }

    override func tearDown() {
        old.removePersistentDomain(forName: oldName)
        new.removePersistentDomain(forName: newName)
    }

    func testCopiesEveryKeyOnceThenSetsTheFlag() {
        old.set(true, forKey: "FlowriterShowHints")
        old.set("dark", forKey: "Theme")
        old.set(["a", "b"], forKey: "Recent")
        XCTAssertTrue(DefaultsMigration.run(from: oldName, into: new))
        XCTAssertEqual(new.bool(forKey: "FlowriterShowHints"), true)
        XCTAssertEqual(new.string(forKey: "Theme"), "dark")
        XCTAssertEqual(new.stringArray(forKey: "Recent"), ["a", "b"])
        XCTAssertEqual(new.bool(forKey: DefaultsMigration.doneKey), true)
        // a second launch copies nothing, even when the old domain changed since
        new.set("light", forKey: "Theme")
        old.set("sepia", forKey: "Theme")
        XCTAssertFalse(DefaultsMigration.run(from: oldName, into: new))
        XCTAssertEqual(new.string(forKey: "Theme"), "light")
    }

    func testEmptyOldDomainCopiesNothingAndSetsNoFlag() {
        XCTAssertFalse(DefaultsMigration.run(from: oldName, into: new))
        XCTAssertNil(new.object(forKey: DefaultsMigration.doneKey))
    }

    func testFlagAlreadySetCopiesNothing() {
        new.set(true, forKey: DefaultsMigration.doneKey)
        old.set("dark", forKey: "Theme")
        XCTAssertFalse(DefaultsMigration.run(from: oldName, into: new))
        XCTAssertNil(new.object(forKey: "Theme"))
    }
}
