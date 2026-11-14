import XCTest
@testable import FlowriterKit

final class UpdatesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("updates-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: versions and feed

    func testVersions() {
        XCTAssertEqual(Updates.version("v0.3.0"), [0, 3, 0])
        XCTAssertEqual(Updates.version("1.10"), [1, 10])
        XCTAssertNil(Updates.version("v1.0-beta"))
        XCTAssertNil(Updates.version(""))
        XCTAssertTrue(Updates.isNewer([0, 10, 0], than: [0, 9, 9]))
        XCTAssertTrue(Updates.isNewer([1, 0, 1], than: [1, 0]))
        XCTAssertFalse(Updates.isNewer([1, 0, 0], than: [1, 0]))
        XCTAssertFalse(Updates.isNewer([0, 3, 0], than: [0, 3, 0]))
    }

    func testTheFeedGivesTheZipAndTheNotesWithoutInstallInstructions() throws {
        let json = """
        {"tag_name": "v0.4.0", "html_url": "https://github.com/o/r/releases/tag/v0.4.0",
         "body": "What is new.\\r\\n\\r\\n- one\\n- two\\n\\n**Not notarized yet: right-click.**\\n\\nDownload `Flowriter-0.4.0.zip`, unzip.",
         "assets": [{"name": "notes.txt", "browser_download_url": "https://x/notes.txt"},
                    {"name": "Flowriter-0.4.0.zip", "browser_download_url": "https://x/Flowriter-0.4.0.zip"}]}
        """
        let release = try Updates.parse(Data(json.utf8))
        XCTAssertEqual(release.version, [0, 4, 0])
        XCTAssertEqual(release.zip, URL(string: "https://x/Flowriter-0.4.0.zip"))
        XCTAssertEqual(release.page, URL(string: "https://github.com/o/r/releases/tag/v0.4.0"))
        XCTAssertEqual(release.notes, "What is new.\n\n- one\n- two")
    }

    func testABadFeedIsAnError() {
        XCTAssertThrowsError(try Updates.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try Updates.parse(Data(#"{"tag_name": "nightly"}"#.utf8)))
        XCTAssertNil(try? Updates.parse(Data(#"{"tag_name": "v1.0.0", "assets": []}"#.utf8)).zip)
    }

    // MARK: where the app is

    func testPlace() throws {
        XCTAssertEqual(Updates.place(of: URL(fileURLWithPath: "/usr/local/bin/flowriter")), .notAnApp)
        XCTAssertEqual(Updates.place(of: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Flowriter.app")), .translocated)
        let app = try makeApp(id: "app.flowriter.Test", version: "1.0.0", in: folder)
        XCTAssertEqual(Updates.place(of: app), .installable(app))
        let locked = folder.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let lockedApp = try makeApp(id: "app.flowriter.Test", version: "1.0.0", in: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(Updates.place(of: lockedApp), .readOnly(lockedApp))
    }

    // MARK: download and check

    func testStageDownloadsUnpacksAndChecksTheApp() async throws {
        let current = try makeApp(id: "app.flowriter.Test", version: "1.0.0", in: folder.appendingPathComponent("installed"))
        let release = try publish(id: "app.flowriter.Test", version: "1.1.0")
        let staging = folder.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = try await Updates.stage(release, current: current, in: staging)
        XCTAssertEqual(Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String, "1.1.0")
    }

    func testStageRefusesAnotherAppAnotherVersionOrABrokenSignature() async throws {
        let current = try makeApp(id: "app.flowriter.Test", version: "1.0.0", in: folder.appendingPathComponent("installed"))
        let staging = folder.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let other = try publish(id: "com.example.Other", version: "1.1.0")
        await assertThrows(try await Updates.stage(other, current: current, in: staging)) {
            guard case .mismatch = $0 else { return XCTFail("\($0)") }
        }

        var wrongVersion = try publish(id: "app.flowriter.Test", version: "1.1.0")
        wrongVersion.version = [1, 2, 0]
        await assertThrows(try await Updates.stage(wrongVersion, current: current, in: staging)) {
            guard case .mismatch = $0 else { return XCTFail("\($0)") }
        }

        let tampered = try publish(id: "app.flowriter.Test", version: "1.1.0") { app in
            try "changed after signing".write(to: app.appendingPathComponent("Contents/MacOS/Test"), atomically: true, encoding: .utf8)
        }
        await assertThrows(try await Updates.stage(tampered, current: current, in: staging)) {
            guard case .signature = $0 else { return XCTFail("\($0)") }
        }

        let noZip = Release(tag: "v1.1.0", version: [1, 1, 0], notes: "", page: URL(string: "https://x")!, zip: nil)
        await assertThrows(try await Updates.stage(noZip, current: current, in: staging)) { XCTAssertEqual($0, .noZip) }
    }

    // MARK: swap

    func testTheHelperSwapsTheAppAfterTheProcessQuits() throws {
        let destination = try makeApp(id: "app.flowriter.Test", version: "1.0.0", in: folder.appendingPathComponent("Applications"))
        let download = folder.appendingPathComponent("download")
        let new = try makeApp(id: "app.flowriter.Test", version: "1.1.0", in: download)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1"]
        try sleeper.run()
        let helper = try Updates.swapAfterQuit(new: new, into: destination, folder: download, pid: sleeper.processIdentifier, relaunch: false)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(version(destination), "1.0.0", "nothing moves while the app runs")
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertEqual(version(destination), "1.1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path), "the download folder goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".previous"))
    }

    // MARK: helpers

    /// A minimal signed app: an Info.plist and a script as its executable, signed ad hoc.
    @discardableResult
    private func makeApp(id: String, version: String, in parent: URL, change: ((URL) throws -> Void)? = nil) throws -> URL {
        let app = parent.appendingPathComponent("Flowriter.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "Test",
                                    "CFBundlePackageType": "APPL", "CFBundleName": "Flowriter"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = macOS.appendingPathComponent("Test")
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertEqual(Updates.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]), 0, "codesign")
        try change?(app)
        return app
    }

    private func publish(id: String, version: String, change: ((URL) throws -> Void)? = nil) throws -> Release {
        let source = folder.appendingPathComponent("release-\(UUID().uuidString)")
        let app = try makeApp(id: id, version: version, in: source, change: change)
        let zip = source.appendingPathComponent("Flowriter-\(version).zip")
        XCTAssertEqual(Updates.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]), 0, "zip")
        return Release(tag: "v" + version, version: Updates.version(version)!, notes: "", page: URL(string: "https://x")!, zip: zip)
    }

    private func version(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    private func assertThrows<T>(_ body: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
                                 _ check: (UpdateError) -> Void) async {
        do {
            _ = try await body()
            XCTFail("no error", file: file, line: line)
        } catch let error as UpdateError {
            check(error)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }
}
