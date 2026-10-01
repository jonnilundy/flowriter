import XCTest
@testable import FloCore

/// The sidecar side of the shared edit hook: exact-range replacements keep a set, `follow`
/// applies an edit once per session, `reanchor` after a reload, and FloCore's isolateHistory.
@MainActor
final class SidecarSessionFollowTests: XCTestCase {
    let text = "The case holds a thumbtack, a ruler."

    func testReplacingExactlyASetKeepsItAndPicksTheMatchingVariant() throws {
        var sc = DocumentSidecar()
        let r = (text as NSString).range(of: "thumbtack")
        let set = try sc.addAlternativeSet(level: .word, from: r.location, to: NSMaxRange(r), in: text)
        let pin = try sc.addVariant(to: set.id, text: "pushpin", author: .ai)
        let g = try sc.addGhost(from: r.location, to: NSMaxRange(r))

        // the undo of a swap: exactly the range, with another variant's text
        let old = Array(text.utf16)
        let res = sc.applyEdit(Change(from: r.location, to: NSMaxRange(r), insert: "pushpin"), old: old)
        let s = try XCTUnwrap(sc.alternativeSet(set.id))
        XCTAssertEqual(s.anchor.from, r.location)
        XCTAssertEqual(s.anchor.to, r.location + 7)
        XCTAssertEqual(s.currentId, pin.id, "the text in the range is that variant now")
        XCTAssertEqual(s.original?.text, "thumbtack", "the variant that left keeps its text")
        XCTAssertEqual(res.droppedGhosts, [g.id], "a ghost typed over whole is new writing: dropped")

        // retyped with new words: the set stays, current variant unchanged
        let after = sc.applyEdit(Change(from: s.anchor.from, to: s.anchor.to, insert: "tack"))
        XCTAssertTrue(after.droppedAlternatives.isEmpty)
        XCTAssertEqual(sc.alternativeSet(set.id)?.anchor.length, 4)
        // deleted whole: dropped
        XCTAssertEqual(sc.applyEdit(Change(from: r.location, to: r.location + 4)).droppedAlternatives, [set.id])
    }

    func testUpdateVariantAndSetAnchor() throws {
        var sc = DocumentSidecar()
        let set = try sc.addAlternativeSet(level: .word, from: 4, to: 8, in: text)
        let v = try sc.addVariant(to: set.id, text: "box", author: .ai)
        try sc.updateVariant(v.id, in: set.id, text: "tin", author: .me)
        XCTAssertEqual(sc.alternativeSet(set.id)?.variants.last?.text, "tin")
        XCTAssertEqual(sc.alternativeSet(set.id)?.variants.last?.author, .me)
        try sc.setAnchor(of: set.id, from: 5, to: 9)
        XCTAssertEqual(sc.alternativeSet(set.id)?.anchor.from, 5)
        XCTAssertThrowsError(try sc.updateVariant("nope", in: set.id, text: "x"))
        XCTAssertThrowsError(try sc.setAnchor(of: set.id, from: 3, to: 3))
    }

    func testFollowAppliesAnEditOncePerSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("follow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = SidecarSession(documentPath: dir.appendingPathComponent("p.md").path)
        session.load(doc: text)
        session.update { _ = try? $0.addGhost(from: 9, to: 14) }
        let old = Array(text.utf16), new = Array(("X" + text).utf16)
        XCTAssertNotNil(session.follow([Change(from: 0, insert: "X")], old: old, new: new))
        XCTAssertEqual(session.sidecar.ghosts[0].anchor.from, 10)
        // a second editor on the same document reports the same keystroke: ignored
        XCTAssertNil(session.follow([Change(from: 0, insert: "X")], old: old, new: new))
        XCTAssertEqual(session.sidecar.ghosts[0].anchor.from, 10)
        XCTAssertEqual(session.followCount, 1)
        XCTAssertEqual(session.anchoredText, new)

        // an outside edit, then a reload: found again by quote
        let moved = "Intro.\n" + "X" + text
        let r = try XCTUnwrap(session.reanchor(to: moved))
        XCTAssertTrue(r.unresolved.isEmpty)
        XCTAssertEqual(session.sidecar.ghosts[0].anchor.from, 17)
        XCTAssertNil(session.reanchor(to: moved), "unchanged text: nothing to do")
    }

    func testIsolateHistoryKeepsTheNextTypingOutOfTheSwapsUndoStep() {
        func run(isolate: IsolateHistory?) -> String {
            let env = CommandEnv(time: 1000)
            let s = EditorSession(state: EditorState(doc: Text("a word here"), selection: .cursor(6)), env: env)
            s.dispatch(TransactionSpec(changes: [Change(from: 2, to: 6, insert: "term")], userEvent: "input.type", isolateHistory: isolate))
            env.time = 1100   // 100 ms later, touching the change: joins unless isolated
            s.dispatch(TransactionSpec(changes: [Change(from: 6, insert: "s")], selection: .cursor(7), userEvent: "input.type"))
            _ = s.handle("Mod-z")
            return s.state.doc.string
        }
        XCTAssertEqual(run(isolate: nil), "a word here", "grouped: one undo takes both")
        XCTAssertEqual(run(isolate: .full), "a term here", "isolated: the typing is its own step")
        XCTAssertEqual(run(isolate: .after), "a term here")
    }
}
