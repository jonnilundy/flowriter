import XCTest
import AppKit
@testable import FloKit
@testable import FloCore

/// Fenced code typed one key at a time (keystroke film). After every key, on the drawn pixels:
///   - every line of every fenced block (its full line box, so its glyphs) lies inside the code box,
///     with at least the box padding above the block's first row and below its last
///   - the code text is inside the box left and right
///   - the caret is inside the box while it is in a block
///   - lines outside the blocks are not inside the box
///   - moving the caret out of the block and back moves no text and does not change the box
/// Each sequence runs in the writing and reading views, dark and light, typed at the end of the
/// document, in the middle (text after it) and into an empty document (the block is line 1).
///
/// Build 853fd18 (reported 2026-10-02): ``` Enter sdkfsdf with no closing fence and no final
/// newline: the box ended in the middle of the last line, cutting the glyphs, the caret below it.
extension CodeBlockRenderTests {
    struct FilmPlace { let name: String; let prefix: String; let suffix: String }
    static let filmPlaces = [
        FilmPlace(name: "end", prefix: "Intro paragraph\n\n", suffix: ""),
        FilmPlace(name: "middle", prefix: "Intro paragraph\n\n", suffix: "\n\nAfter one.\n\nAfter two."),
        FilmPlace(name: "alone", prefix: "", suffix: ""),
    ]

    /// "t:abc" types one key per character; anything else is one key.
    static func filmKeys(_ spec: [String]) -> [String] {
        spec.flatMap { k -> [String] in k.hasPrefix("t:") ? k.dropFirst(2).map { $0 == " " ? "Space" : String($0) } : [k] }
    }
    static let seqA = ["t:```", "Enter", "t:sdkfsdf"]
    static let filmSequences: [(name: String, lead: String, keys: [String])] = [
        ("a-unclosed-last-line", "", seqA),
        ("b-second-line", "", seqA + ["Enter", "t:second"]),
        ("c-closed", "", ["t:```ts", "Enter", "t:code", "Enter", "t:```"]),
        ("d-under-nested-list", "- Escalations\n  - to support", ["Enter", "Enter"] + seqA),
        ("e-backspace-out", "", seqA + Array(repeating: "Backspace", count: 11)),
        ("f-block-then-text", "", ["t:```", "Enter", "t:a = 1", "Enter", "t:```", "Enter", "Enter", "t:text after"]),
    ]

    struct FilmLine { let number: Int; let first: Bool; let last: Bool }

    /// Lines of every fenced block in the current document (1-based), with the trailing empty line
    /// after a final newline when an open block runs to the end.
    func blockLines(_ c: EditorController) -> [FilmLine] {
        let st = c.state
        var out: [FilmLine] = []
        st.tree.iterate(enter: { n, _ in
            guard n.name == "FencedCode" else { return true }
            let a = st.doc.lineAt(n.from).number, b = st.doc.lineAt(n.to).number
            for l in a...b { out.append(FilmLine(number: l, first: l == a, last: l == b)) }
            return false
        })
        return out
    }

    /// Vertical runs of the code box at the column's right side (view coordinates).
    func boxRuns(_ s: Shot) -> [(top: CGFloat, bottom: CGFloat)] {
        let x = boxProbeX(s), page = pageRGB(s)
        let rect = s.c.textView.visibleRect
        var runs: [(CGFloat, CGFloat)] = []
        var start: CGFloat?
        var y = rect.minY
        let step = 1 / s.scale
        while y < rect.maxY {
            let inBox = !near(px(s, x, y + step / 2), page, 5)
            if inBox && start == nil { start = y }
            if !inBox, let a = start { runs.append((a, y)); start = nil }
            y += step
        }
        if let a = start { runs.append((a, rect.maxY)) }
        return runs
    }

