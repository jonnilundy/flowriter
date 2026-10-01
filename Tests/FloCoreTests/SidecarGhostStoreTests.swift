import XCTest
@testable import FloCore

/// The ghost UI's store shape on top of the sidecar.
@MainActor
final class SidecarGhostStoreTests: XCTestCase {
    private var dir: URL!
    private var docPath: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-ghost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        docPath = dir.appendingPathComponent("post.md").path
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let doc = "Keep this. Trim this part. Keep that. And this tail."

    private func span(_ needle: String, proposed: Bool = false, in text: String? = nil) -> GhostSpan {
        let r = ((text ?? doc) as NSString).range(of: needle)
        return GhostSpan(from: r.location, to: NSMaxRange(r), proposed: proposed)
    }

    func testSaveLoadKeepsQuotesAndOtherSections() throws {
        // Another feature already stored an alternative and an overflow item.
        let session = SidecarSession(documentPath: docPath)
        session.loadIfNeeded(doc: doc)
        try session.update { sc in
            try sc.addAlternativeSet(level: .word, from: 0, to: 4, in: doc, id: "alt")
            sc.addOverflow("spare", id: "ov")
        }
        let store = SidecarGhostStore(session: session)
        store.saveSpans([span("Trim this part."), span("And this tail.", proposed: true)], doc: doc)
        XCTAssertNil(store.lastError)

        let json = try String(contentsOf: SidecarStore.url(for: URL(fileURLWithPath: docPath)), encoding: .utf8)
        XCTAssertTrue(json.contains("\"quote\": \"Trim this part.\""))
        XCTAssertTrue(json.contains("\"state\": \"proposed\""))

        // A fresh session (next launch) sees all three sections.
        let fresh = SidecarGhostStore(session: SidecarSession(documentPath: docPath))
        XCTAssertEqual(fresh.loadSpans(doc: doc), [span("Trim this part."), span("And this tail.", proposed: true)])
        XCTAssertNotNil(fresh.session.sidecar.alternativeSet("alt"))
        XCTAssertEqual(fresh.session.sidecar.overflow.map(\.id), ["ov"])
    }

    func testReanchorsAfterAnExternalEdit() throws {
        let store = SidecarGhostStore(session: SidecarSession(documentPath: docPath))
        store.saveSpans([span("Trim this part.")], doc: doc)
        let edited = "New first line.\n" + doc
        let reloaded = SidecarGhostStore(session: SidecarSession(documentPath: docPath))
        XCTAssertEqual(reloaded.loadSpans(doc: edited), [span("Trim this part.", in: edited)])
    }

    func testMetadataSurvivesSplitAndGrowth() throws {
        let session = SidecarSession(documentPath: docPath)
        session.loadIfNeeded(doc: doc)
        try session.update { sc in
            let r = (doc as NSString).range(of: "Trim this part. Keep that.")
            try sc.addGhost(from: r.location, to: NSMaxRange(r), author: .ai, state: .ghosted, source: "lab:trim-10", id: "g1")
        }
        let store = SidecarGhostStore(session: session)
        // The UI revived the middle: two spans; the larger overlap keeps the id and source.
        store.saveSpans([span("Trim this part."), span("that.")], doc: doc)
        let ghosts = session.sidecar.ghosts
        XCTAssertEqual(ghosts.count, 2)
        XCTAssertEqual(ghosts[0].id, "g1")
        XCTAssertEqual(ghosts[0].source, "lab:trim-10")
        XCTAssertEqual(ghosts[0].author, .ai)
        XCTAssertNotEqual(ghosts[1].id, "g1")
        XCTAssertEqual(ghosts[1].author, .me)
    }

    func testNoGhostsNoFile() {
        let store = SidecarGhostStore(session: SidecarSession(documentPath: docPath))
        store.saveSpans([], doc: doc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SidecarStore.url(for: URL(fileURLWithPath: docPath)).path))
        store.saveSpans([span("Keep this.")], doc: doc)
        store.saveSpans([], doc: doc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SidecarStore.url(for: URL(fileURLWithPath: docPath)).path))
    }

    func testSharedSessionIsOnePerPath() {
        XCTAssertTrue(SidecarSession.shared(for: docPath) === SidecarSession.shared(for: dir.path + "/./post.md"))
        SidecarSession.discard(documentPath: docPath)
    }
}
