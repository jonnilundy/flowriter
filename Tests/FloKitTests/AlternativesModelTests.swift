import XCTest
import FloCore
@testable import FloKit

/// Cycling, anchoring and undo logic of the alternatives session (no AppKit).
final class AlternativesModelTests: XCTestCase {
    let base = "The case holds a thumbtack, a ruler, and some string. None of it matters much."

    /// A document with a session, driven like the editor drives it: every change goes through
    /// `map` (or comes from `select`), then `record`.
    struct Doc {
        var text: String
        var session = AlternativesSession()
        var units: [UInt16] { Array(text.utf16) }
        init(_ t: String) { text = t; session.record(doc: units) }

        mutating func apply(_ changes: [Change], own: Bool = false) -> [Change] {
            let old = units
            let cs = ChangeSet(changes, docLength: old.count)
            let inverse = cs.invert(Text(units: old)).changes
            text = cs.apply(to: Text(units: old)).string
            if !own { session.map(cs, old: old) }
            session.record(doc: units)
            return inverse
        }

        /// Undo `inverse` like the editor does: map, then restore the recorded anchors.
        mutating func undo(_ inverse: [Change]) -> [Change] {
            let old = units, oldSets = session.sets
            let cs = ChangeSet(inverse, docLength: old.count)
            let redo = cs.invert(Text(units: old)).changes
            text = cs.apply(to: Text(units: old)).string
            session.map(cs, old: old)
            session.restore(doc: units, old: old, oldSets: oldSets)
            session.record(doc: units)
            return redo
        }

        /// Add a version (the layer records the anchors right after, as here).
        mutating func add(_ text: String, _ author: SidecarAuthor = .me, _ level: AlternativeLevel, _ r: NSRange) throws -> (String, String) {
            let ids = try session.addVersion(text, author: author, level: level, range: r, doc: self.text)
            session.record(doc: units)
            return ids
        }

        mutating func show(_ v: String, _ s: String) -> [Change] {
            let change = try! session.select(v, in: s, doc: units)!
            return apply(change.changes, own: true)
        }

        func shown(_ s: String) -> String {
            let set = session.set(s)!
            return String(text.utf16.dropFirst(set.from).prefix(set.to - set.from))!
        }
    }

    func range(_ d: Doc, _ s: String) -> NSRange { (d.text as NSString).range(of: s) }

    func testAddVersionShowsItAndFixesTheArticle() throws {
        var d = Doc(base)
        let (sid, eraser) = try d.add("eraser", .me, .word, range(d, "thumbtack"))
        XCTAssertEqual(d.session.set(sid)!.variants.map(\.text), ["thumbtack", "eraser"])
        XCTAssertTrue(d.session.set(sid)!.visible)
        _ = d.show(eraser, sid)
        XCTAssertTrue(d.text.contains("holds an eraser, a ruler"), d.text)
        XCTAssertEqual(d.shown(sid), "eraser")
        XCTAssertFalse(d.session.set(sid)!.showsOriginal)
        // back to the original: the article follows
        _ = d.show(d.session.set(sid)!.originalId, sid)
        XCTAssertTrue(d.text.contains("holds a thumbtack, a ruler"), d.text)
        XCTAssertTrue(d.session.set(sid)!.showsOriginal)
    }

    func testCycleWrapsBothWays() throws {
        var d = Doc(base)
        let r = range(d, "thumbtack")
        let (sid, _) = try d.add("eraser", .me, .word, r)
        _ = try d.add("pushpin", .ai, .word, r)
        var seen: [String] = []
        for _ in 0..<4 {
            _ = d.show(d.session.stepped(sid, 1)!, sid)
            seen.append(d.shown(sid))
        }
        XCTAssertEqual(seen, ["eraser", "pushpin", "thumbtack", "eraser"])
        _ = d.show(d.session.stepped(sid, -1)!, sid)
        XCTAssertEqual(d.shown(sid), "thumbtack")
        _ = d.show(d.session.stepped(sid, -1)!, sid)
        XCTAssertEqual(d.shown(sid), "pushpin")
        XCTAssertTrue(d.text.contains("holds a pushpin,"), d.text)
    }

