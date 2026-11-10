import XCTest
@testable import FlowriterKit

final class StylerTests: XCTestCase {
    /// Flags of the first occurrence of `part` in `line`.
    private func flags(_ line: String, _ part: String, state: BlockState = .normal, first: Bool = false) -> StyleFlags {
        let styled = MarkdownStyler.style(line, state: state, isFirstLine: first)
        let r = (line as NSString).range(of: part)
        XCTAssertNotEqual(r.location, NSNotFound, "\(part) not in \(line)")
        let set = Set(styled.flags[r.location..<(r.location + r.length)])
        XCTAssertEqual(set.count, 1, "\(part) in \(line) has mixed flags \(set)")
        return set.first ?? []
    }

    func testEveryCharacterGetsOneFlagEntry() {
        for line in ["", "plain", "# h", "- [x] done **b**", "```", "a 😀 b", "> q"] {
            XCTAssertEqual(MarkdownStyler.style(line).flags.count, line.utf16.count, line)
        }
    }

    func testHeadings() {
        XCTAssertEqual(flags("## Title", "##"), [.mark, .bold, .headingMark])
        XCTAssertEqual(flags("# A **b**", "**"), [.mark, .heading, .bold], "marks inside a heading stay quiet")
        XCTAssertEqual(flags("## Title", "Title"), [.heading, .bold])
        XCTAssertEqual(flags("#hashtag", "#hashtag"), [])
        XCTAssertEqual(flags("####### seven", "seven"), [])
        XCTAssertTrue(flags("# A `b`", "b").contains(.code))
    }

    func testEmphasis() {
        XCTAssertEqual(flags("a **bold** b", "bold"), [.bold])
        XCTAssertEqual(flags("a **bold** b", "**"), [.mark])
        XCTAssertEqual(flags("a *it* b", "it"), [.italic])
        XCTAssertEqual(flags("a _it_ b", "it"), [.italic])
        XCTAssertEqual(flags("***both***", "both"), [.bold, .italic])
        XCTAssertEqual(flags("a ~~cut~~ b", "cut"), [.strike])
        XCTAssertEqual(flags("snake_case_name", "case"), [])
        XCTAssertEqual(flags("2 * 3 * 4", "3"), [])
        XCTAssertEqual(flags("**open only", "open"), [])
        XCTAssertEqual(flags(#"\*not\*"#, "not"), [])
    }

    func testCodeAndLinks() {
        XCTAssertEqual(flags("run `x * y` now", "x * y"), [.code])
        XCTAssertEqual(flags("run `x * y` now", "`"), [.mark, .code])
        XCTAssertEqual(flags("see [the *essay*](http://e.x/a_b) ok", "the "), [.link])
        XCTAssertEqual(flags("see [the *essay*](http://e.x/a_b) ok", "essay"), [.link, .italic])
        XCTAssertEqual(flags("see [text](http://e.x/a_b) ok", "http://e.x/a_b"), [.url])
        XCTAssertEqual(flags("go to https://resend.com.", "https://resend.com"), [.link])
        XCTAssertEqual(MarkdownStyler.style("go to https://resend.com.").flags.last, [])
        XCTAssertEqual(flags("a [[Braindump]] b", "Braindump"), [.link])
        XCTAssertEqual(flags("a <!-- note --> b", "<!-- note -->"), [.meta])
        XCTAssertEqual(flags("![alt](pic.png)", "!"), [.mark])
    }

    func testLists() {
        XCTAssertEqual(flags("- item", "-"), [.listMarker])
        XCTAssertEqual(flags("  12. item", "12."), [.listMarker])
        XCTAssertEqual(flags("- [ ] todo", "[ ]"), [.listMarker])
        XCTAssertEqual(flags("- [x] did it", "[x]"), [.mark])
        XCTAssertEqual(flags("- [x] did it", "did it"), [.done])
        XCTAssertEqual(flags("-not a list", "-not a list"), [])
        XCTAssertEqual(MarkdownStyler.style("- item").hangingColumns, 2)
        XCTAssertEqual(MarkdownStyler.style("    10. item").hangingColumns, 8)
        XCTAssertEqual(MarkdownStyler.style("- [ ] todo").hangingColumns, 6)
        XCTAssertEqual(MarkdownStyler.style("plain").hangingColumns, 0)
    }

    func testQuoteRuleTable() {
        XCTAssertEqual(flags("> said", ">"), [.mark])
        XCTAssertEqual(flags("> said", "said"), [.quote])
        XCTAssertEqual(MarkdownStyler.style("> said").hangingColumns, 2)
        XCTAssertEqual(flags("---", "---"), [.mark])
        XCTAssertEqual(flags("* * *", "*"), [.mark])
        XCTAssertEqual(flags("| a | b |", "|"), [.mark])
    }

    func testFencesCarryState() {
        let open = MarkdownStyler.style("```swift")
        XCTAssertEqual(open.endState, .fence(char: 96, count: 3))
        XCTAssertEqual(flags("let a = **b**", "let a = **b**", state: open.endState), [.code, .codeBlock])
        XCTAssertEqual(MarkdownStyler.style("``", state: open.endState, isFirstLine: false).endState, open.endState)
        XCTAssertEqual(MarkdownStyler.style("~~~", state: open.endState, isFirstLine: false).endState, open.endState)
        XCTAssertEqual(MarkdownStyler.style("```", state: open.endState, isFirstLine: false).endState, .normal)
        XCTAssertEqual(MarkdownStyler.style("`inline` code").endState, .normal)
    }

    func testFrontmatterOnlyOnTheFirstLine() {
        XCTAssertEqual(MarkdownStyler.style("---", state: .normal, isFirstLine: true).endState, .frontmatter)
        XCTAssertEqual(MarkdownStyler.style("---", state: .normal, isFirstLine: false).endState, .normal)
        XCTAssertEqual(flags("title: x", "title: x", state: .frontmatter), [.meta])
        XCTAssertEqual(MarkdownStyler.style("---", state: .frontmatter, isFirstLine: false).endState, .normal)
    }
}
