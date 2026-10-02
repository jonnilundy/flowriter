import XCTest
import AppKit
@testable import FloKit
@testable import FloCore

/// Fenced code blocks as Flowriter draws them (marks always visible, full-height blank lines), in the
/// writing view and the reading view, dark and light. Facts come from the drawn pixels (cacheDisplay
/// of the text view) and the laid-out fragments, not from the plan alone.
///
/// Build bcc1848 (reported 2026-10-02): in the reading view a fence the writer was typing ("```" and
/// its language) drew nothing; a selection on it painted an empty slab inside an empty code box.
@MainActor
final class CodeBlockRenderTests: XCTestCase {
    override func setUp() {
        RenderPlanner.marksAlwaysVisible = true
        EditorController.fullHeightBlankLines = true
    }
    override func tearDown() {
        RenderPlanner.marksAlwaysVisible = false
        RenderPlanner.readingView = false
        EditorController.fullHeightBlankLines = false
    }

    static let item = "- agent has some sort of db to track open cases"

    @MainActor struct Shot {
        let r: KeyReplayer
        let rep: NSBitmapImageRep
        let origin: CGPoint
        let scale: CGFloat
        var c: EditorController { r.controller }
        var doc: Text { r.controller.state.doc }
    }

    /// Load `doc` in an offscreen editor with Flowriter's dark or light colours and draw it.
    func shot(_ doc: String, _ sel: EditorSelection, dark: Bool, reading: Bool, keys: [String] = [], name: String) -> Shot {
        RenderPlanner.readingView = reading
        let r = KeyReplayer(width: 1000, height: 600)
        let t = r.controller.theme
        if dark {
            t.foreground = NSColor(hex: "#EDEDED"); t.background = NSColor(hex: "#1B1A18")
            t.selectionOverride = NSColor(hex: "#ECAA7F").withAlphaComponent(0.32)
        } else {
            t.selectionOverride = NSColor(hex: "#B5532A").withAlphaComponent(0.22)
        }
        r.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let tv = r.controller.textView
        tv.drawsBackground = true
        tv.backgroundColor = t.background
        tv.selectedTextAttributes = [.backgroundColor: t.selectionColor]
        r.load(doc, selection: sel)
        for k in keys { r.press(k) }
        let tlm = tv.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        let rect = tv.visibleRect
        let rep = tv.bitmapImageRepForCachingDisplay(in: rect)!
        tv.cacheDisplay(in: rect, to: rep)
        if let dir = ProcessInfo.processInfo.environment["CODEBLOCK_PNG_DIR"] {
            let file = "\(dir)/\(name)-\(reading ? "reading" : "writing")-\(dark ? "dark" : "light").png"
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
        }
        return Shot(r: r, rep: rep, origin: rect.origin, scale: CGFloat(rep.pixelsWide) / rect.width)
    }

    func rgb(_ s: Shot, _ px: Int, _ py: Int) -> (Int, Int, Int) {
        let c = s.rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) ?? .black
        return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// Glyph pixels in a view rect: pixels far from the rect's most common colour (its background,
    /// code box or selection). An empty slab has none.
    func ink(_ s: Shot, _ r: NSRect) -> Int {
        let x0 = Int(((r.minX - s.origin.x) * s.scale).rounded()), x1 = Int(((r.maxX - s.origin.x) * s.scale).rounded())
        let y0 = Int(((r.minY - s.origin.y) * s.scale).rounded()), y1 = Int(((r.maxY - s.origin.y) * s.scale).rounded())
        var px: [(Int, Int, Int)] = []
        for y in max(0, y0)..<min(s.rep.pixelsHigh, y1) { for x in max(0, x0)..<min(s.rep.pixelsWide, x1) { px.append(rgb(s, x, y)) } }
        var counts: [Int: Int] = [:]
        for p in px { counts[p.0 << 16 | p.1 << 8 | p.2, default: 0] += 1 }
        guard let mode = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        let m = (mode >> 16, (mode >> 8) & 255, mode & 255)
        return px.filter { max(abs($0.0 - m.0), abs($0.1 - m.1), abs($0.2 - m.2)) > 48 }.count
    }