    func testSwapLeavesEverythingOutsideTheRangeAlone() throws {
        var d = Doc(base)
        let r = range(d, "None of it matters much.")
        let (sid, v) = try d.add("Nothing in it is precious.", .me, .sentence, r)
        let before = d.text
        _ = d.show(v, sid)
        let head = String(before.utf16.prefix(r.location))!
        XCTAssertTrue(d.text.hasPrefix(head))
        XCTAssertEqual(d.text, head + "Nothing in it is precious.")
    }

    func testTypingOutsideShiftsAndInsideEditsTheShownVersion() throws {
        var d = Doc(base)
        let r = range(d, "thumbtack")
        let (sid, eraser) = try d.add("eraser", .me, .word, r)
        _ = d.apply([Change(from: 0, insert: "Now ")])                                // before: shifts
        XCTAssertEqual(d.shown(sid), "thumbtack")
        let s = d.session.set(sid)!
        _ = d.apply([Change(from: s.to, insert: "s")])                                // at the end: stays outside
        XCTAssertEqual(d.shown(sid), "thumbtack")
        _ = d.apply([Change(from: s.from + 5, insert: "-")])                          // inside: grows
        XCTAssertEqual(d.shown(sid), "thumb-tack")
        _ = d.show(eraser, sid)                                                       // the edit is kept in its version
        XCTAssertEqual(d.session.set(sid)!.variants.first!.text, "thumb-tack")
    }

    func testUndoAndRedoOfASwapRestoreTheCurrentVersion() throws {
        var d = Doc(base)
        let (sid, eraser) = try d.add("eraser", .me, .word, range(d, "thumbtack"))
        let undoSwap = d.show(eraser, sid)
        XCTAssertEqual(d.session.set(sid)!.currentId, eraser)
        let redo = d.undo(undoSwap)
        XCTAssertEqual(d.text, base)
        XCTAssertEqual(d.session.set(sid)!.currentId, d.session.set(sid)!.originalId)
        XCTAssertEqual(d.shown(sid), "thumbtack")
        _ = d.undo(redo)
        XCTAssertEqual(d.session.set(sid)!.currentId, eraser)
        XCTAssertTrue(d.text.contains("an eraser"))
        XCTAssertEqual(d.session.set(sid)!.variants.map { AlternativesSession.text(of: $0, in: d.session.set(sid)!, doc: d.units) }, ["thumbtack", "eraser"])
    }

    func testDeletingTheWholeTextDropsTheSetAndUndoBringsItBack() throws {
        var d = Doc(base)
        let r = range(d, "a thumbtack, ")
        let (sid, _) = try d.add("eraser", .me, .word, range(d, "thumbtack"))
        let undoDelete = d.apply([Change(from: r.location, to: NSMaxRange(r))])
        XCTAssertNil(d.session.set(sid))
        _ = d.undo(undoDelete)
        XCTAssertEqual(d.text, base)
        XCTAssertEqual(d.shown(sid), "thumbtack")
        XCTAssertEqual(d.session.set(sid)!.variants.count, 2)
    }

    func testRetypingTheRangeWithAVersionSwitchesToIt() throws {
        var d = Doc(base)
        let r = range(d, "thumbtack")
        let (sid, eraser) = try d.add("eraser", .me, .word, r)
        _ = d.apply([Change(from: r.location, to: NSMaxRange(r), insert: "eraser")])
        XCTAssertEqual(d.session.set(sid)!.currentId, eraser)
        XCTAssertEqual(d.session.set(sid)!.variants.first!.text, "thumbtack")
    }

