import AppKit
import FloCore
import FloKit

/// Flowriter: the selection bar (`--ui-selftest selection-bar <post> <out>`, VM only;
/// scripts/selection-bar-vm-test.sh on Tests/fixtures/selection-bar/notebook.md, light and dark).
/// Shows after a mouse selection (not during the drag) and after a keyboard selection settles; not
/// for whitespace; placed over the first line, below when there is no room above, inside the
/// column; showing and hiding moves no text; hides on a key, Esc (and stays away), scroll, the
/// window losing key; off with the tools or the setting. Then each action: ghost / revive and
/// stash leave the caret in the page with focus; alt leaves an empty focused version line, typing
/// "rough" and Return adds it and leaves a new empty line, Esc gives the page its selection back;
/// an empty line never typed into adds nothing; versions moves with Down, applies with Return,
/// closes with Esc. Screenshots selection-bar-*-<appearance>.png.
@MainActor
enum SelectionBarScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    /// Run in the writing space's document window (SelfTestRunner.run).
    static let names = ["selection-bar"]
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }
    static func shot(_ ctx: Ctx, _ name: String) { T.screenshot(ctx, "selection-bar-\(name)-\(appearance).png") }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        guard name == "selection-bar" else { return false }
        UserDefaults.standard.removeObject(forKey: SelectionBar.defaultsKey)
        await scenario(ctx)
        UserDefaults.standard.removeObject(forKey: SelectionBar.defaultsKey)
        return true
    }

    // MARK: helpers

    static func text(_ ctx: Ctx) -> NSString { ctx.c.state.doc.string as NSString }
    static func range(_ ctx: Ctx, _ s: String, after: Int = 0) -> NSRange {
        text(ctx).range(of: s, options: [], range: NSRange(location: after, length: text(ctx).length - after))
    }

    /// A mouse event at a point in the text view (window coordinates in the event).
    static func mouse(_ ctx: Ctx, _ type: NSEvent.EventType, _ p: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        let w = ctx.wc.window!
        return NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A key through the app's event queue (as a real key: event monitors see it).
    static func postKey(_ ctx: Ctx, _ chars: String, code: UInt16, mods: NSEvent.ModifierFlags = []) async {
        let w = ctx.wc.window!
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        NSApp.postEvent(e, atStart: false)
        await T.pause(0.06)
    }
    static func shiftRight(_ ctx: Ctx) async {
        await postKey(ctx, String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124, mods: [.shift, .function, .numericPad])
    }
    static func escape(_ ctx: Ctx) async { await postKey(ctx, "\u{1b}", code: 53) }

    /// Where the drag test looked while the mouse was still down.
    static var shownDuringDrag: Bool?

    /// A real drag over `r` (down, drags, up) through the event queue. The bar is checked while the
    /// mouse is still down, before the up is posted.
    static func drag(_ ctx: Ctx, over r: NSRange) async {
        let tv = ctx.c.textView
        guard let a = ctx.c.rect(forPosition: r.location, in: tv), let b = ctx.c.rect(forPosition: NSMaxRange(r), in: tv) else { return }
        let p0 = NSPoint(x: a.minX + 1, y: a.midY), p1 = NSPoint(x: b.minX, y: b.midY)
        let mid = NSPoint(x: (p0.x + p1.x) / 2, y: p0.y)
        shownDuringDrag = nil
        NSApp.postEvent(mouse(ctx, .leftMouseDown, p0, in: tv), atStart: false)
        NSApp.postEvent(mouse(ctx, .leftMouseDragged, mid, in: tv), atStart: false)
        NSApp.postEvent(mouse(ctx, .leftMouseDragged, p1, in: tv), atStart: false)
        let up = mouse(ctx, .leftMouseUp, p1, in: tv)
        let bar = ctx.pane.selectionBar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                shownDuringDrag = bar?.isShown == true || bar?.view.isHidden == false
                NSApp.postEvent(up, atStart: false)
            }
        }
        await T.pause(0.9)
    }

    /// A real click on one of the bar's labels.
    static func click(_ ctx: Ctx, _ bar: SelectionBar, _ label: String) async -> Bool {
        guard let it = bar.view.items.first(where: { SelectionBarView.label($0.action) == label }) else { T.log("no label \(label) in \(bar.view.labels)"); return false }
        let p = NSPoint(x: it.rect.midX, y: it.rect.midY)
        NSApp.postEvent(mouse(ctx, .leftMouseDown, p, in: bar.view), atStart: false)
        NSApp.postEvent(mouse(ctx, .leftMouseUp, p, in: bar.view), atStart: false)
        await T.pause(0.4)
        return true
    }

    static func select(_ ctx: Ctx, _ r: NSRange) async {
        ctx.c.textView.setSelectedRange(r)
        await T.pause(SelectionBar.keyboardSettle + 0.35)
    }

    static func fragments(_ ctx: Ctx) -> [CGRect] {
        guard let tlm = ctx.c.textView.textLayoutManager, let tcm = tlm.textContentManager else { return [] }
        var out: [CGRect] = []
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: []) { f in out.append(f.layoutFragmentFrame); return true }
        return out + [ctx.c.textView.frame, ctx.c.scrollView.contentView.bounds]
    }

    static func visible(_ bar: SelectionBar) -> Bool { bar.isShown && !bar.view.isHidden && bar.view.alphaValue > 0.99 }

    static func state(_ bar: SelectionBar, _ ctx: Ctx) -> String {
        "shown \(bar.isShown), hidden \(bar.view.isHidden), alpha \(String(format: "%.2f", bar.view.alphaValue)), blocker \(bar.blocker(for: ctx.c.textView.selectedRange()) ?? "none")"
    }

    static func responderIsPage(_ ctx: Ctx) -> Bool { ctx.wc.window!.firstResponder === ctx.c.textView }

    // MARK: scenario

    static func scenario(_ ctx: Ctx) async {
        AlternativesPanelView.animations = false
        await T.pause(0.6)
        ctx.wc.window?.contentView?.layoutSubtreeIfNeeded()
        ctx.wc.window?.makeFirstResponder(ctx.c.textView)
        guard let bar = ctx.pane.selectionBar else { T.expect(false, "the pane has a selection bar"); return }
        T.expect(WritingTools.isOn && SelectionBar.enabled, "tools on, View > Show Selection Bar on by default")
        T.log("window key \(ctx.wc.window!.isKeyWindow), responder page \(responderIsPage(ctx))")
        let c = ctx.c

        // 1. a mouse selection: nothing while the mouse is down, the bar after the mouse-up; no text moves
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await T.pause(0.3)
        let before = fragments(ctx)
        let r1 = range(ctx, "pencil in my bag")
        await drag(ctx, over: r1)
        T.expect(shownDuringDrag == false, "not shown while the mouse is still down (\(String(describing: shownDuringDrag)))")
        let sel1 = c.textView.selectedRange()
        T.expect(sel1 == r1, "the drag selected \"pencil in my bag\" (\(sel1) vs \(r1))")
        T.expect(visible(bar), "shown after the mouse-up (\(state(bar, ctx)))")
        T.expect(bar.view.labels == ["ghost", "alt", "stash"], "labels ghost alt stash (\(bar.view.labels))")
        let during = fragments(ctx)
        T.expect(during == before, "showing it moved no text (\(before.count) fragment frames identical)")
        // its look
        let f = bar.view.frame
        T.expect(f.height == SelectionBarView.height && SelectionBarView.radius == 7, "26 pt tall, radius 7 (\(f.height))")
        let lines = bar.lineRects(sel1)
        if let first = SelectionBar.line(lines, first: true) {
            T.expect(abs(f.maxY - (first.minY - SelectionBar.lineGap)) <= 0.5, String(format: "8 pt above the first line (bar bottom %.1f, line top %.1f)", f.maxY, first.minY))
            T.expect(abs(f.midX - first.midX) <= 0.5, String(format: "centred over the selection (bar %.1f, text %.1f)", f.midX, first.midX))
            let glyphs = c.textView.window!.convertFromScreen(c.textView.firstRect(forCharacterRange: sel1, actualRange: nil))
            let g = ctx.pane.convert(glyphs, from: nil)
            T.expect(f.maxY <= g.minY - 6, String(format: "clear of the glyphs (bar bottom %.1f, text top %.1f)", f.maxY, g.minY))
        } else { T.expect(false, "selection line rects") }
        let col = bar.column!
        T.expect(f.minX >= col.left - 0.5 && f.maxX <= col.right + 0.5, "inside the text column")
        shot(ctx, "bar")
        // hover: the label in the text colour on a faint fill
        if let alt = bar.view.items.firstIndex(where: { $0.action == .alt }) {
            let it = bar.view.items[alt]
            bar.view.mouseMoved(with: mouse(ctx, .mouseMoved, NSPoint(x: it.rect.midX, y: it.rect.midY), in: bar.view, clicks: 0))
            T.expect(bar.view.hovered == alt, "hover finds the alt label")
            bar.view.display()
            shot(ctx, "bar-hover")
            bar.view.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: ctx.wc.window!.windowNumber,
                                                               context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        }

        // 2. Esc hides it, moves nothing, and it stays away from this range
        await escape(ctx)
        await T.pause(0.3)
        T.expect(!bar.isShown && bar.view.isHidden, "Esc hides it (\(state(bar, ctx)))")
        T.expect(c.textView.selectedRange() == r1, "Esc keeps the selection")
        T.expect(fragments(ctx) == before, "hiding it moved no text")
        await T.pause(0.8)
        T.expect(!bar.isShown, "after Esc it does not come back for the same range")

        // 3. a keyboard selection: shown only once it settles
        let r3 = range(ctx, "Some days")
        c.textView.setSelectedRange(NSRange(location: r3.location, length: 0))
        await T.pause(0.2)
        for _ in 0..<r3.length { await shiftRight(ctx) }
        T.expect(c.textView.selectedRange() == r3, "shift-right selected \"Some days\" (\(c.textView.selectedRange()))")
        T.expect(!bar.isShown, "not shown right after the keys")
        await T.pause(0.25)
        T.expect(!bar.isShown, "not shown 250 ms after the last key")
        await T.pause(0.5)
        T.expect(visible(bar), "shown once the keyboard selection settled (\(state(bar, ctx)))")
        // a key hides it (typing)
        await postKey(ctx, "x", code: 7)
        T.expect(!bar.isShown, "typing hides it")
        T.expect(text(ctx).range(of: "x days").location == NSNotFound && text(ctx).range(of: "need. x").location == NSNotFound, "typing replaced the selection")
        await postKey(ctx, "z", code: 6, mods: [.command])
        await T.pause(0.2)
        T.expect(text(ctx).range(of: "Some days it is").location != NSNotFound, "undo brings the text back")

        // 4. whitespace only: never
        let blank = range(ctx, "need.\n\n")
        await select(ctx, NSRange(location: blank.location + 5, length: 2))
        T.expect(!bar.isShown, "not shown for a selection of only line breaks (\(state(bar, ctx)))")

        // 5. the tools off, or the setting off: never
        WritingTools.isOn = false
        await select(ctx, range(ctx, "thumbtack"))
        T.expect(!bar.isShown, "not shown with the writing tools off")
        WritingTools.isOn = true
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        SelectionBar.setEnabled(false)
        await select(ctx, range(ctx, "thumbtack"))
        T.expect(!bar.isShown, "not shown with View > Show Selection Bar off")
        SelectionBar.setEnabled(true)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))

        // 6. clamped to the column: a word at the start of a line
        let r6 = range(ctx, "I keep")
        await select(ctx, NSRange(location: r6.location, length: 1))
        T.expect(visible(bar), "shown for a one-letter word (\(state(bar, ctx)))")
        T.expect(abs(bar.view.frame.minX - col.left) <= 0.5, String(format: "held inside the column on the left (bar %.1f, column %.1f)", bar.view.frame.minX, col.left))

        // 7. hides on scroll and on the window losing key
        let clip = c.scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 24))
        c.scrollView.reflectScrolledClipView(clip)
        await T.pause(0.2)
        T.expect(!bar.isShown, "a scroll hides it")
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 0))
        c.scrollView.reflectScrolledClipView(clip)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await select(ctx, range(ctx, "thumbtack"))
        T.expect(visible(bar), "shown again on a new selection")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: ctx.wc.window)
        await T.pause(0.2)
        T.expect(!bar.isShown, "the window losing key hides it")

        // 8. no room above (the line at the top of the visible band): below the last line
        let low = range(ctx, "Short words carry", after: range(ctx, "## Notes 2").location)
        if let band = bar.visibleBand, let line = c.rect(forPosition: low.location, in: c.textView) {
            let top = ctx.pane.convert(line, from: c.textView).minY
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + top - (band.top + 4)))
            c.scrollView.reflectScrolledClipView(clip)
            await T.pause(0.3)
            let r8 = NSRange(location: low.location, length: 11)   // "Short words"
            c.textView.setSelectedRange(NSRange(location: 0, length: 0))
            await select(ctx, r8)
            let rects = bar.lineRects(r8)
            if let first = SelectionBar.line(rects, first: true), let last = SelectionBar.line(rects, first: false) {
                T.log(String(format: "below: band top %.1f, line top %.1f, room above %.1f", band.top, first.minY, first.minY - SelectionBar.lineGap - SelectionBarView.height - band.top))
                T.expect(first.minY - SelectionBar.lineGap - SelectionBarView.height < band.top, "the line sits at the top of the visible band (no room above)")
                T.expect(visible(bar) && abs(bar.view.frame.minY - (last.maxY + SelectionBar.lineGap)) <= 0.5,
                         String(format: "no room above: 8 pt below the last line (bar top %.1f, line bottom %.1f, %@)", bar.view.frame.minY, last.maxY, state(bar, ctx)))
            } else { T.expect(false, "line rects for the low selection") }
            shot(ctx, "below")
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: 0))
            c.scrollView.reflectScrolledClipView(clip)
            await T.pause(0.2)
        } else { T.expect(false, "visible band and line rect") }

        // 9. ghost, then revive: the caret at the end, focus in the page
        guard let g = c.ghosts else { T.expect(false, "ghost layer attached"); return }
        let rg = range(ctx, "Some days it is the only tool I need.")
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await select(ctx, rg)
        T.expect(visible(bar) && bar.view.labels.first == "ghost", "ghost offered (\(bar.view.labels))")
        _ = await click(ctx, bar, "ghost")
        T.expect(g.ranges.contains { $0.from <= rg.location && $0.to >= NSMaxRange(rg) }, "ghost: the sentence is a ghost")
        T.expect(c.textView.selectedRange() == NSRange(location: NSMaxRange(rg), length: 0), "ghost: caret at the end of the range (\(c.textView.selectedRange()))")
        T.expect(responderIsPage(ctx) && !bar.isShown, "ghost: focus in the page, bar hidden")
        await select(ctx, rg)
        T.expect(visible(bar) && bar.view.labels.first == "revive", "on ghost text it reads revive (\(bar.view.labels))")
        shot(ctx, "revive")
        _ = await click(ctx, bar, "revive")
        T.expect(g.ranges.isEmpty, "revive: the ghost is gone")
        T.expect(c.textView.selectedRange() == NSRange(location: NSMaxRange(rg), length: 0) && responderIsPage(ctx), "revive: caret at the end, focus in the page")

        // 10. stash: the text goes to the overflow panel, the caret stays at the cut
        let rs = range(ctx, " None of it matters much.")
        let rsText = NSRange(location: rs.location + 1, length: rs.length - 1)
        await select(ctx, rsText)
        _ = await click(ctx, bar, "stash")
        T.expect(text(ctx).range(of: "None of it matters much.").location == NSNotFound, "stash: the sentence left the page")
        T.expect(ctx.pane.overflow?.panel.textView.string.contains("None of it matters much.") == true, "stash: the sentence is in the overflow panel")
        T.expect(c.textView.selectedRange() == NSRange(location: rsText.location, length: 0), "stash: caret at the cut (\(c.textView.selectedRange()) vs \(rsText.location))")
        T.expect(responderIsPage(ctx) && !bar.isShown, "stash: focus in the page, bar hidden")
        ctx.pane.overflow?.setOpen(false, animated: false)

        // 11. alt: an empty version line, focused; type and Return; Esc back to the page
        guard let l = c.alternatives else { T.expect(false, "alternatives layer attached"); return }
        let p = AlternativesAttach.panel(ctx.wc.root.area)
        let ra = range(ctx, "thumbtack")
        await select(ctx, ra)
        _ = await click(ctx, bar, "alt")
        T.expect(p.isOpen && p.inputHasFocus && p.input.stringValue.isEmpty, "alt: panel open, an empty version line focused")
        T.expect(p.session == .add(ra) && !bar.isShown, "alt: an Add Alternative session on the selection, bar hidden")
        T.expect(p.rows.count == 1 && p.rows.first?.text == "thumbtack", "alt: the selection is the first version (\(p.rows.map(\.text)))")
        p.display()
        shot(ctx, "alt-panel")
        AlternativesScenarios.typeText(ctx, "rough")
        AlternativesScenarios.returnKey(ctx)
        let set = l.set(level: .word, at: ra.location + 1)
        T.expect(set?.variants.map(\.text) == ["thumbtack", "rough"], "alt: typing rough and Return made a version (\(set?.variants.map(\.text) ?? []))")
        T.expect(text(ctx).range(of: "a rough, a ruler").location != NSNotFound, "alt: the page shows rough")
        T.expect(p.inputHasFocus && p.input.stringValue.isEmpty, "alt: a new empty line, focused")
        p.display()
        shot(ctx, "alt-panel-added")
        AlternativesScenarios.escape(ctx)
        let roughRange = range(ctx, "rough")
        T.expect(!p.isOpen && responderIsPage(ctx), "alt: Esc closes the panel, focus in the page")
        T.expect(c.textView.selectedRange() == roughRange, "alt: the selection is back, on the version (\(c.textView.selectedRange()) vs \(roughRange))")
        await T.pause(SelectionBar.keyboardSettle + 0.3)
        T.expect(!bar.isShown, "alt: the bar stays away from the restored selection")
        // an empty line never typed into adds nothing
        let rr = range(ctx, "ruler")
        await select(ctx, rr)
        _ = await click(ctx, bar, "alt")
        T.expect(p.isOpen && p.inputHasFocus, "alt on ruler: empty line focused")
        AlternativesScenarios.escape(ctx)
        T.expect(!p.isOpen && l.set(level: .word, at: rr.location + 1) == nil, "an empty line never typed into adds nothing (sets \(l.session.sets.count))")
        T.expect(c.textView.selectedRange() == rr && responderIsPage(ctx), "Esc gives the page its selection back")

        // 12. versions: Down moves, Return applies; Esc closes
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await select(ctx, roughRange)
        T.expect(visible(bar) && bar.view.labels.last == "versions", "inside an alternative set: versions offered (\(bar.view.labels))")
        shot(ctx, "versions-bar")
        _ = await click(ctx, bar, "versions")
        T.expect(p.isOpen && ctx.wc.window!.firstResponder === p, "versions: panel open, the list focused")
        T.expect(p.rows.firstIndex(where: \.current) == 1, "versions: the shown version (rough) highlighted")
        p.display()
        shot(ctx, "versions-panel")
        AlternativesScenarios.arrow(ctx, down: true)
        T.expect(set.map { AlternativesScenarios.shown(l, $0.id) } == "thumbtack", "versions: Down moves to thumbtack")
        AlternativesScenarios.returnKey(ctx)
        T.expect(!p.isOpen && responderIsPage(ctx), "versions: Return applies and closes, focus in the page")
        T.expect(text(ctx).range(of: "a thumbtack, a ruler").location != NSNotFound, "versions: the page shows thumbtack")
        let rt = range(ctx, "thumbtack")
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await select(ctx, rt)
        _ = await click(ctx, bar, "versions")
        AlternativesScenarios.arrow(ctx, down: true)
        AlternativesScenarios.escape(ctx)
        T.expect(!p.isOpen && responderIsPage(ctx), "versions: Esc closes, focus in the page")
        T.expect(set.map { AlternativesScenarios.shown(l, $0.id) } == "rough", "versions: the version shown last stays")

        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        l.flush()
        ctx.model.flushDirtyFiles()
        await T.pause(0.3)
    }
}