    /// Ink over the characters [from, to) (their text segments, full line height).
    func ink(_ s: Shot, _ from: Int, _ to: Int) -> Int {
        s.c.segmentRects(from, to).reduce(0) { $0 + ink(s, $1) }
    }

    /// Line n's text range (1-based), without the newline.
    func line(_ s: Shot, _ n: Int) -> (Int, Int) { let l = s.doc.line(n); return (l.from, l.to) }

    /// The code box is drawn on line n: right of the text, near the column's right edge, the pixel is
    /// the box fill, not the page.
    func boxDrawn(_ s: Shot, line n: Int) -> Bool {
        let (a, b) = line(s, n)
        guard let seg = s.c.segmentRects(a, max(b, a + 1)).first ?? s.c.segmentRects(max(0, a - 1), a).first else { return false }
        let tv = s.c.textView
        let right = tv.textContainerOrigin.x + (tv.textContainer?.size.width ?? 0) - 6
        let inBox = rgb(s, Int(((right - s.origin.x) * s.scale)), Int(((seg.midY - s.origin.y) * s.scale)))
        let bg = s.c.theme.background.usingColorSpace(.sRGB)!
        let pageRGB = (Int(bg.redComponent * 255), Int(bg.greenComponent * 255), Int(bg.blueComponent * 255))
        return max(abs(inBox.0 - pageRGB.0), abs(inBox.1 - pageRGB.1), abs(inBox.2 - pageRGB.2)) >= 6
    }

    func fragmentFrames(_ s: Shot) -> [CGRect] {
        let tlm = s.c.textView.textLayoutManager!
        var out: [CGRect] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { out.append($0.layoutFragmentFrame); return true }
        return out
    }

    func color(_ s: Shot, at pos: Int) -> NSColor? {
        s.c.textView.textStorage?.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? NSColor
    }

    // MARK: the reported case

    /// Jonni's screenshot: a fence typed under a list item in the reading view, then selected.
    /// The fence and its language must draw, under the selection.
    func testTypedFenceUnderListItemIsVisibleWhenSelected() {
        for dark in [true, false] {
            let doc = Self.item
            let s = shot(doc, .cursor(doc.utf16.count), dark: dark, reading: true,
                         keys: ["Enter", "Enter", "t:```typescript", "Shift-Home"], name: "typed-fence")
            let tag = dark ? "dark" : "light"
            XCTAssertEqual(s.r.doc, Self.item + "\n```typescript", "\(tag): typed text")
            let (a, b) = line(s, 2)
            XCTAssertEqual([s.r.selection.main.from, s.r.selection.main.to], [a, b], "\(tag): the fence line is selected")
            XCTAssertTrue(boxDrawn(s, line: 2), "\(tag): code box drawn")
            XCTAssertGreaterThan(ink(s, a, a + 3), 40, "\(tag): ``` drawn under the selection")
            XCTAssertGreaterThan(ink(s, a + 3, b), 150, "\(tag): the language drawn under the selection")
            XCTAssertGreaterThan(color(s, at: a)?.alphaComponent ?? 0, 0.3, "\(tag): fence colour is not clear")
        }
    }

    // MARK: matrix

    struct Case {
        let name: String
        let doc: String
        /// 1-based lines of the opening fence, the content and the closing fence (nil: unclosed).
        let open: Int, content: [Int], close: Int?
    }

    static let cases: [Case] = [
        Case(name: "lang-many-after-list", doc: item + "\n\n```ts\nconst a = 1\nconst b = 2\nconst c = 3\n```\n\nafter",
             open: 3, content: [4, 5, 6], close: 7),
        Case(name: "nolang-one-after-list", doc: item + "\n\n```\nselect 1\n```\n\nafter", open: 3, content: [4], close: 5),
        Case(name: "nolang-directly-after-list", doc: item + "\n```\nselect 1\n```\nafter", open: 2, content: [3], close: 4),
        Case(name: "empty", doc: "Intro\n\n```\n```\n\nafter", open: 3, content: [], close: 4),
        Case(name: "unclosed-lang", doc: "Intro\n\n```sql\nselect 1\nfrom t", open: 3, content: [4, 5], close: nil),
    ]

