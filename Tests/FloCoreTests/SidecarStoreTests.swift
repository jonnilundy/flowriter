import XCTest
@testable import FloCore

/// Sidecar file IO and re-anchoring after edits made outside the app.
final class SidecarStoreTests: XCTestCase {
    private var dir: URL!
    private var doc: URL!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        doc = dir.appendingPathComponent("post.md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var sidecarPath: String { SidecarStore.url(for: doc).path }

    private func range(of needle: String, in s: String) -> (Int, Int) {
        let r = (s as NSString).range(of: needle)
        precondition(r.location != NSNotFound, needle)
        return (r.location, r.location + r.length)
    }

    private func slice(_ s: String, _ a: TextAnchor) -> String {
        String(utf16CodeUnits: Array(Array(s.utf16)[a.from..<a.to]), count: a.length)
    }

    private let post = """
    # Tools

    Pin it with a thumbtack. It holds the note in place.

    The second paragraph talks about the desk. The desk is old.

    The third paragraph is short.

    """

    /// A sidecar with one of everything, on `post`.
    private func sample() throws -> DocumentSidecar {
        var sc = DocumentSidecar()
        let (f, t) = range(of: "thumbtack", in: post)
        let set = try sc.addAlternativeSet(level: .word, from: f, to: t, in: post, id: "alt1", now: t0)
        try sc.addVariant(to: set.id, text: "eraser", author: .ai, id: "v2", now: t0.addingTimeInterval(60))
        let (gf, gt) = range(of: "The desk is old.", in: post)
        try sc.addGhost(from: gf, to: gt, author: .me, id: "gh1", now: t0)
        let (pf, pt) = range(of: "The third paragraph is short.", in: post)
        try sc.addGhost(from: pf, to: pt, author: .ai, state: .proposed, source: "lab:trim-10", id: "gh2", now: t0)
        sc.addOverflow("A spare line with \"quotes\", a tab\tand an emoji 😀\nsecond line", id: "ov1", now: t0)
        return sc
    }

    // MARK: File and format

    func testFileNameIsHiddenNextToTheDocument() {
        XCTAssertEqual(SidecarStore.url(for: URL(fileURLWithPath: "/a/b/post.md")).path, "/a/b/.post.md.flowriter.json")
        XCTAssertTrue(FileWatchSkips.hidden("/a/b/.post.md.flowriter.json", root: "/a"))
    }

    func testNoFileForAnEmptySidecar() throws {
        XCTAssertEqual(try SidecarStore.save(DocumentSidecar(), for: doc, documentText: post), .skipped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath))
        let loaded = SidecarStore.load(for: doc, documentText: post)
        XCTAssertEqual(loaded.status, .missing)
        XCTAssertTrue(loaded.sidecar.isEmpty)
    }

