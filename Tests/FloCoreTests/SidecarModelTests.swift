import XCTest
@testable import FloCore

/// Alternatives, articles, ghosts and overflow on the model (no IO).
final class SidecarModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func slice(_ s: String, _ a: TextAnchor) -> String {
        let u = Array(s.utf16)
        return String(utf16CodeUnits: Array(u[a.from..<a.to]), count: a.length)
    }

    private func range(of needle: String, in s: String) -> (Int, Int) {
        let r = (s as NSString).range(of: needle)
        return (r.location, r.location + r.length)
    }

    // MARK: Alternatives

    func testCycleVariantsFixesArticleAndFollowsAnchors() throws {
        var text = "Pin it with a thumbtack. Then go home."
        var sc = DocumentSidecar()
        let (f, t) = range(of: "thumbtack", in: text)
        let set = try sc.addAlternativeSet(level: .word, from: f, to: t, in: text, now: t0)
        let eraser = try sc.addVariant(to: set.id, text: "eraser", author: .ai, now: t0)
        let (sf, st) = range(of: "Pin it with a thumbtack.", in: text)
        let sentence = try sc.addAlternativeSet(level: .sentence, from: sf, to: st, in: text, now: t0)
        let (gf, gt) = range(of: "Then go home.", in: text)
        let ghost = try sc.addGhost(from: gf, to: gt, now: t0)

        let change = try XCTUnwrap(try sc.selectVariant(eraser.id, in: set.id, text: text))
        text = change.text
        XCTAssertEqual(text, "Pin it with an eraser. Then go home.")
        XCTAssertEqual(change.changes.count, 2)
        XCTAssertEqual(slice(text, sc.alternativeSet(set.id)!.anchor), "eraser")
        XCTAssertEqual(slice(text, sc.alternativeSet(sentence.id)!.anchor), "Pin it with an eraser.")
        XCTAssertEqual(slice(text, sc.ghost(ghost.id)!.anchor), "Then go home.")
        XCTAssertEqual(sc.alternativeSet(set.id)?.currentId, eraser.id)
        XCTAssertEqual(sc.alternativeSet(set.id)?.originalId, set.originalId)

        // Cycling wraps back to the original, and the article goes back too.
        text = try XCTUnwrap(try sc.cycleVariant(in: set.id, by: 1, text: text)).text
        XCTAssertEqual(text, "Pin it with a thumbtack. Then go home.")
        XCTAssertEqual(slice(text, sc.alternativeSet(sentence.id)!.anchor), "Pin it with a thumbtack.")
        XCTAssertEqual(slice(text, sc.ghost(ghost.id)!.anchor), "Then go home.")
        XCTAssertNil(try sc.selectVariant(set.originalId, in: set.id, text: text), "already current")
    }

    func testArticleAtSentenceStartStaysInsideSentenceSet() throws {
        var text = "A thumbtack holds it."
        var sc = DocumentSidecar()
        let (f, t) = range(of: "thumbtack", in: text)
        let word = try sc.addAlternativeSet(level: .word, from: f, to: t, in: text)
        let sentence = try sc.addAlternativeSet(level: .sentence, from: 0, to: text.utf16.count, in: text)
        let v = try sc.addVariant(to: word.id, text: "eraser", author: .me)
        text = try XCTUnwrap(try sc.selectVariant(v.id, in: word.id, text: text)).text
        XCTAssertEqual(text, "An eraser holds it.")
        XCTAssertEqual(slice(text, sc.alternativeSet(sentence.id)!.anchor), "An eraser holds it.")
    }

    func testTypingInsideAVariantUpdatesItOnSave() throws {
        var text = "a big dog"
        var sc = DocumentSidecar()
        let set = try sc.addAlternativeSet(level: .word, from: 2, to: 5, in: text)
        let edit = Change(from: 4, to: 4, insert: "g")   // "big" -> "bigg"
        sc.applyEdit(edit)
        text = DocumentSidecar.applying([edit], to: text)
        let saved = sc.refreshed(in: text)
        XCTAssertEqual(saved.alternativeSet(set.id)?.current?.text, "bigg")
        XCTAssertEqual(saved.alternativeSet(set.id)?.anchor.quote, "bigg")
        XCTAssertEqual(saved.alternativeSet(set.id)?.anchor.prefix, "a ")
        XCTAssertEqual(saved.alternativeSet(set.id)?.anchor.suffix, " dog")
    }

    func testSwapKeepsTextTypedInsideTheCurrentVariant() throws {
        var text = "a big dog"
        var sc = DocumentSidecar()
        let set = try sc.addAlternativeSet(level: .word, from: 2, to: 5, in: text)
        let huge = try sc.addVariant(to: set.id, text: "huge", author: .ai)
        let typed = Change(from: 5, to: 5, insert: "")   // no-op, then a real edit inside
        sc.applyEdit(typed)
        let edit = Change(from: 3, to: 4, insert: "u")   // "big" -> "bug"
        sc.applyEdit(edit)
        text = DocumentSidecar.applying([edit], to: text)
        text = try XCTUnwrap(try sc.selectVariant(huge.id, in: set.id, text: text)).text
        XCTAssertEqual(text, "a huge dog")
        text = try XCTUnwrap(try sc.selectVariant(set.originalId, in: set.id, text: text)).text
        XCTAssertEqual(text, "a bug dog")
    }

    func testRemoveVariantRules() throws {
        let text = "one"
        var sc = DocumentSidecar()
        let set = try sc.addAlternativeSet(level: .word, from: 0, to: 3, in: text, now: t0)
        let two = try sc.addVariant(to: set.id, text: "two", author: .ai, now: t0.addingTimeInterval(1))
        _ = try sc.addVariant(to: set.id, text: "three", author: .ai, now: t0.addingTimeInterval(2))
        XCTAssertThrowsError(try sc.removeVariant(set.currentId, from: set.id)) { XCTAssertEqual($0 as? SidecarError, .cannotRemoveCurrentVariant) }
        _ = try sc.selectVariant(two.id, in: set.id, text: text)
        try sc.removeVariant(set.originalId, from: set.id)
        XCTAssertEqual(sc.alternativeSet(set.id)?.originalId, two.id, "oldest remaining becomes the original")
    }

    func testDeletingTheWholeRangeDropsTheSet() throws {
        var sc = DocumentSidecar()
        let set = try sc.addAlternativeSet(level: .word, from: 4, to: 9, in: "the quick fox")
        let r = sc.applyEdit(Change(from: 3, to: 10, insert: ""))
        XCTAssertEqual(r.droppedAlternatives, [set.id])
        XCTAssertTrue(sc.isEmpty)
    }

    // MARK: Articles

    func testArticleRules() {
        let cases: [(String, Bool)] = [
            ("eraser", true), ("thumbtack", false), ("hour", true), ("honest mistake", true), ("heir", true),
            ("house", false), ("university", false), ("unicorn", false), ("user", false), ("usual", false),
            ("euro", false), ("one-time fee", false), ("once-a-year", false), ("umbrella", true),
            ("unimportant", true), ("uninformed", true), ("MBA", true), ("FBI agent", true), ("URL", false),
            ("NASA", false), ("SQL", true), ("X-ray", true), ("8-hour day", true), ("80", true), ("11", true),
            ("18th", true), ("110", false), ("11,000", true), ("1", false), ("100", false), ("iPhone", true),
            ("*eraser*", true), ("\"hour\"", true), ("yak", false), ("owl", true),
        ]
        for (word, an) in cases {
            XCTAssertEqual(Articles.wantsAn(word), an, word)
        }
        XCTAssertNil(Articles.wantsAn("  ... "))
    }

    func testArticleFixKeepsCaseAndMarkup() {
        func fixed(_ text: String, _ word: String, _ next: String) -> String {
            let at = (text as NSString).range(of: word).location
            guard let c = Articles.fix(in: text, before: at, nextText: next) else { return text }
            return DocumentSidecar.applying([c], to: text)
        }
        XCTAssertEqual(fixed("A thumbtack", "thumbtack", "eraser"), "An thumbtack")
        XCTAssertEqual(fixed("AN EGG", "EGG", "BOX"), "A EGG")
        XCTAssertEqual(fixed("An egg", "egg", "box"), "A egg")
        XCTAssertEqual(fixed("use a *thumbtack*", "thumbtack", "eraser"), "use an *thumbtack*")
        XCTAssertEqual(fixed("use an  hour", "hour", "day"), "use a  hour")
        XCTAssertEqual(fixed("a thumbtack", "thumbtack", "tack"), "a thumbtack", "already right")
        XCTAssertEqual(fixed("banana thumbtack", "thumbtack", "eraser"), "banana thumbtack", "not an article")
        XCTAssertEqual(fixed("Kafka thumbtack", "thumbtack", "eraser"), "Kafka thumbtack", "word ending in a")
        XCTAssertEqual(fixed("a\nthumbtack", "thumbtack", "eraser"), "a\nthumbtack", "line break is not a gap")
        XCTAssertEqual(fixed("athumbtack", "thumbtack", "eraser"), "athumbtack", "no space")
        XCTAssertEqual(fixed("l'a thumbtack", "thumbtack", "eraser"), "l'a thumbtack", "apostrophe word")
    }

    // MARK: Ghosts

    func testGhostLifecycle() throws {
        let text = "Keep this. Trim this part. Keep that."
        var sc = DocumentSidecar()
        let (f, t) = range(of: "Trim this part. ", in: text)
        let g = try sc.addGhost(from: f, to: t, author: .ai, state: .proposed, source: "lab:trim-10", now: t0)
        XCTAssertEqual(sc.ghosts(overlapping: 0, 12).map(\.id), [g.id])
        XCTAssertEqual(sc.ghosts(overlapping: 0, 11).map(\.id), [])
        try sc.acceptGhost(g.id)
        XCTAssertEqual(sc.ghost(g.id)?.state, .ghosted)
        XCTAssertEqual(sc.ghost(g.id)?.source, "lab:trim-10")
        XCTAssertEqual(sc.reviveGhost(g.id)?.id, g.id)
        XCTAssertTrue(sc.isEmpty)
        XCTAssertThrowsError(try sc.acceptGhost("nope"))
    }

    // MARK: Overflow

    func testStashSelectionAndOrdering() throws {
        let text = "Intro. A spare paragraph. Outro."
        var sc = DocumentSidecar()
        let (of, ot) = range(of: "Outro.", in: text)
        let ghost = try sc.addGhost(from: of, to: ot)
        let (f, t) = range(of: "A spare paragraph. ", in: text)
        let (item, change) = try sc.stashSelection(from: f, to: t, in: text, id: "b", now: t0)
        XCTAssertEqual(change.text, "Intro. Outro.")
        XCTAssertEqual(item.text, "A spare paragraph. ")
        XCTAssertEqual(slice(change.text, sc.ghost(ghost.id)!.anchor), "Outro.")

        sc.addOverflow("https://example.com", id: "c", now: t0)
        sc.addOverflow("note", id: "a", now: t0)
        XCTAssertEqual(sc.sortedOverflow.map(\.id), ["b", "c", "a"])
        try sc.moveOverflow("a", to: 0)
        XCTAssertEqual(sc.sortedOverflow.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(sc.sortedOverflow.map(\.order), [0, 1, 2])
        try sc.updateOverflow("c", text: "https://example.org")
        XCTAssertEqual(sc.overflow.first { $0.id == "c" }?.text, "https://example.org")
        XCTAssertNotNil(sc.removeOverflow("b"))
        XCTAssertEqual(sc.sortedOverflow.map(\.id), ["a", "c"])
    }
}
