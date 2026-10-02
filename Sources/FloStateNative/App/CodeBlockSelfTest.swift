import AppKit
import FloCore
import FloKit

/// Flowriter: fenced code blocks in the document window (`--ui-selftest code-blocks`, VM only:
/// scripts/code-blocks-vm-test.sh with Tests/fixtures/code-blocks/code.md). Build bcc1848: in the
/// reading view a fence being typed ("```" and its language) drew nothing, and selecting it painted
/// an empty slab in an empty code box. Screenshots code-blocks-*-<appearance>.png.
extension ViewTogglesScenarios {
    static func codeBlocks(_ ctx: Ctx) async {
        let c = ctx.c
        let look = appearance
        func text() -> NSString { c.state.doc.string as NSString }
        func alpha(_ pos: Int) -> CGFloat {
            (c.textView.textStorage?.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? NSColor)?.alphaComponent ?? 0
        }
        func select(_ from: Int, _ to: Int) async {
            c.run { t in t.dispatch(TransactionSpec(selection: .single(from, to), scrollIntoView: false)); return true }
            await relayout(ctx)
        }
        let fence = text().range(of: "```ts").location
        let code = text().range(of: "const cases").location
        let close = text().range(of: "\n```\n").location + 1
        let after = text().range(of: "The block above").location
        T.expect(fence != NSNotFound && code != NSNotFound && after != NSNotFound, "fixture has the code block")

        // writing view: fences and code drawn
        ViewToggles.readingView = false
        await select(0, 0)
        T.expect(alpha(fence) > 0.3 && alpha(fence + 3) > 0.3 && alpha(close) > 0.3, "writing view: fences drawn")
        T.expect(alpha(code) > 0.5, "writing view: code drawn")
        T.screenshot(ctx, "code-blocks-writing-\(look).png")

        // reading view, caret outside: fences hidden in place, code drawn
        ViewToggles.readingView = true
        await select(0, 0)
        T.expect(alpha(fence) == 0 && alpha(close) == 0, "reading view, caret outside: fences hidden")
        T.expect(alpha(code) > 0.5, "reading view, caret outside: code drawn")
        let topBefore = c.lineTop(at: after)
        T.screenshot(ctx, "code-blocks-reading-\(look).png")

        // reading view, caret in the block: fences drawn, nothing moves
        await select(code + 2, code + 2)
        T.expect(alpha(fence) > 0.3 && alpha(fence + 3) > 0.3 && alpha(close) > 0.3, "reading view, caret inside: fences drawn")
        let topInside = c.lineTop(at: after)
        T.expect(topBefore != nil && topBefore == topInside,
                 "reading view: the caret entering the block moves nothing (\(topBefore.map { "\($0)" } ?? "nil") -> \(topInside.map { "\($0)" } ?? "nil"))")
        T.screenshot(ctx, "code-blocks-reading-caret-in-\(look).png")

        // reading view: type a fence under a new list item, then select it (the reported case)
        let end = text().length
        await select(end, end)
        T.key(ctx, "\r", code: 36)
        T.type(ctx, "- one more case")
        T.key(ctx, "\r", code: 36)
        T.key(ctx, "\r", code: 36)
        T.type(ctx, "```typescript")
        T.key(ctx, "\u{F729}", code: 115, mods: [.shift])
        await relayout(ctx)
        let typed = text().range(of: "```typescript", options: .backwards).location
        T.expect(text().hasSuffix("- one more case\n```typescript"), "typed: \(String((text() as String).suffix(40)).debugDescription)")
        let sel = c.state.selection.main
        T.expect(typed != NSNotFound && sel.from == typed && sel.to == typed + 13, "the typed fence is selected (\(sel.from)-\(sel.to), fence at \(typed))")
        T.expect(typed != NSNotFound && alpha(typed) > 0.3 && alpha(typed + 3) > 0.3, "reading view: the typed fence and its language are drawn")
        T.screenshot(ctx, "code-blocks-reading-typed-selected-\(look).png")

        await reportedUnderNestedList(ctx)
        await typedKeyByKey(ctx)

        ViewToggles.readingView = false
        await relayout(ctx)
    }