    /// Every case, both views, dark and light: caret outside the block, caret inside, and a selection
    /// across the block's content.
    func testFencedCodeMatrix() {
        for c in Self.cases {
            for reading in [false, true] {
                for dark in [true, false] {
                    let tag = "\(c.name) \(reading ? "reading" : "writing") \(dark ? "dark" : "light")"
                    let lastLine = Text(c.doc).lines
                    let outside = Text(c.doc).line(1).from + 1
                    let inLine = c.content.first ?? c.open
                    let inside = Text(c.doc).line(inLine).from + 1
                    let fences = [c.open] + (c.close.map { [$0] } ?? [])
                    let sOut = shot(c.doc, .cursor(outside), dark: dark, reading: reading, name: "\(c.name)-out")
                    let sIn = shot(c.doc, .cursor(inside), dark: dark, reading: reading, name: "\(c.name)-in")
                    // a selection over the content (or over the opening fence of an empty block)
                    let selFrom = Text(c.doc).line(c.content.first ?? c.open).from
                    let selTo = Text(c.doc).line(c.content.last ?? c.open).to
                    let sSel = shot(c.doc, .single(selFrom, selTo), dark: dark, reading: reading, name: "\(c.name)-sel")

                    for s in [sOut, sIn, sSel] {
                        // the box: on every line of the block, each line one text line tall
                        for n in fences + c.content {
                            XCTAssertTrue(boxDrawn(s, line: n), "\(tag): box on line \(n)")
                        }
                        let frames = fragmentFrames(s)
                        for n in fences + c.content where n - 1 < frames.count {
                            XCTAssertEqual(frames[n - 1].height, 27, accuracy: 0.5, "\(tag): line \(n) height")
                        }
                        // code text: drawn, not clear
                        for n in c.content {
                            let (a, b) = line(s, n)
                            XCTAssertGreaterThan(ink(s, a, b), 60, "\(tag): code line \(n) drawn")
                            XCTAssertGreaterThan(color(s, at: a)?.alphaComponent ?? 0, 0.5, "\(tag): code line \(n) colour")
                        }
                        XCTAssertLessThanOrEqual(frames.count, lastLine + 1, "\(tag): fragments")
                    }
                    // fences: always drawn in the writing view; in the reading view only while the
                    // selection is in the block (hidden but holding their place otherwise)
                    for n in fences {
                        let (a, b) = line(sOut, n)
                        if reading {
                            XCTAssertEqual(ink(sOut, a, b), 0, "\(tag): fence \(n) hidden with the caret outside")
                        } else {
                            XCTAssertGreaterThan(ink(sOut, a, b), 40, "\(tag): fence \(n) drawn with the caret outside")
                        }
                        XCTAssertGreaterThan(ink(sIn, a, b), 40, "\(tag): fence \(n) drawn with the caret inside")
                        XCTAssertGreaterThan(ink(sSel, a, b), 40, "\(tag): fence \(n) drawn with a selection inside")
                    }
                    // moving the caret in or out of the block moves nothing (integrity: no reflow)
                    let fo = fragmentFrames(sOut), fi = fragmentFrames(sIn)
                    XCTAssertEqual(fo.count, fi.count, "\(tag): fragment count")
                    for (x, y) in zip(fo, fi) {
                        XCTAssertEqual(x.minY, y.minY, accuracy: 0.01, "\(tag): fragment top moved")
                        XCTAssertEqual(x.minX, y.minX, accuracy: 0.01, "\(tag): fragment left moved")
                        XCTAssertEqual(x.height, y.height, accuracy: 0.01, "\(tag): fragment height changed")
                        XCTAssertEqual(x.width, y.width, accuracy: 0.01, "\(tag): fragment width changed")
                    }
                }
            }
        }
    }
}