    /// Where every line of text sits: the rect of each laid-out line that holds characters (the empty
    /// line after a final newline holds none, nothing is drawn for it).
    func textLineRects(_ c: EditorController) -> [CGRect] {
        let tlm = c.textView.textLayoutManager!
        var out: [CGRect] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            for l in f.textLineFragments where l.characterRange.length > 0 {
                out.append(l.typographicBounds.offsetBy(dx: f.layoutFragmentFrame.minX, dy: f.layoutFragmentFrame.minY))
            }
            return true
        }
        return out
    }

    /// The layout invariants for the state `s`; empty when all hold.
    func filmProblems(_ s: Shot) -> [String] {
        var out: [String] = []
        let c = s.c, doc = s.doc
        let runs = boxRuns(s)
        let tol: CGFloat = 0.6
        let pad = AttributeApplier.codeBoxPadding
        let lines = blockLines(c)
        func run(covering top: CGFloat, _ bottom: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
            runs.first { $0.top <= top + tol && $0.bottom >= bottom - tol }
        }
        for l in lines {
            let line = doc.line(l.number)
            guard let box = caretRect(s, line.from) else { out.append("line \(l.number): no line rect"); continue }
            guard let r = run(covering: box.minY, box.maxY) else {
                out.append("line \(l.number) [\(box.minY), \(box.maxY)] not inside the box (runs \(runs.map { "[\($0.top), \($0.bottom)]" }))")
                continue
            }
            if l.first && r.top > box.minY - pad + tol { out.append("line \(l.number): \(box.minY - r.top) pt above the first row, want \(pad)") }
            if l.last && r.bottom < box.maxY + pad - tol { out.append("line \(l.number): \(r.bottom - box.maxY) pt below the last row, want \(pad)") }
            for seg in c.segmentRects(line.from, line.to) {
                let page = pageRGB(s)
                if near(px(s, seg.minX - pad, seg.midY), page, 5) { out.append("line \(l.number): text left of the box") }
                if seg.maxX + pad < boxProbeX(s), near(px(s, seg.maxX + pad, seg.midY), page, 5) { out.append("line \(l.number): text right of the box") }
            }
        }
        // lines outside every block stay outside the box (its padding may reach into the empty line
        // right under a closing fence at the end, which has no space of its own)
        let inBlock = Set(lines.map(\.number))
        for n in 1...doc.lines where !inBlock.contains(n) {
            guard let box = caretRect(s, doc.line(n).from) else { continue }
            for r in runs {
                let overlap = min(r.bottom, box.maxY) - max(r.top, box.minY)
                if overlap > pad + tol { out.append("line \(n) outside the block is \(overlap) pt inside the box"); break }
            }
        }
        // the caret, while it is on a block line
        let head = c.state.selection.main.head
        let headLine = doc.lineAt(head).number
        if lines.contains(where: { $0.number == headLine }), let caret = caretRect(s, head) {
            if run(covering: caret.minY, caret.maxY) == nil { out.append("caret [\(caret.minY), \(caret.maxY)] outside the box") }
            if near(px(s, caret.minX - pad, caret.midY), pageRGB(s), 5) { out.append("caret left of the box") }
        }
        return out
    }

    func testCodeBlockKeystrokeFilm() {
        var states = 0, failed = 0
        var report: [String] = []
        for seq in Self.filmSequences {
            for place in Self.filmPlaces {
                for reading in [false, true] {
                    for dark in [true, false] {
                        let tag = "\(seq.name) \(place.name) \(reading ? "reading" : "writing") \(dark ? "dark" : "light")"
                        let r = makeReplayer(dark: dark, reading: reading, bulletSpacing: 4)
                        let lead = place.prefix + seq.lead
                        r.load(lead + place.suffix, selection: .cursor(lead.utf16.count))
                        var typed: [String] = []
                        for key in Self.filmKeys(seq.keys) {
                            r.press(key)
                            typed.append(key)
                            states += 1
                            let s = capture(r, dark: dark, reading: reading, name: "film")
                            var problems = filmProblems(s)
                            // the caret alone moving (out of the block to the document start, then
                            // back) moves no text
                            let before = textLineRects(r.controller), runsBefore = boxRuns(s)
                            let sel = r.controller.state.selection
                            r.controller.run { t in t.dispatch(TransactionSpec(selection: .cursor(0), scrollIntoView: false)); return true }
                            let away = textLineRects(r.controller)
                            let runsAway = boxRuns(capture(r, dark: dark, reading: reading, name: "film-away"))
                            r.controller.run { t in t.dispatch(TransactionSpec(selection: sel, scrollIntoView: false)); return true }
                            let back = textLineRects(r.controller)
                            for (name, f) in [("caret away", away), ("caret back", back)] {
                                let moved = f.count != before.count ? ["\(before.count) lines -> \(f.count)"]
                                    : zip(before, f).filter { abs($0.minY - $1.minY) > 0.01 || abs($0.minX - $1.minX) > 0.01 || abs($0.height - $1.height) > 0.01 }.map { "\($0.0) -> \($0.1)" }
                                if !moved.isEmpty { problems.append("\(name): text moved \(moved)") }
                            }
                            if runsAway.count != runsBefore.count || zip(runsAway, runsBefore).contains(where: { abs($0.top - $1.top) > 0.6 || abs($0.bottom - $1.bottom) > 0.6 }) {
                                problems.append("caret away: the box changed \(runsBefore.map { "[\($0.top), \($0.bottom)]" }) -> \(runsAway.map { "[\($0.top), \($0.bottom)]" })")
                            }
                            if !problems.isEmpty {
                                failed += 1
                                if report.count < 2000 {
                                    report.append("\(tag) after \(typed.joined(separator: " ")): \(problems.joined(separator: "; ")) doc=\(r.doc.debugDescription)")
                                }
                                if let dir = ProcessInfo.processInfo.environment["CODEBLOCK_PNG_DIR"], failed <= 12 {
                                    let file = "\(dir)/film-fail-\(failed)-\(seq.name)-\(place.name)-\(reading ? "reading" : "writing")-\(dark ? "dark" : "light").png"
                                    try? s.rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
                                }
                            }
                        }
                        print("progress: \(tag) done, \(states) states, \(failed) failed")
                    }
                }
            }
        }
        print("FILM: \(states) keystroke states, \(failed) failed")
        for line in report { print("FILM FAIL \(line)") }
        XCTAssertEqual(failed, 0, "keystroke film: \(failed) of \(states) states break a layout invariant (first: \(report.first ?? "-"))")
    }
}