    /// The second report (build 2273071, dark, reading view): a fence typed under a nested list, then
    /// "dkfjsdfd", then Enter, no closing fence. The box butted against the list line, the caret on
    /// the empty line drew at the box's edge (12 pt left of the code text), the code got a spelling
    /// underline. Screenshots code-blocks-reported-{writing,reading}-<appearance>.png.
    static func reportedUnderNestedList(_ ctx: Ctx) async {
        let c = ctx.c
        let look = appearance
        func text() -> NSString { c.state.doc.string as NSString }
        // drop the fence the step before typed (still selected), and its line
        T.backspace(ctx, 2)
        await relayout(ctx)
        T.expect(text().hasSuffix("- one more case"), "typed fence removed: \(String((text() as String).suffix(30)).debugDescription)")
        T.key(ctx, "\r", code: 36)
        T.key(ctx, "\r", code: 36)   // ends the list (an empty item clears its line)
        T.type(ctx, "- Escalations")
        T.key(ctx, "\r", code: 36)
        T.key(ctx, "\t", code: 48)
        T.type(ctx, "to support if they have trouble")
        T.key(ctx, "\r", code: 36)
        T.key(ctx, "\r", code: 36)
        T.type(ctx, "```")
        T.key(ctx, "\r", code: 36)
        T.type(ctx, "dkfjsdfd")
        T.key(ctx, "\r", code: 36)
        await relayout(ctx)
        let tail = "- Escalations\n  - to support if they have trouble\n```\ndkfjsdfd\n"
        T.expect(text().hasSuffix(tail), "typed: \(String((text() as String).suffix(70)).debugDescription)")
        let code = text().range(of: "dkfjsdfd", options: .backwards).location
        let list = text().range(of: "to support if", options: .backwards).location
        let fence = code - 4
        T.expect(c.state.selection.main.head == text().length, "caret on the empty last line")
        guard code != NSNotFound, list != NSNotFound else { return }

        func caretRect(_ pos: Int) -> CGRect? {
            guard let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager,
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: pos) else { return nil }
            var rect: CGRect?
            tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, r, _, _ in rect = r; return false }
            return rect
        }
        func segment(_ from: Int, _ to: Int) -> CGRect? {
            guard let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager,
                  let a = tcm.location(tcm.documentRange.location, offsetBy: from),
                  let b = tcm.location(tcm.documentRange.location, offsetBy: to), let r = NSTextRange(location: a, end: b) else { return nil }
            var rect: CGRect?
            tlm.enumerateTextSegments(in: r, type: .standard, options: [.rangeNotRequired]) { _, s, _, _ in rect = s; return false }
            return rect
        }
        for reading in [false, true] {
            let view = reading ? "reading" : "writing"
            ViewToggles.readingView = reading
            await relayout(ctx)
            // the caret on the empty line sits at the code text's x
            let caret = caretRect(text().length), codeX = segment(code, code + 1)?.minX
            T.expect(caret != nil && codeX != nil && abs(caret!.minX - codeX!) < 0.5,
                     "\(view): caret x \(caret.map { "\($0.minX)" } ?? "nil") = code text x \(codeX.map { "\($0)" } ?? "nil")")
            // the box (its top is the fence row's text top less its padding) keeps clear of the list line
            if let l = segment(list, list + 2), let f = segment(fence, fence + 3) {
                let gap = (f.minY - 4) - l.maxY
                T.expect(gap >= 8, "\(view): gap between the list line and the code box \(gap) pt")
            } else { T.expect(false, "\(view): list and fence segments") }
            // moving the caret out of the block and back moves nothing
            let topIn = c.lineTop(at: code)
            c.run { t in t.dispatch(TransactionSpec(selection: .cursor(0), scrollIntoView: false)); return true }
            await relayout(ctx)
            let topOut = c.lineTop(at: code)
            c.run { t in t.dispatch(TransactionSpec(selection: .cursor(t.state.doc.length), scrollIntoView: false)); return true }
            await relayout(ctx)
            T.expect(topIn != nil && topIn == topOut && topIn == c.lineTop(at: code),
                     "\(view): the caret leaving the block moves nothing (\(topIn.map { "\($0)" } ?? "nil") -> \(topOut.map { "\($0)" } ?? "nil"))")
            T.screenshot(ctx, "code-blocks-reported-\(view)-\(look).png")
        }

        // the code is checked but not marked: text checking ran over it (NSTextChecked) and left no
        // spelling or grammar state
        let tv = c.textView
        tv.checkText(in: NSRange(location: 0, length: text().length),
                     types: NSTextCheckingTypes(NSTextCheckingResult.CheckingType.spelling.rawValue | NSTextCheckingResult.CheckingType.grammar.rawValue),
                     options: [:])
        func marks(at pos: Int) -> (checked: Bool, marked: Bool)? {
            guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: pos) else { return nil }
            var out: (Bool, Bool)?
            tlm.enumerateRenderingAttributes(from: loc, reverse: false) { _, attrs, _ in
                let marked = [NSAttributedString.Key.spellingState, NSAttributedString.Key("NSGrammarState")].contains {
                    (attrs[$0] as? NSNumber).map { $0.intValue != 0 } ?? false
                }
                out = (attrs[NSAttributedString.Key("NSTextChecked")] != nil, marked); return false
            }
            return out
        }
        let checked = await T.waitFor(8) { marks(at: code + 2).flatMap { $0.checked ? $0 : nil } }
        T.expect(checked != nil, "text checking ran over the code")
        T.expect(checked?.marked == false, "no spelling or grammar mark on dkfjsdfd")
        T.screenshot(ctx, "code-blocks-reported-checked-\(look).png")
    }

    /// Build 853fd18 (reported 2026-10-02, dark, reading view): ``` Enter sdkfsdf typed at the end,
    /// no closing fence and no final newline: the box ended in the middle of the last line and the
    /// caret stuck out below it. Typed one key at a time with the reading view on; after every key
    /// the drawn text view (cacheDisplay) must have the box under each code line's whole line box
    /// and its padding, and under the caret. Screenshots code-blocks-typed-{a,b-enter,b}-<appearance>.png.
    static func typedKeyByKey(_ ctx: Ctx) async {
        let c = ctx.c, tv = c.textView
        let look = appearance
        ViewToggles.readingView = true
        func text() -> NSString { c.state.doc.string as NSString }
        // a fresh document: ⌘A, Backspace (logged: what a writer gets), then clear what is left
        T.key(ctx, "a", code: 0, mods: [.command])
        T.backspace(ctx)
        await relayout(ctx)
        T.log("after ⌘A Backspace in the reading view: \((text() as String).debugDescription)")
        c.run { t in t.dispatch(TransactionSpec(changes: [Change(from: 0, to: t.state.doc.length, insert: "")], selection: .cursor(0))); return true }
        T.type(ctx, "Intro paragraph")
        T.key(ctx, "\r", code: 36)
        T.key(ctx, "\r", code: 36)
        await relayout(ctx)
        T.expect(text() as String == "Intro paragraph\n\n", "fresh document: \((text() as String).debugDescription)")

        func caretRect(_ pos: Int) -> CGRect? {
            guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
                  let loc = tcm.location(tcm.documentRange.location, offsetBy: pos) else { return nil }
            var rect: CGRect?
            tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, r, _, _ in rect = r; return false }
            return rect?.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
        }
        /// Every line of the open block (from the fence to the end) and the caret: box drawn above,
        /// on and below them, with 4 pt of padding past the first and last rows.
        func check(_ step: String) -> Bool {
            let doc = c.state.doc
            guard let fenceAt = Optional(text().range(of: "```", options: .backwards).location), fenceAt != NSNotFound else { return true }
            let first = doc.lineAt(fenceAt).number
            let rect = tv.visibleRect
            guard let rep = tv.bitmapImageRepForCachingDisplay(in: rect) else { return false }
            tv.cacheDisplay(in: rect, to: rep)
            let scale = CGFloat(rep.pixelsWide) / rect.width
            func rgb(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
                let col = rep.colorAt(x: Int((x - rect.minX) * scale), y: Int((y - rect.minY) * scale))?.usingColorSpace(.sRGB) ?? .black
                return (Int(col.redComponent * 255), Int(col.greenComponent * 255), Int(col.blueComponent * 255))
            }
            let page = rgb(rect.minX + 2, rect.minY + 2)
            let x = tv.textContainerOrigin.x + (tv.textContainer?.size.width ?? 0) - 6
            func inBox(_ y: CGFloat) -> Bool { let p = rgb(x, y); return max(abs(p.0 - page.0), abs(p.1 - page.1), abs(p.2 - page.2)) > 5 }
            var bad: [String] = []
            for n in first...doc.lines {
                guard let r = caretRect(doc.line(n).from) else { continue }
                var y = r.minY + 0.5
                while y < r.maxY { if !inBox(y) { bad.append("line \(n) at y \(y)"); break }; y += 1 }
                if n == first && !inBox(r.minY - 3) { bad.append("no padding above line \(n)") }
                if n == doc.lines && !inBox(r.maxY + 3) { bad.append("no padding below line \(n)") }
            }
            if let car = caretRect(c.state.selection.main.head), !(inBox(car.minY + 1) && inBox(car.maxY - 1)) { bad.append("caret outside the box") }
            if !bad.isEmpty { T.log("\(step): \(bad.joined(separator: ", "))") }
            return bad.isEmpty
        }
        var failed: [String] = []
        func key(_ ch: String, _ code: UInt16 = 0) async {
            T.key(ctx, ch, code: ch == " " ? 49 : code)
            await relayout(ctx)
            let step = "after \((text() as String).suffix(12).debugDescription)"
            if !check(step) { failed.append(step) }
        }
        for ch in "```" { await key(String(ch), 50) }
        await key("\r", 36)
        for ch in "sdkfsdf" { await key(String(ch)) }
        T.expect(text().hasSuffix("```\nsdkfsdf"), "sequence a typed: \((text() as String).suffix(20).debugDescription)")
        T.screenshot(ctx, "code-blocks-typed-a-\(look).png")
        await key("\r", 36)
        T.screenshot(ctx, "code-blocks-typed-b-enter-\(look).png")
        for ch in "second" { await key(String(ch)) }
        T.expect(text().hasSuffix("```\nsdkfsdf\nsecond"), "sequence b typed: \((text() as String).suffix(24).debugDescription)")
        T.screenshot(ctx, "code-blocks-typed-b-\(look).png")
        T.expect(failed.isEmpty, "reading view, key by key: the box holds every code line and the caret after all 15 keys (\(failed.count) failed: \(failed.prefix(3).joined(separator: "; ")))")
    }
}
