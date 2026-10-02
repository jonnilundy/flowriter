import XCTest
import AppKit
@testable import FloKit
@testable import FloCore

/// Fenced code, second report (2026-10-02, build 2273071, dark, reading view): a fence typed under a
/// nested list, then "dkfjsdfd", then Enter, no closing fence.
///   1. the code box butted against the list line above it, and the fence sat on the box's top edge
///   2. the caret on the empty line after the code drew at the box's left edge, 12 pt left of the code
///   3. the code got spelling underlines
/// plus typing in code (Enter, closing fence, rich paste). Facts come from drawn pixels, caret and
/// text segment rects, text checking attributes and the document text.
extension CodeBlockRenderTests {
    static let nested = "- Escalations\n    - to support if they have trouble"
    static let reportedKeys = ["Enter", "Enter", "t:```", "Enter", "t:dkfjsdfd", "Enter"]

    /// The caret rect TextKit gives an insertion point (what NSTextView draws), in view coordinates.
    func caretRect(_ s: Shot, _ pos: Int) -> CGRect? {
        let tv = s.c.textView
        guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: pos) else { return nil }
        var rect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, r, _, _ in
            rect = r; return false
        }
        let o = tv.textContainerOrigin
        return rect?.offsetBy(dx: o.x, dy: o.y)
    }

    func px(_ s: Shot, _ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
        rgb(s, Int(((x - s.origin.x) * s.scale)), Int(((y - s.origin.y) * s.scale)))
    }
    func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tol: Int) -> Bool {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) <= tol
    }
    /// The page colour as drawn (the view's top left corner is always page).
    func pageRGB(_ s: Shot) -> (Int, Int, Int) { rgb(s, 2, 2) }
    /// x just inside the code box's right edge (no text there).
    func boxProbeX(_ s: Shot) -> CGFloat {
        let tv = s.c.textView
        return tv.textContainerOrigin.x + (tv.textContainer?.size.width ?? 0) - 6
    }
    /// The box's top edge: scanning down from `y` at the box's right side, the first device pixel row
    /// that is not page colour (view coordinates).
    func boxTop(_ s: Shot, from y: CGFloat) -> CGFloat? {
        let x = boxProbeX(s), page = pageRGB(s)
        var yy = y
        while yy < y + 200 { if !near(px(s, x, yy), page, 5) { return yy }; yy += 1 / s.scale }
        return nil
    }
    /// The box's bottom edge: scanning down from `y` (inside the box), the first page-colour row.
    func boxBottom(_ s: Shot, from y: CGFloat) -> CGFloat? {
        let x = boxProbeX(s), page = pageRGB(s)
        var yy = y
        while yy < y + 200 { if near(px(s, x, yy), page, 5) { return yy }; yy += 1 / s.scale }
        return nil
    }
    /// The first row of glyph ink in `r`, against the box fill beside it.
    func inkTop(_ s: Shot, _ r: NSRect) -> CGFloat? {
        var y = r.minY
        while y < r.maxY {
            let fill = px(s, boxProbeX(s), y)
            var x = r.minX
            while x < r.maxX { if !near(px(s, x, y), fill, 48) { return y }; x += 1 / s.scale }
            y += 1 / s.scale
        }
        return nil
    }

    // MARK: 1 and 2: the reported case, both views, dark and light

    func testReportedFenceUnderNestedListLayout() {
        for reading in [false, true] {
            for dark in [true, false] {
                let tag = "\(reading ? "reading" : "writing") \(dark ? "dark" : "light")"
                let s = shot(Self.nested, .cursor(Self.nested.utf16.count), dark: dark, reading: reading,
                             keys: Self.reportedKeys, name: "reported", bulletSpacing: 4)
                XCTAssertEqual(s.r.doc, Self.nested + "\n```\ndkfjsdfd\n", "\(tag): typed text")
                XCTAssertEqual(s.r.selection.main.head, s.doc.length, "\(tag): caret on the empty last line")
                let list = line(s, 2), fence = line(s, 3), code = line(s, 4)

                // 2: the caret on the empty line sits where code text starts, not at the box's edge
                let textX = s.c.segmentRects(code.0, code.0 + 1).first?.minX ?? -1
                let caret = caretRect(s, s.doc.length)
                XCTAssertNotNil(caret, "\(tag): caret rect")
                XCTAssertEqual(caret?.minX ?? -1, textX, accuracy: 0.5, "\(tag): caret x vs code text x")
                let caretAtCode = caretRect(s, code.0)
                XCTAssertEqual(caretAtCode?.minX ?? -1, textX, accuracy: 0.5, "\(tag): caret at the code line's start")
                if let c = caret {
                    XCTAssertFalse(near(px(s, boxProbeX(s), c.midY), pageRGB(s), 5), "\(tag): the box runs under the caret's line")
                }

                // 1: a gap between the list line and the box; room between the box top and the fence
                guard let listSeg = s.c.segmentRects(list.0, list.1).first,
                      let fenceSeg = s.c.segmentRects(fence.0, fence.1).first,
                      let top = boxTop(s, from: listSeg.midY) else { return XCTFail("\(tag): geometry") }
                let gap = top - listSeg.maxY
                XCTAssertGreaterThanOrEqual(gap, AttributeApplier.codeBoxGap, "\(tag): gap between the list line box and the code box (\(gap))")
                let ink = inkTop(s, fenceSeg).map { $0 - top }
                let left = fenceSeg.minX - s.c.textView.textContainerOrigin.x - s.c.applier.gutter
                XCTAssertGreaterThanOrEqual(ink ?? 0, 9, "\(tag): box top to the fence's ink (\(ink ?? -1)); left padding \(left)")

                // the box ends below the caret's line, with padding under it
                if let caret = caret, let bottom = boxBottom(s, from: caret.midY) {
                    XCTAssertGreaterThanOrEqual(bottom - caret.maxY, AttributeApplier.codeBoxPadding - 0.5,
                                                "\(tag): padding under the last row (\(bottom - caret.maxY))")
                } else { XCTFail("\(tag): box bottom") }
            }
        }
    }

    /// A closed block right under a paragraph line and right above one: clear of both.
    func testCodeBoxKeepsClearOfTheLinesAroundIt() {
        let doc = "Intro line\n```\nselect 1\n```\nafter line"
        for reading in [false, true] {
            for dark in [true, false] {
                let tag = "\(reading ? "reading" : "writing") \(dark ? "dark" : "light")"
                let s = shot(doc, .cursor(0), dark: dark, reading: reading, name: "around")
                let intro = line(s, 1), body = line(s, 3), after = line(s, 5)
                guard let introSeg = s.c.segmentRects(intro.0, intro.1).first,
                      let bodySeg = s.c.segmentRects(body.0, body.1).first,
                      let afterSeg = s.c.segmentRects(after.0, after.1).first,
                      let top = boxTop(s, from: introSeg.midY),
                      let bottom = boxBottom(s, from: bodySeg.midY) else { return XCTFail("\(tag): geometry") }
                XCTAssertGreaterThanOrEqual(top - introSeg.maxY, AttributeApplier.codeBoxGap, "\(tag): gap above the box")
                XCTAssertGreaterThanOrEqual(afterSeg.minY - bottom, AttributeApplier.codeBoxGap, "\(tag): gap below the box")
            }
        }
    }

    // MARK: 3: no spelling or grammar marks and no substitutions in code

    /// Run the view's text checking over the whole document and wait for its marks.
    func spellingMarked(_ r: KeyReplayer) -> [String] {
        let tv = r.controller.textView
        let all = NSRange(location: 0, length: (r.doc as NSString).length)
        tv.checkText(in: all, types: NSTextCheckingTypes(NSTextCheckingResult.CheckingType.spelling.rawValue
                                                        | NSTextCheckingResult.CheckingType.grammar.rawValue), options: [:])
        let tlm = tv.textLayoutManager!
        func read() -> (checked: Bool, words: [String]) {
            var checked = false, words: [String] = []
            tlm.enumerateRenderingAttributes(from: tlm.documentRange.location, reverse: false) { _, attrs, range in
                if attrs[NSAttributedString.Key("NSTextChecked")] != nil { checked = true }
                let marked = [NSAttributedString.Key.spellingState, NSAttributedString.Key("NSGrammarState")].contains { k in
                    (attrs[k] as? NSNumber).map { $0.intValue != 0 } ?? false
                }
                if marked {
                    let a = tlm.offset(from: tlm.documentRange.location, to: range.location)
                    let b = tlm.offset(from: tlm.documentRange.location, to: range.endLocation)
                    words.append((r.doc as NSString).substring(with: NSRange(location: a, length: b - a)))
                }
                return true
            }
            return (checked, words)
        }
        let deadline = Date().addingTimeInterval(8)
        while !read().checked && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return read().words
    }

    func testCodeIsNotSpellChecked() {
        let doc = "Some blorf prose\n\n```zzqlang\ndkfjsdfd blorf\n```\n\nand `zzqqx` here\n\n    qwrtkk indented\n\n```\nunclosed vbnmx"
        let r = KeyReplayer(width: 1000, height: 600)
        r.load(doc, selection: .cursor(0))
        XCTAssertTrue(r.controller.textView.isContinuousSpellCheckingEnabled, "spelling on")
        let marked = spellingMarked(r)
        XCTAssertEqual(marked, ["blorf"], "only the prose word is marked")

        // a word marked as prose, then fenced: its mark goes when the code is checked again
        let r2 = KeyReplayer(width: 1000, height: 600)
        r2.load("intro\n\ndkfjsdfd", selection: .cursor(0))
        XCTAssertEqual(spellingMarked(r2), ["dkfjsdfd"], "prose word marked before fencing")
        r2.controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        for k in ["t:```", "Enter"] { r2.press(k) }
        XCTAssertEqual(r2.doc, "intro\n\n```\ndkfjsdfd")
        XCTAssertEqual(spellingMarked(r2), [], "fenced word unmarked")

        // the right-click spelling items follow the marks
        XCTAssertFalse(r.controller.touchesCode(NSRange(location: 6, length: 0)), "prose is not code")
        XCTAssertTrue(r.controller.touchesCode(NSRange(location: (doc as NSString).range(of: "dkfj").location, length: 0)), "fenced code")
        XCTAssertTrue(r.controller.touchesCode(NSRange(location: (doc as NSString).range(of: "zzqqx").location + 2, length: 0)), "inline code")
        XCTAssertTrue(r.controller.touchesCode(NSRange(location: (doc as NSString).range(of: "qwrtkk").location, length: 0)), "indented code")
        XCTAssertFalse(r.controller.touchesCode(NSRange(location: (doc as NSString).range(of: " here").location + 1, length: 0)), "after inline code")
    }

    /// With the user's substitutions turned on (Edit > Substitutions), prose gets them and code does not.
    func testCodeGetsNoSubstitutions() {
        for (name, doc, isCode) in [("prose", "text", false), ("fenced", "```\ncode", true), ("fenced-closed", "```\ncode\n```", true)] {
            let r = KeyReplayer(width: 1000, height: 600)
            let end = name == "fenced-closed" ? 8 : (doc as NSString).length
            r.load(doc, selection: .cursor(end))
            let tv = r.controller.textView
            tv.isAutomaticQuoteSubstitutionEnabled = true
            tv.isAutomaticDashSubstitutionEnabled = true
            tv.isAutomaticTextReplacementEnabled = true
            tv.isAutomaticSpellingCorrectionEnabled = true
            r.press("t: \"q\" it's -- x ")
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let typed = " \"q\" it's -- x "
            if isCode {
                XCTAssertTrue(r.doc.contains(typed), "\(name): typed as is: \(r.doc.debugDescription)")
            } else {
                XCTAssertFalse(r.doc.contains(typed), "\(name): prose still gets substitutions: \(r.doc.debugDescription)")
            }
            XCTAssertEqual(r.viewText, r.doc, "\(name): view and state agree")
        }
    }

    // MARK: 4: typing in code

    /// Code copied from a web page carries a <pre>: inside a code block it pastes as its plain text
    /// (its Markdown form is a fenced block, which closed the block early). Outside code it still converts.
    func testRichPasteIntoCodeIsPlainText() {
        let html = "<pre><code>let a = 1\nlet b = 2</code></pre>"
        let plain = "let a = 1\nlet b = 2"
        let r = KeyReplayer(width: 1000, height: 600)
        r.load("```ts\nconst x = 0\n\n```", selection: .cursor(18))
        r.controller.features.paste(PastePayload(plain: plain, html: html))
        XCTAssertEqual(r.doc, "```ts\nconst x = 0\nlet a = 1\nlet b = 2\n```")
        let r2 = KeyReplayer(width: 1000, height: 600)
        r2.load("Intro\n\n", selection: .cursor(7))
        r2.controller.features.paste(PastePayload(plain: plain, html: html))
        XCTAssertTrue(r2.doc.contains("```"), "outside code the <pre> still becomes a fenced block: \(r2.doc.debugDescription)")
    }

    /// What already works, kept working: Enter keeps the code line's indent and continues no Markdown,
    /// the closing fence ends the block, an open block at the end stays open through Enter.
    func testTypingInCode() {
        func run(_ doc: String, _ at: Int, _ keys: [String]) -> String {
            let r = KeyReplayer(width: 1000, height: 600)
            r.load(doc, selection: .cursor(at))
            for k in keys { r.press(k) }
            return r.doc
        }
        XCTAssertEqual(run("```\n    foo\n```", 11, ["Enter", "t:x"]), "```\n    foo\n    x\n```", "Enter keeps the indent")
        XCTAssertEqual(run("```\n- a", 7, ["Enter", "t:b"]), "```\n- a\nb", "no list continuation in code")
        XCTAssertEqual(run("```\n> a", 7, ["Enter", "t:b"]), "```\n> a\nb", "no quote continuation in code")
        XCTAssertEqual(run("```\nfoo", 7, ["Enter", "t:```", "Enter", "t:- after"]), "```\nfoo\n```\n- after", "closing fence ends the block")
        XCTAssertEqual(run("```\nfoo", 7, ["Enter", "Enter", "t:x"]), "```\nfoo\n\nx", "open block stays open")
        XCTAssertEqual(run("- item\n\n  ```\n  code", 20, ["Enter", "t:more"]), "- item\n\n  ```\n  code\n  more", "block in a list item keeps its indent")
        // a fence typed on a list item: Enter goes into the block at the item text's indent, not to a
        // new item (it gave "- ```\n- dkfjsdfd\n- ")
        XCTAssertEqual(run("- item", 6, ["Enter", "t:```", "Enter", "t:code", "Enter"]), "- item\n- ```\n  code\n  ", "fence on a list item")
        XCTAssertEqual(run("- a\n    - b", 11, ["Enter", "t:```ts", "Enter", "t:x"]), "- a\n    - b\n    - ```ts\n      x", "fence on a nested item")
        XCTAssertEqual(run("- ```\n  code\n  ```", 19, ["Enter", "t:next"]), "- ```\n  code\n  ```\n  next", "after the closing fence: still the item's indent")
    }

    // MARK: Tab and multi-line paste in code (approved follow-ups, 2026-10-02)

    /// In a fenced code block, Tab with no selection puts 2 spaces at the caret (it indented the whole line
    /// from its start, also with the caret mid line). A selection still indents its lines; Shift Tab
    /// and Tab outside code are unchanged.
    func testTabInCodeInsertsAtTheCaret() {
        func run(_ doc: String, _ sel: EditorSelection, _ keys: [String]) -> (String, Int, Int) {
            let r = KeyReplayer(width: 1000, height: 600)
            r.load(doc, selection: sel)
            for k in keys { r.press(k) }
            return (r.doc, r.selection.main.from, r.selection.main.to)
        }
        func eq(_ a: (String, Int, Int), _ b: (String, Int, Int), _ m: String) {
            XCTAssertEqual(a.0, b.0, m); XCTAssertEqual([a.1, a.2], [b.1, b.2], "\(m): selection")
        }
        eq(run("```\nfoo\n```", .cursor(6), ["Tab"]), ("```\nfo  o\n```", 8, 8), "mid line: at the caret")
        eq(run("```\nfoo\n```", .cursor(7), ["Tab", "t:x"]), ("```\nfoo  x\n```", 10, 10), "line end: at the caret")
        eq(run("```\nfoo\n```", .cursor(4), ["Tab"]), ("```\n  foo\n```", 6, 6), "line start")
        eq(run("```\nfoo\n```", .cursor(4), ["Tab", "Tab"]), ("```\n    foo\n```", 8, 8), "twice")
        eq(run("- item\n\n  ```\n  code", .cursor(20), ["Tab", "t:x"]), ("- item\n\n  ```\n  code  x", 23, 23), "block in a list item")
        // indented code is left alone: "    * foo" is as often an over-indented list item (keys parity)
        eq(run("Intro\n\n    indented code", .cursor(14), ["Tab"]), ("Intro\n\n      indented code", 16, 16), "indented code: the line, as before")
        // unchanged: a selection indents its lines, Shift Tab outdents, prose indents the line
        eq(run("```\nfoo\nbar\n```", .single(4, 11), ["Tab"]), ("```\n  foo\n  bar\n```", 6, 15), "selection indents lines")
        eq(run("```\n    foo\n```", .cursor(10), ["Shift-Tab"]), ("```\n  foo\n```", 8, 8), "Shift Tab outdents")
        eq(run("text", .cursor(2), ["Tab"]), ("  text", 4, 4), "prose: the line, as before")
    }

    /// The text a paste gives, through the paste chain (⌘V) and through Paste as plain text.
    func pasted(_ doc: String, at pos: Int, _ text: String) -> (chain: String, plain: String) {
        let r = KeyReplayer(width: 1000, height: 600)
        r.load(doc, selection: .cursor(pos))
        r.controller.features.paste(PastePayload(plain: text))
        let r2 = KeyReplayer(width: 1000, height: 600)
        r2.load(doc, selection: .cursor(pos))
        let pb = NSPasteboard(name: NSPasteboard.Name("flo-test-\(UUID().uuidString)"))
        pb.clearContents(); pb.setString(text, forType: .string)
        r2.controller.features.performMenuAction("paste-plain", pasteboard: pb)
        pb.releaseGlobally()
        return (r.doc, r2.doc)
    }

    /// Whether the fenced block that opens at `fence` still runs to the closing fence at the end of
    /// `doc`, inside a list item.
    func blockIntact(_ doc: String, fence: Int) -> Bool {
        let st = EditorState(doc: Text(doc), selection: .cursor(0))
        var ok = false
        st.tree.iterate(enter: { n, _ in
            if n.name == "FencedCode", n.from == fence {
                var p = n.parent, inItem = false
                while let q = p { if q.name == "ListItem" { inItem = true }; p = q.parent }
                ok = inItem && n.to == st.doc.length
            }
            return true
        })
        return ok
    }

    /// Multi-line code pasted into a block inside a list item: every line after the first gets the
    /// block's content indent (on top of its own), so the block and the item stay whole. Before,
    /// "let c = 3" landed at column 0, which ends the list item and with it the block.
    func testMultiLinePasteIntoListItemBlockKeepsItsIndent() {
        let code = "let a = 1\n  let b = 2\n\nlet c = 3"
        let doc = "- item\n  ```\n  \n  ```"
        let want = "- item\n  ```\n  let a = 1\n    let b = 2\n\n  let c = 3\n  ```"
        let p = pasted(doc, at: 15, code)
        XCTAssertEqual(p.chain, want, "⌘V")
        XCTAssertEqual(p.plain, want, "Paste as plain text")
        XCTAssertTrue(blockIntact(want, fence: 9), "the block runs to its closing fence inside the item")
        XCTAssertFalse(blockIntact("- item\n  ```\n  let a = 1\n  let b = 2\n\nlet c = 3\n  ```", fence: 9), "(the old result breaks the block)")
        // a nested item: the fence's column (6) is the indent
        let nested = "- a\n    - ```ts\n      \n      ```"
        XCTAssertEqual(pasted(nested, at: 22, "x\ny").chain, "- a\n    - ```ts\n      x\n      y\n      ```", "nested item")
        // mid line: the first line goes at the caret, the rest indented
        XCTAssertEqual(pasted("- item\n  ```\n  foo()\n  ```", at: 19, "a\nb").chain, "- item\n  ```\n  foo(a\n  b)\n  ```", "mid line")
        // unchanged: a top-level block, a single line, prose in a list item
        XCTAssertEqual(pasted("```\n\n```", at: 4, code).chain, "```\n" + code + "\n```", "top-level block")
        XCTAssertEqual(pasted(doc, at: 15, "one line").chain, "- item\n  ```\n  one line\n  ```", "one line")
        XCTAssertEqual(pasted("- item text", at: 11, "a\nb").chain, "- item texta\nb", "prose in a list item")
    }
}