    func testEnclosingSentenceFollowsAWordSwap() throws {
        var d = Doc(base)
        let sentence = range(d, "The case holds a thumbtack, a ruler, and some string.")
        let (ss, _) = try d.add("It holds odds and ends.", .me, .sentence, sentence)
        let (ws, eraser) = try d.add("eraser", .me, .word, range(d, "thumbtack"))
        _ = d.show(eraser, ws)
        XCTAssertEqual(d.shown(ss), "The case holds an eraser, a ruler, and some string.")
    }

    func testRemovingVersionsDownToOneRemovesTheSet() throws {
        var d = Doc(base)
        let r = range(d, "thumbtack")
        let (sid, eraser) = try d.add("eraser", .me, .word, r)
        let (_, pushpin) = try d.add("pushpin", .me, .word, r)
        XCTAssertThrowsError(try d.session.remove(d.session.set(sid)!.currentId, from: sid))   // the shown one: select another first
        try d.session.remove(pushpin, from: sid)
        XCTAssertEqual(d.session.set(sid)!.variants.count, 2)
        try d.session.remove(eraser, from: sid)
        XCTAssertNil(d.session.set(sid))
        XCTAssertEqual(d.text, base)
    }

    func testEditingAnAIVersionMakesItTheWriters() throws {
        var d = Doc(base)
        let r = range(d, "thumbtack")
        let (sid, ai) = try d.add("pushpin", .ai, .word, r)
        _ = d.show(ai, sid)
        XCTAssertEqual(d.session.claimEditedVersions(doc: d.units), [])
        let s = d.session.set(sid)!
        _ = d.apply([Change(from: s.from + 4, insert: "-")])
        XCTAssertEqual(d.session.claimEditedVersions(doc: d.units), [sid])
        let v = d.session.set(sid)!.variants.first { $0.id == ai }!
        XCTAssertEqual(v.author, .me)
        XCTAssertEqual(v.text, "push-pin")
    }

    func testUndoingTheEditGivesTheAIVersionBack() throws {
        var d = Doc(base)
        let (sid, ai) = try d.add("pushpin", .ai, .word, range(d, "thumbtack"))
        _ = d.show(ai, sid)
        let s = d.session.set(sid)!
        let undoEdit = d.apply([Change(from: s.from + 4, insert: "-")])
        d.session.claimEditedVersions(doc: d.units)
        d.session.record(doc: d.units)
        XCTAssertEqual(d.session.set(sid)!.variants.first { $0.id == ai }!.author, .me)
        _ = d.undo(undoEdit)
        XCTAssertEqual(d.shown(sid), "pushpin")
        XCTAssertEqual(d.session.set(sid)!.variants.first { $0.id == ai }!.author, .ai)
    }

    func testTextUnits() {
        let t = "# Title\n\n- The case holds a thumbtack. None of it matters much.\n\nPlain words here." as NSString
        let p = t.range(of: "thumbtack").location + 3
        XCTAssertEqual(t.substring(with: AltText.word(in: t, at: p)!), "thumbtack")
        XCTAssertEqual(t.substring(with: AltText.sentence(in: t, at: p)!), "The case holds a thumbtack.")
        XCTAssertEqual(t.substring(with: AltText.paragraph(in: t, at: p)!), "The case holds a thumbtack. None of it matters much.")
        let q = t.range(of: "matters").location
        XCTAssertEqual(t.substring(with: AltText.sentence(in: t, at: q)!), "None of it matters much.")
        XCTAssertEqual(t.substring(with: AltText.paragraph(in: t, at: 3)!), "Title")
        XCTAssertNil(AltText.paragraph(in: t, at: 8))
        // caret right after a word counts as that word
        XCTAssertEqual(t.substring(with: AltText.word(in: t, at: t.range(of: "thumbtack").location + 9)!), "thumbtack")
        XCTAssertEqual(AltText.level(of: t.range(of: "thumbtack"), in: t), .word)
        XCTAssertEqual(AltText.level(of: t.range(of: "None of it matters much."), in: t), .sentence)
        XCTAssertEqual(AltText.level(of: t.range(of: "Plain words here."), in: t), .paragraph)
    }
}
