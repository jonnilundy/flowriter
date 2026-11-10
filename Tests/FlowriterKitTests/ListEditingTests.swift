import XCTest
@testable import FlowriterKit

final class ListEditingTests: XCTestCase {
    /// `|` marks the caret; `[` and `]` mark a selection.
    private func parse(_ marked: String) -> (NSString, NSRange) {
        let ns = marked as NSString
        let caret = ns.range(of: "|")
        if caret.location != NSNotFound { return (ns.replacingCharacters(in: caret, with: "") as NSString, NSRange(location: caret.location, length: 0)) }
        let a = ns.range(of: "⟦").location, b = ns.range(of: "⟧").location
        let text = (marked.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")) as NSString
        return (text, NSRange(location: a, length: b - a - 1))
    }

    private func render(_ text: NSString, _ edit: TextEdit?) -> String? {
        guard let edit else { return nil }
        let out = NSMutableString(string: text.replacingCharacters(in: edit.range, with: edit.text))
        if edit.selection.length == 0 {
            out.insert("|", at: edit.selection.location)
        } else {
            out.insert("⟧", at: NSMaxRange(edit.selection))
            out.insert("⟦", at: edit.selection.location)
        }
        return out as String
    }

    private func enter(_ s: String) -> String? { let (t, r) = parse(s); return render(t, ListEditing.newline(in: t, selection: r)) }
    private func tab(_ s: String, back: Bool = false) -> String? { let (t, r) = parse(s); return render(t, ListEditing.tab(in: t, selection: r, outdent: back)) }
    private func backspace(_ s: String) -> String? { let (t, r) = parse(s); return render(t, ListEditing.backspace(in: t, selection: r)) }

    func testReturnContinuesAList() {
        XCTAssertEqual(enter("- one|"), "- one\n- |")
        XCTAssertEqual(enter("* one|"), "* one\n* |")
        XCTAssertEqual(enter("  - one|"), "  - one\n  - |")
        XCTAssertEqual(enter("1. one|"), "1. one\n2. |")
        XCTAssertEqual(enter("9) one|"), "9) one\n10) |")
        XCTAssertEqual(enter("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(enter("- one| two"), "- one\n- | two")
        XCTAssertEqual(enter("> quote|"), "> quote\n> |")
    }

    func testReturnOnAnEmptyItemLeavesTheList() {
        XCTAssertEqual(enter("- one\n- |"), "- one\n|")
        XCTAssertEqual(enter("1. one\n2. |"), "1. one\n|")
        XCTAssertEqual(enter("- [ ] |"), "|")
        XCTAssertEqual(enter("> |"), "|")
        XCTAssertEqual(enter("- one\n  - two\n  - |"), "- one\n  - two\n- |")
        XCTAssertEqual(enter("1. one\n   - two\n   - |"), "1. one\n   - two\n- |")
    }

    func testReturnOutsideAListIsPlain() {
        XCTAssertNil(enter("plain|"))
        XCTAssertNil(enter("# Heading|"))
        XCTAssertNil(enter("|- at the line start"))
        XCTAssertNil(enter("-not a list|"))
        XCTAssertNil(enter("- a⟦b\n- c⟧d"))
        XCTAssertEqual(enter("    indented|"), "    indented\n    |")
    }

    func testBackspaceAfterATopLevelMarkerRemovesIt() {
        XCTAssertEqual(backspace("- |one"), "|one")
        XCTAssertEqual(backspace("1. |one"), "|one")
        XCTAssertEqual(backspace("- [ ] |one"), "|one")
        XCTAssertEqual(backspace("> |one"), "|one")
        XCTAssertNil(backspace("- o|ne"))
        XCTAssertNil(backspace("-| one"))
        XCTAssertNil(backspace("plain|"))
    }

    func testBackspaceAfterANestedMarkerGoesOneLevelOut() {
        XCTAssertEqual(backspace("- one\n  - |two"), "- one\n- |two")
        XCTAssertEqual(backspace("- one\n  - two\n    - |"), "- one\n  - two\n  - |")
        XCTAssertEqual(backspace("1. one\n   - |two"), "1. one\n- |two")
        XCTAssertEqual(backspace("    - |old four-space nesting"), "- |old four-space nesting")
        // two keys from a nested item to plain text at the left edge
        XCTAssertEqual(backspace("- one\n- |two"), "- one\n|two")
    }

    func testBackspaceInTheIndentGoesBackOneStop() {
        XCTAssertEqual(backspace("    |text"), "|text")
        XCTAssertEqual(backspace("  |text"), "|text")
        XCTAssertEqual(backspace("      |text"), "    |text")
        XCTAssertEqual(backspace("   |"), "|")
        XCTAssertEqual(backspace("  |- item"), "|- item")
        XCTAssertNil(backspace("\t|text"), "a tab is one character: plain Backspace")
        XCTAssertNil(backspace("a  |b"), "spaces inside text: plain Backspace")
        XCTAssertNil(backspace("|text"))
    }

    func testTabNestsUnderTheItemAbove() {
        XCTAssertEqual(tab("- one\n- two|"), "- one\n  - two|")
        XCTAssertEqual(tab("1. one\n2. two|"), "1. one\n   2. two|")
        XCTAssertEqual(tab("10. one\n- |two"), "10. one\n    - |two")
        XCTAssertEqual(tab("- one\n  - two\n- th|ree"), "- one\n  - two\n  - th|ree")
        XCTAssertEqual(tab("- one\n  - two|", back: true), "- one\n- two|")
        XCTAssertEqual(tab("1. one\n   - two|", back: true), "1. one\n- two|")
        XCTAssertNil(tab("- one|", back: true))
    }

    func testTabOnSeveralLinesKeepsTheSelection() {
        XCTAssertEqual(tab("- one\n⟦- two\n- three⟧"), "- one\n⟦  - two\n  - three⟧")
        XCTAssertEqual(tab("- one\n  - t⟦wo\n  - th⟧ree", back: true), "- one\n- t⟦wo\n- th⟧ree")
    }

    func testTabOutsideAList() {
        XCTAssertEqual(tab("ab|"), "ab  |")
        XCTAssertEqual(tab("|"), "    |")
        XCTAssertEqual(tab("    text|", back: true), "text|")
        XCTAssertNil(tab("text|", back: true))
    }

    func testIndentKeepsLineTerminators() {
        let (t, r) = parse("- one\r\n⟦- two\r\n- three⟧")
        let edit = ListEditing.tab(in: t, selection: r, outdent: false)
        XCTAssertEqual(edit.map { t.replacingCharacters(in: $0.range, with: $0.text) }, "- one\r\n  - two\r\n  - three")
    }

    func testBoldToggle() {
        let t = "say word now" as NSString
        let on = Formatting.toggle("**", in: t, selection: NSRange(location: 4, length: 4))
        let bolded = t.replacingCharacters(in: on.range, with: on.text) as NSString
        XCTAssertEqual(bolded, "say **word** now")
        XCTAssertEqual(bolded.substring(with: on.selection), "word")
        let off = Formatting.toggle("**", in: bolded, selection: on.selection)
        XCTAssertEqual(bolded.replacingCharacters(in: off.range, with: off.text), "say word now")
    }
}
