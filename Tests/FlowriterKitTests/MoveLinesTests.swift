import XCTest
@testable import FlowriterKit

final class MoveLinesTests: XCTestCase {
    /// `|` marks the caret; `⟦` and `⟧` mark a selection. nil: nothing moves.
    private func move(_ marked: String, up: Bool) -> String? {
        let ns = marked as NSString
        let text: NSString, selection: NSRange
        let caret = ns.range(of: "|")
        if caret.location != NSNotFound {
            text = ns.replacingCharacters(in: caret, with: "") as NSString
            selection = NSRange(location: caret.location, length: 0)
        } else {
            let a = ns.range(of: "⟦").location, b = ns.range(of: "⟧").location
            text = marked.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "") as NSString
            selection = NSRange(location: a, length: b - a - 1)
        }
        guard let edit = MoveLines.move(in: text, selection: selection, up: up) else { return nil }
        let out = NSMutableString(string: text.replacingCharacters(in: edit.range, with: edit.text))
        if edit.selection.length == 0 {
            out.insert("|", at: edit.selection.location)
        } else {
            out.insert("⟧", at: NSMaxRange(edit.selection))
            out.insert("⟦", at: edit.selection.location)
        }
        return out as String
    }

    func testTheCaretLineMovesAndTheCaretGoesWithIt() {
        XCTAssertEqual(move("one\ntw|o\nthree", up: true), "tw|o\none\nthree")
        XCTAssertEqual(move("one\ntw|o\nthree", up: false), "one\nthree\ntw|o")
        XCTAssertEqual(move("one\ntwo\nthr|ee", up: true), "one\nthr|ee\ntwo")
        XCTAssertEqual(move("o|ne\ntwo\n", up: false), "two\no|ne\n")
    }

    func testNothingMovesPastTheEnds() {
        XCTAssertNil(move("o|ne\ntwo", up: true))
        XCTAssertNil(move("one\ntw|o", up: false))
        XCTAssertNil(move("one\ntw|o\n", up: false))
        XCTAssertNil(move("|", up: true))
    }

    func testASelectionMovesEveryLineItTouches() {
        XCTAssertEqual(move("a\nb⟦b\nc⟧c\nd", up: true), "b⟦b\nc⟧c\na\nd")
        XCTAssertEqual(move("a\nb⟦b\nc⟧c\nd", up: false), "a\nd\nb⟦b\nc⟧c")
    }

    func testASelectionEndingAtALineStartLeavesThatLine() {
        XCTAssertEqual(move("a\n⟦b\n⟧c\nd", up: false), "a\nc\n⟦b\n⟧d")
    }

    func testBlankLinesAndListsMoveAsText() {
        XCTAssertEqual(move("- one\n\n- t|wo", up: true), "- one\n- t|wo\n")
        XCTAssertEqual(move("1. one\n2. t|wo", up: true), "2. t|wo\n1. one")
    }

    func testWindowsLineBreaksStayWhereTheyAre() {
        XCTAssertEqual(move("one\r\ntw|o", up: true), "tw|o\r\none")
    }
}
