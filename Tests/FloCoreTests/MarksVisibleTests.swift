import XCTest
@testable import FloCore

/// Flowriter: with marks always visible, the render plan must not depend on where the caret is
/// (the integrity suite's "no reflow on caret moves" at the planner level).
final class MarksVisibleTests: XCTestCase {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/integrity")
    static let extra = "# Heading\n\nSome **bold**, *soft*, `code`, ~~gone~~, a [link](https://example.com), \\*escaped\\*, -- and :smile:.\n\n> quoted\n\n- item\n- [ ] task\n\nSetext\n===\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n$x^2$ and [[Wiki Page]] and ![img](a.png)\n"

    func docs() throws -> [(String, String)] {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.dir.path).filter { $0.hasSuffix(".md") }.sorted()
        XCTAssertEqual(files.count, 4)
        return try files.map { ($0, try String(contentsOf: Self.dir.appendingPathComponent($0), encoding: .utf8)) } + [("extra", Self.extra)]
    }

    func plans(_ text: String) -> [RenderPlan] {
        let doc = Text(text)
        // caret at the start of every 3rd line (and at the end)
        var carets = stride(from: 1, through: doc.lines, by: 3).map { doc.line($0).from + min(2, doc.line($0).to - doc.line($0).from) }
        carets.append(doc.length)
        return carets.map { RenderPlanner.plan(EditorState(doc: doc, selection: .cursor($0))) }
    }

    func same(_ a: RenderPlan, _ b: RenderPlan) -> Bool {
        a.runs == b.runs && a.lines == b.lines && Set(a.widgets) == Set(b.widgets)
    }

    func testPlanIndependentOfCaret() throws {
        RenderPlanner.marksAlwaysVisible = true
        defer { RenderPlanner.marksAlwaysVisible = false }
        for (name, text) in try docs() {
            let ps = plans(text)
            for (i, p) in ps.enumerated().dropFirst() { XCTAssertTrue(same(ps[0], p), "\(name): plan differs with caret #\(i)") }
            // no mark is hidden: only list prefixes (drawn over by bullets) are transparent, only tabs are removed
            for r in ps[0].runs { if let h = r.style.hidden { XCTAssertTrue(h == .transparent || h == .margin(visible: true) || h == .removed && text.utf16.dropFirst(r.from).first == 9, "\(name): hidden \(h) at \(r.from)") } }
        }
    }

    /// A "-" or "=" typed under a paragraph must not restyle the paragraph (build 31: it became a heading).
    func testSetextUnderlineIsPlainTextInMarksMode() {
        for under in ["-", "- ", "--", "=", "==", "---"] {
            let text = "ddfs\ndk\nsldflk\n" + under
            RenderPlanner.marksAlwaysVisible = true
            let p = RenderPlanner.plan(EditorState(doc: Text(text), selection: .cursor(text.utf16.count)))
            RenderPlanner.marksAlwaysVisible = false
            let upstream = RenderPlanner.plan(EditorState(doc: Text(text), selection: .cursor(0)))
            XCTAssertEqual(p.lines.map(\.kind), [.paragraph, .paragraph, .paragraph, .paragraph], "\(under.debugDescription): line kinds")
            XCTAssertTrue(p.runs.allSatisfy { $0.style.sizeEm == 1 && $0.style.weight == 400 && $0.style.hidden == nil }, "\(under.debugDescription): body style")
            if under != "---" && under != "- " {
                XCTAssertEqual(upstream.lines.first?.kind, .heading(level: under.hasPrefix("=") ? 1 : 2), "\(under.debugDescription): upstream still a setext heading")
            }
        }
        // ATX headings still style
        RenderPlanner.marksAlwaysVisible = true
        defer { RenderPlanner.marksAlwaysVisible = false }
        XCTAssertEqual(RenderPlanner.plan(EditorState(doc: Text("## Todos\n"), selection: .cursor(0))).lines.first?.kind, .heading(level: 2))
    }

    /// A line of only `#` marks (and spaces) is plain text until a character follows: the first
    /// key typed on an empty line must not give it the heading size and space before.
    func testEmptyATXHeadingIsPlainTextInMarksMode() {
        RenderPlanner.marksAlwaysVisible = true
        defer { RenderPlanner.marksAlwaysVisible = false }
        func plan(_ t: String) -> RenderPlan { RenderPlanner.plan(EditorState(doc: Text(t), selection: .cursor(t.utf16.count))) }
        for marks in ["#", "# ", "##", "## ", "###  ", "# #", "## ##"] {
            let p = plan("para\n\n" + marks)
            XCTAssertEqual(p.lines.map(\.kind), [.paragraph, .blank, .paragraph], "\(marks.debugDescription): line kinds")
            XCTAssertTrue(p.runs.allSatisfy { $0.style.sizeEm == 1 && $0.style.weight == 400 }, "\(marks.debugDescription): body size and weight")
        }
        XCTAssertEqual(plan("para\n\n# N").lines.last?.kind, .heading(level: 1), "a character after the marks makes the heading")
        XCTAssertEqual(plan("para\n\n## ##x").lines.last?.kind, .heading(level: 2))
        RenderPlanner.marksAlwaysVisible = false
        XCTAssertEqual(plan("para\n\n#").lines.last?.kind, .heading(level: 1), "upstream mode keeps the empty heading")
    }

    func testDefaultModeStillRevealsPerLine() throws {
        XCTAssertFalse(RenderPlanner.marksAlwaysVisible)
        let ps = plans(Self.extra)
        XCTAssertTrue(ps.dropFirst().contains { !same(ps[0], $0) }, "upstream mode reveals marks per caret line")
    }
}