    func testEmptiedSidecarRemovesTheFile() throws {
        var sc = try sample()
        XCTAssertEqual(try SidecarStore.save(sc, for: doc, documentText: post), .written)
        sc = DocumentSidecar()
        XCTAssertEqual(try SidecarStore.save(sc, for: doc, documentText: post), .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath))
    }

    func testRoundTripIsByteStable() throws {
        let sc = try sample()
        try SidecarStore.save(sc, for: doc, documentText: post)
        let first = try Data(contentsOf: SidecarStore.url(for: doc))

        let loaded = SidecarStore.load(for: doc, documentText: post)
        XCTAssertEqual(loaded.status, .loaded)
        XCTAssertEqual(loaded.unresolved, [])
        XCTAssertEqual(loaded.moved, [])
        XCTAssertEqual(loaded.sidecar, sc.refreshed(in: post))

        try SidecarStore.save(loaded.sidecar, for: doc, documentText: post)
        let second = try Data(contentsOf: SidecarStore.url(for: doc))
        XCTAssertEqual(first, second)

        // decode -> encode without the store, too.
        let decoded = try SidecarCodec.decode(first)
        XCTAssertEqual(SidecarCodec.encode(decoded.sidecar, documentText: post), first)
        XCTAssertEqual(decoded.documentSHA256, SidecarStore.sha256(post))
    }

    func testFormatSnapshot() throws {
        let text = "Pin it with a thumbtack."
        var sc = DocumentSidecar()
        let set = try sc.addAlternativeSet(level: .word, from: 14, to: 23, in: text, id: "alt1", now: t0)
        try sc.addVariant(to: set.id, text: "eraser", author: .ai, id: "v2", now: t0)
        try sc.addGhost(from: 0, to: 6, author: .ai, state: .proposed, source: "lab:trim-10", id: "gh1", now: t0)
        sc.addOverflow("spare", id: "ov1", now: t0)
        let json = String(decoding: SidecarCodec.encode(sc.refreshed(in: text), documentText: text), as: UTF8.self)
        let originalId = set.originalId
        XCTAssertEqual(json, """
        {
          "schemaVersion": 1,
          "documentSHA256": "\(SidecarStore.sha256(text))",
          "alternatives": [
            {
              "id": "alt1",
              "level": "word",
              "anchor": {
                "from": 14,
                "to": 23,
                "quote": "thumbtack",
                "prefix": "Pin it with a ",
                "suffix": "."
              },
              "originalId": "\(originalId)",
              "currentId": "\(originalId)",
              "variants": [
                {
                  "id": "\(originalId)",
                  "text": "thumbtack",
                  "author": "me",
                  "createdAt": "2026-09-21T14:13:20Z"
                },
                {
                  "id": "v2",
                  "text": "eraser",
                  "author": "ai",
                  "createdAt": "2026-09-21T14:13:20Z"
                }
              ]
            }
          ],
          "ghosts": [
            {
              "id": "gh1",
              "anchor": {
                "from": 0,
                "to": 6,
                "quote": "Pin it",
                "prefix": "",
                "suffix": " with a thumbtack."
              },
              "author": "ai",
              "state": "proposed",
              "createdAt": "2026-09-21T14:13:20Z",
              "source": "lab:trim-10"
            }
          ],
          "overflow": [
            {
              "id": "ov1",
              "text": "spare",
              "createdAt": "2026-09-21T14:13:20Z",
              "order": 0
            }
          ]
        }

        """)
    }

    // MARK: Corrupt and foreign files

    func testCorruptFilesAreBackedUpAndNeverCrash() throws {
        let bad: [String] = [
            "", "{", "not json", "[]", "{\"schemaVersion\": \"one\"}", "{\"alternatives\": []}",
            "{\"schemaVersion\": 1, \"ghosts\": {}}",
            "{\"schemaVersion\": 1, \"ghosts\": [{\"id\": \"g\"}]}",
            "{\"schemaVersion\": 1, \"ghosts\": [{\"id\": \"g\", \"anchor\": {\"from\": 5, \"to\": 2, \"quote\": \"x\"}, \"author\": \"me\", \"state\": \"ghosted\", \"createdAt\": \"2026-09-30T00:00:00Z\"}]}",
            "{\"schemaVersion\": 1, \"ghosts\": [{\"id\": \"g\", \"anchor\": {\"from\": 0, \"to\": 2, \"quote\": \"x\"}, \"author\": \"robot\", \"state\": \"ghosted\", \"createdAt\": \"2026-09-30T00:00:00Z\"}]}",
            "{\"schemaVersion\": 1, \"alternatives\": [{\"id\": \"a\", \"level\": \"word\", \"anchor\": {\"from\": 0, \"to\": 2, \"quote\": \"x\"}, \"originalId\": \"v\", \"currentId\": \"missing\", \"variants\": [{\"id\": \"v\", \"text\": \"x\", \"author\": \"me\", \"createdAt\": \"2026-09-30T00:00:00Z\"}]}]}",
            "{\"schemaVersion\": 1, \"overflow\": [{\"id\": \"o\", \"text\": \"x\", \"createdAt\": \"yesterday\", \"order\": 0}]}",
        ]
        for (i, content) in bad.enumerated() {
            let raw = Data(content.utf8) + (i == 0 ? Data([0xFF, 0xFE, 0x00]) : Data())
            try raw.write(to: SidecarStore.url(for: doc))
            let r = SidecarStore.load(for: doc, documentText: post)
            XCTAssertEqual(r.status, .recoveredFromCorrupt(backup: SidecarStore.backupURL(for: doc)), "case \(i): \(content)")
            XCTAssertTrue(r.sidecar.isEmpty, "case \(i)")
            XCTAssertEqual(try Data(contentsOf: SidecarStore.backupURL(for: doc)), raw, "case \(i): backup holds the bad bytes")
        }
        // The next save replaces the broken file and keeps the backup.
        try SidecarStore.save(try sample(), for: doc, documentText: post)
        XCTAssertEqual(SidecarStore.load(for: doc, documentText: post).status, .loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SidecarStore.backupURL(for: doc).path))
    }

    func testNewerSchemaIsBackedUp() throws {
        try Data("{\"schemaVersion\": 2, \"future\": true}".utf8).write(to: SidecarStore.url(for: doc))
        let r = SidecarStore.load(for: doc, documentText: post)
        XCTAssertEqual(r.status, .newerSchema(version: 2, backup: SidecarStore.backupURL(for: doc)))
        XCTAssertTrue(r.sidecar.isEmpty)
    }

    func testFractionalSecondsFromOtherWritersAreAccepted() throws {
        let json = """
        {"schemaVersion": 1, "overflow": [{"id": "o", "text": "x", "createdAt": "2026-09-30T10:00:00.750Z", "order": 3}]}
        """
        try Data(json.utf8).write(to: SidecarStore.url(for: doc))
        let r = SidecarStore.load(for: doc, documentText: post)
        XCTAssertEqual(r.status, .loaded)
        XCTAssertEqual(r.sidecar.overflow.first?.createdAt, SidecarCodec.parseDate("2026-09-30T10:00:00Z"))
    }

    // MARK: Re-anchoring after external edits

    private func saveSample() throws -> DocumentSidecar {
        let sc = try sample()
        try SidecarStore.save(sc, for: doc, documentText: post)
        return sc
    }

    func testUnchangedDocumentIsExact() throws {
        _ = try saveSample()
        let r = SidecarStore.load(for: doc, documentText: post)
        XCTAssertEqual(r.moved, [])
        XCTAssertEqual(r.sidecar.alternatives.count, 1)
        XCTAssertEqual(r.sidecar.ghosts.count, 2)
    }

    func testMovedParagraph() throws {
        _ = try saveSample()
        let edited = """
        # Tools

        The third paragraph is short.

        The second paragraph talks about the desk. The desk is old.

        Pin it with a thumbtack. It holds the note in place.

        """
        let r = SidecarStore.load(for: doc, documentText: edited)
        XCTAssertEqual(r.unresolved, [])
        XCTAssertEqual(Set(r.moved), ["alt1", "gh1", "gh2"])
        XCTAssertEqual(slice(edited, r.sidecar.alternativeSet("alt1")!.anchor), "thumbtack")
        XCTAssertEqual(slice(edited, r.sidecar.ghost("gh1")!.anchor), "The desk is old.")
        XCTAssertEqual(slice(edited, r.sidecar.ghost("gh2")!.anchor), "The third paragraph is short.")
    }

    func testEditedNearbyTextAndRepeatedQuote() throws {
        // "desk" occurs twice; an alternative on the second one must stay on the second one
        // after words before both change.
        var sc = DocumentSidecar()
        let second = (post as NSString).range(of: "desk", options: .backwards)
        let set = try sc.addAlternativeSet(level: .word, from: second.location, to: NSMaxRange(second), in: post, id: "desk2", now: t0)
        try SidecarStore.save(sc, for: doc, documentText: post)

        let edited = post
            .replacingOccurrences(of: "Pin it with a thumbtack.", with: "Fix it with a pin, quickly.")
            .replacingOccurrences(of: "talks about", with: "is all about")
        let r = SidecarStore.load(for: doc, documentText: edited)
        XCTAssertEqual(r.unresolved, [])
        XCTAssertEqual(r.moved, [set.id])
        let a = r.sidecar.alternativeSet(set.id)!.anchor
        XCTAssertEqual(a.from, (edited as NSString).range(of: "desk", options: .backwards).location)
    }

    func testDeletedTargetIsReportedAndKept() throws {
        _ = try saveSample()
        let edited = post.replacingOccurrences(of: " The desk is old.", with: "")
        let r = SidecarStore.load(for: doc, documentText: edited)
        XCTAssertEqual(r.unresolved, [UnresolvedAnchorReport(kind: .ghost, id: "gh1", quote: "The desk is old.", reason: .notFound)])
        XCTAssertNil(r.sidecar.ghost("gh1"))
        XCTAssertEqual(r.sidecar.unresolved.ghosts.map(\.id), ["gh1"])
        XCTAssertNotNil(r.sidecar.ghost("gh2"))

        // Saved with the unresolved item, and found again once the text is back.
        try SidecarStore.save(r.sidecar, for: doc, documentText: edited)
        let json = try String(contentsOf: SidecarStore.url(for: doc), encoding: .utf8)
        XCTAssertTrue(json.contains("\"unresolved\""))
        let back = SidecarStore.load(for: doc, documentText: post)
        XCTAssertEqual(back.unresolved, [])
        XCTAssertEqual(slice(post, back.sidecar.ghost("gh1")!.anchor), "The desk is old.")
        XCTAssertTrue(back.sidecar.unresolved.isEmpty)
    }

    func testAmbiguousQuoteIsReportedNotGuessed() throws {
        // The same block twice, longer than the stored context on both sides of "one".
        let block = "lorem ipsum dolor sit amet, consectetur; one; adipiscing elit, sed do eiusmod tempor.\n"
        let text = block + block
        let second = (text as NSString).range(of: "one", options: .backwards)
        var sc = DocumentSidecar()
        try sc.addGhost(from: second.location, to: NSMaxRange(second), id: "g", now: t0)
        try SidecarStore.save(sc, for: doc, documentText: text)
        let r = SidecarStore.load(for: doc, documentText: "Intro.\n" + text)
        XCTAssertEqual(r.unresolved.map(\.reason), [.ambiguous])
        XCTAssertEqual(r.sidecar.unresolved.ghosts.map(\.id), ["g"])
    }

    func testEditInsideTargetIsNotFound() throws {
        _ = try saveSample()
        let edited = post.replacingOccurrences(of: "thumbtack", with: "thumb tack")
        let r = SidecarStore.load(for: doc, documentText: edited)
        XCTAssertEqual(r.unresolved.map(\.id), ["alt1"])
        XCTAssertEqual(r.unresolved.first?.reason, .notFound)
    }
}

/// The workspace watcher and file index skip dot entries; the sidecar relies on that.
private enum FileWatchSkips {
    static func hidden(_ path: String, root: String) -> Bool { WorkspaceWatcherModel.shouldIgnore(path, root: root) }
}
