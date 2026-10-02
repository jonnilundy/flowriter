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

        ViewToggles.readingView = false
        await relayout(ctx)
    }
}
