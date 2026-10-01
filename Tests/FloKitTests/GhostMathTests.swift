import XCTest
import FloCore
@testable import FloKit

@MainActor
final class GhostMathTests: XCTestCase {
    func r(_ a: Int, _ b: Int, _ o: GhostOrigin = .author) -> GhostRange { GhostRange(from: a, to: b, origin: o) }

    func testGhostMergesTouchingAndOverlapping() {
        var rs = GhostMath.ghost([], from: 5, to: 10)
        rs = GhostMath.ghost(rs, from: 10, to: 12)
        rs = GhostMath.ghost(rs, from: 2, to: 6)
        XCTAssertEqual(rs, [r(2, 12)])
    }

    func testReviveSplitsAndTrims() {
        XCTAssertEqual(GhostMath.revive([r(0, 20)], from: 5, to: 8), [r(0, 5), r(8, 20)])
        XCTAssertEqual(GhostMath.revive([r(0, 20)], from: 0, to: 20), [])
        XCTAssertEqual(GhostMath.revive([r(0, 20)], from: 15, to: 30), [r(0, 15)])
    }

    func testReviveLeavesProposed() {
        XCTAssertEqual(GhostMath.revive([r(0, 20, .proposed)], from: 0, to: 20), [r(0, 20, .proposed)])
    }

    func testAuthorAndProposedDoNotMerge() {
        XCTAssertEqual(GhostMath.normalize([r(0, 5), r(5, 9, .proposed)]).count, 2)
    }

    func testTouchingTakesWholeGhosts() {
        let rs = [r(2, 6), r(10, 14), r(20, 24, .proposed)]
        XCTAssertEqual(GhostMath.touching(rs, from: 4, to: 4), [r(2, 6)])          // caret inside
        XCTAssertEqual(GhostMath.touching(rs, from: 2, to: 2), [r(2, 6)])          // caret at the start
        XCTAssertEqual(GhostMath.touching(rs, from: 6, to: 6), [r(2, 6)])          // caret at the end
        XCTAssertEqual(GhostMath.touching(rs, from: 8, to: 8), [])                 // caret between
        XCTAssertEqual(GhostMath.touching(rs, from: 5, to: 11), [r(2, 6), r(10, 14)])   // a selection over two
        XCTAssertEqual(GhostMath.touching(rs, from: 6, to: 10), [])                // only the gap
        XCTAssertEqual(GhostMath.touching(rs, from: 21, to: 22), [])               // proposed ghosts are the Lab's
    }

    func testIsGhostText() {
        let text = Array("ab cd\n\nef gh ij".utf16)   // ghosts "ab cd" (0..5) and "ef gh" (7..12)
        let rs = [r(0, 5), r(7, 12)]
        XCTAssertTrue(GhostMath.isGhostText(rs, from: 1, to: 3, in: text))     // inside one ghost
        XCTAssertTrue(GhostMath.isGhostText(rs, from: 0, to: 6, in: text))     // with the line break after it
        XCTAssertTrue(GhostMath.isGhostText(rs, from: 2, to: 9, in: text))     // two ghosts, a blank line between
        XCTAssertFalse(GhostMath.isGhostText(rs, from: 10, to: 15, in: text))  // runs into plain text
        XCTAssertFalse(GhostMath.isGhostText(rs, from: 5, to: 7, in: text))    // white space only, no ghost
        XCTAssertFalse(GhostMath.isGhostText([r(0, 5, .proposed)], from: 0, to: 5, in: text))
    }

    func testCovers() {
        XCTAssertTrue(GhostMath.covers([r(0, 5), r(5, 9)], from: 2, to: 8))
        XCTAssertFalse(GhostMath.covers([r(0, 5), r(6, 9)], from: 2, to: 8))
    }

    func testWordCountSkipsGhosts() {
        let t = "One two three four five"
        XCTAssertEqual(GhostMath.wordCount(t, ghosts: []), 5)
        XCTAssertEqual(GhostMath.wordCount(t, ghosts: [r(4, 13)]), 3)   // "two three" ghosted
        XCTAssertEqual(GhostMath.wordCount(t, ghosts: [r(0, 23)]), 0)
    }
}

@MainActor
final class GhostMapTests: XCTestCase {
    func r(_ a: Int, _ b: Int) -> GhostRange { GhostRange(from: a, to: b) }
    func u(_ s: String) -> [UInt16] { Array(s.utf16) }

    func testWholeParagraphReplaceBecomesOneLetter() {
        // the text view reports the paragraph replaced; the ghost sits inside it
        let old = u("Para one. The ghost here. End.")
        let new = u("XPara one. The ghost here. End.")
        let big = Change(from: 0, to: old.count, insert: String(utf16CodeUnits: new, count: new.count))
        let refined = GhostMath.refine([big], old: old)
        XCTAssertEqual(refined.map { "\($0.from)-\($0.to):\($0.insert)" }, ["0-0:X"])
        // the sidecar's anchor rule, fed the refined change, keeps the ghost
        var sc = DocumentSidecar()
        sc.ghosts = [GhostRecord(anchor: TextAnchor(from: 11, to: 24), author: .me, state: .ghosted)]
        sc.applyEdits(refined)
        XCTAssertEqual(sc.ghosts.map { [$0.anchor.from, $0.anchor.to] }, [[12, 25]])
        // fed the raw whole-paragraph replace, it would be dropped
        var raw = DocumentSidecar()
        raw.ghosts = [GhostRecord(anchor: TextAnchor(from: 11, to: 24), author: .me, state: .ghosted)]
        raw.applyEdits([big])
        XCTAssertTrue(raw.ghosts.isEmpty)
    }

    func testDiffFallback() {
        let c = GhostMath.diff(old: u("abcdef"), new: u("abXYdef"))!
        XCTAssertEqual("\(c.from)-\(c.to):\(c.insert)", "2-3:XY")
        XCTAssertNil(GhostMath.diff(old: u("same"), new: u("same")))
    }
}
