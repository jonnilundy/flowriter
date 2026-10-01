import AppKit
import FloCore
import FloKit

/// Flowriter: the outline popup (the rail's hover popup that lists the headings). VM only;
/// scripts/outline-vm-test.sh on Tests/fixtures/outline/fireside-ideas.md, in the writing space's
/// document window, once per appearance:
///   outline   motion: the popup fades and scales in and out (opacity and scale sampled on screen,
///                   in order, ending fully in / fully gone, the ticks fading the other way); a hide
///                   cut into a show (and the reverse) turns round without a jump; ten quick toggles
///                   leave nothing behind; Reduce Motion fades without scaling; Esc and a mouse leave
///                   close it with the same motion.
///                   Hover: the row under the pointer gets a highlight (pixels checked) and the pointing
///                   hand over the row bands, none over the air; the shown section keeps its colour.
///                   Click: a row puts the caret at the heading's text, scrolls it to the top, gives the
///                   page focus (typing lands there) and closes the popup; a tick does the same;
///                   a right click still offers Copy heading link.
///                   Screenshots outline-{open,hover,mid-show,mid-hide}-<appearance>.png.
@MainActor
enum OutlineScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static let names: Set<String> = ["outline"]
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        guard names.contains(name) else { return false }
        ctx.model.setSetting("editor.show-outline", .bool(true))
        ctx.wc.root.area.updateRail()
        await T.pause(0.3)
        T.expect(ctx.model.isCompact, "the writing space's document window")
        let rail = ctx.wc.root.area.rail
        T.expect(!rail.isHidden && rail.headings.count == 5, "the rail shows 5 headings (\(rail.headings.count))")
        OutlineMotion.reduceMotionOverride = false
        await motion(ctx)
        await reduceMotion(ctx)
        await hover(ctx)
        await click(ctx)
        OutlineMotion.reduceMotionOverride = nil
        ctx.model.flushDirtyFiles()
        return true
    }

    // MARK: helpers

    static func rail(_ ctx: Ctx) -> OutlineRailView { ctx.wc.root.area.rail }

    static func settle(_ ctx: Ctx) {
        ctx.wc.root.needsLayout = true
        ctx.wc.root.layoutSubtreeIfNeeded()
        ctx.wc.window!.displayIfNeeded()
    }

    static func enter(_ ctx: Ctx) {
        let w = ctx.wc.window!
        let e = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        rail(ctx).mouseEntered(with: e)
    }

    /// The pointer leaves the rail's zone and the popup (to the page).
    static func leave(_ ctx: Ctx) {
        let r = rail(ctx), w = ctx.wc.window!
        let e = NSEvent.enterExitEvent(with: .mouseExited, location: r.convert(NSPoint(x: 100, y: 100), to: nil), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                       eventNumber: 0, trackingNumber: 0, userData: nil)!
        r.mouseExited(with: e)
    }

    static func move(_ ctx: Ctx, to p: NSPoint, in v: NSView) {
        let w = ctx.wc.window!
        let e = NSEvent.mouseEvent(with: .mouseMoved, location: v.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        (v as? OutlinePopoverView.ListDrawer)?.mouseMoved(with: e)
    }

    /// The middle of row `i` in the list drawer's coordinates.
    static func rowPoint(_ pop: OutlinePopoverView, _ i: Int) -> NSPoint {
        NSPoint(x: pop.drawer.bounds.midX, y: OutlineRows.rowTop(i) + OutlineRows.textHeight / 2)
    }

    struct Sample { var t: Double; var alpha: CGFloat; var scale: CGFloat }

    /// Opacity and scale on screen, every ~16 ms, until `done` or `limit` seconds.
    static func sample(_ pop: OutlinePopoverView, limit: Double = 1.5, until done: () -> Bool) async -> [Sample] {
        var out: [Sample] = []
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < limit {
            await T.pause(0.016)
            out.append(Sample(t: CACurrentMediaTime() - t0, alpha: pop.shownOpacity, scale: pop.shownScale))
            if done() { break }
        }
        return out
    }

    static func fmt(_ s: [Sample]) -> String { s.prefix(14).map { String(format: "%.2f", $0.alpha) }.joined(separator: " ") + (s.count > 14 ? " … (\(s.count))" : "") }

    static func monotone(_ s: [Sample], up: Bool) -> Bool {
        zip(s, s.dropFirst()).allSatisfy { up ? $1.alpha >= $0.alpha - 0.02 : $1.alpha <= $0.alpha + 0.02 }
    }

    /// Wait until the rail has no popup (the hide ended).
    static func gone(_ ctx: Ctx, limit: Double = 1.5) async -> Bool {
        await T.waitFor(limit) { rail(ctx).popover == nil ? true : nil } ?? false
    }

    static func shown(_ ctx: Ctx, limit: Double = 1.5) async -> Bool {
        await T.waitFor(limit) { rail(ctx).popover?.phase == .shown ? true : nil } ?? false
    }

    static func cleanState(_ ctx: Ctx, _ what: String) {
        let r = rail(ctx)
        T.expect(r.popover == nil && r.subviews.count == 1 && r.tickOpacity > 0.99, "\(what): nothing left behind (popup \(r.popover != nil), subviews \(r.subviews.count), ticks \(String(format: "%.2f", r.tickOpacity)))")
    }

    // MARK: motion

    static func motion(_ ctx: Ctx) async {
        let r = rail(ctx)

        // in
        let t0 = CACurrentMediaTime()
        enter(ctx)
        guard let pop = r.popover else { T.expect(false, "the popup opens"); return }
        T.expect(pop.phase == .showing && r.isOpen, "right after the hover the popup is coming in (phase \(pop.phase))")
        let ins = await sample(pop) { pop.phase == .shown }
        let tin = CACurrentMediaTime() - t0
        T.expect(pop.phase == .shown && abs(pop.shownOpacity - 1) < 0.01 && abs(pop.shownScale - 1) < 0.001, "in: ends fully visible at full size (alpha \(pop.shownOpacity), scale \(pop.shownScale))")
        T.expect(ins.contains { $0.alpha > 0.03 && $0.alpha < 0.97 }, "in: a frame in the middle was on screen (\(fmt(ins)))")
        T.expect(monotone(ins, up: true), "in: opacity only rises (\(fmt(ins)))")
        T.expect(ins.contains { $0.scale > 0.955 && $0.scale < 0.999 } && ins.allSatisfy { $0.scale >= 0.955 && $0.scale <= 1.001 }, "in: a small scale (0.96 to 1) goes with the fade (scales \(ins.prefix(8).map { String(format: "%.3f", $0.scale) }.joined(separator: " ")))")
        T.expect(tin > 0.1 && tin < 0.45, String(format: "in: takes about 180 ms (%.0f ms to the last sample, VM timers are coarse)", tin * 1000))
        T.expect(r.tickOpacity < 0.01, "in: the ticks have faded out under the popup (\(String(format: "%.2f", r.tickOpacity)))")
        settle(ctx)
        T.screenshot(ctx, "outline-open-\(appearance).png")

        // out
        let t1 = CACurrentMediaTime()
        r.closePopover()
        T.expect(!r.isOpen && r.popover != nil && pop.phase == .hiding, "right after the hide the popup is still on screen, going out (popup \(r.popover != nil), phase \(pop.phase))")
        let outs = await sample(pop) { r.popover == nil }
        let tout = CACurrentMediaTime() - t1
        T.expect(await gone(ctx), "out: the popup is gone from the view tree at the end")
        T.expect(outs.contains { $0.alpha > 0.03 && $0.alpha < 0.97 }, "out: a frame in the middle was on screen (\(fmt(outs)))")
        T.expect(monotone(outs, up: false), "out: opacity only falls (\(fmt(outs)))")
        T.expect(tout > 0.07 && tout < 0.4 && tout < tin + 0.05, String(format: "out: takes about 130 ms, not slower than in (%.0f ms, in %.0f ms)", tout * 1000, tin * 1000))
        cleanState(ctx, "out")

        // a show cut short by a hide: it turns round from where it is
        enter(ctx)
        let pop2 = r.popover!
        await T.pause(0.06)
        let a1 = pop2.shownOpacity
        r.closePopover()
        let a2 = pop2.shownOpacity
        T.expect(abs(a1 - a2) < 0.2, String(format: "hide in the middle of a show: no jump (%.2f before, %.2f after)", a1, a2))
        await T.pause(0.04)
        let a3 = pop2.shownOpacity
        T.expect(a3 < a1 + 0.02 && r.popover === pop2, String(format: "the popup now goes out (%.2f, was %.2f)", a3, a1))
        // and the hide cut short by a show
        enter(ctx)
        let a4 = pop2.shownOpacity
        T.expect(r.popover === pop2 && pop2.phase == .showing && abs(a4 - a3) < 0.2, String(format: "show in the middle of a hide: the same popup comes back, no jump (%.2f to %.2f)", a3, a4))
        T.expect(await shown(ctx) && abs(pop2.shownOpacity - 1) < 0.01 && abs(pop2.shownScale - 1) < 0.001, "turned round: ends fully visible at full size")
        r.closePopover()
        T.expect(await gone(ctx), "and out again")
        cleanState(ctx, "turned round")

        // ten quick toggles, then each end state is clean
        for i in 0..<10 {
            if i % 2 == 0 { enter(ctx) } else { r.closePopover() }
            await T.pause(0.015)
        }
        r.closePopover()   // 10 toggles ended closed; make sure the last act is a hide
        T.expect(await gone(ctx), "ten quick toggles, ending with a hide: the popup is gone")
        cleanState(ctx, "ten quick toggles (hide last)")
        for i in 0..<9 {
            if i % 2 == 0 { enter(ctx) } else { r.closePopover() }
            await T.pause(0.015)
        }
        T.expect(await shown(ctx), "nine quick toggles, ending with a show: the popup is fully in")
        T.expect(abs(r.popover!.shownOpacity - 1) < 0.01 && abs(r.popover!.shownScale - 1) < 0.001 && r.tickOpacity < 0.01 && r.popover!.superview === r, "fully in: opaque, full size, the ticks away")

        // Esc (the window's key monitor) closes with the same motion
        let pop3 = r.popover!
        T.appKey(ctx, "\u{1b}", code: 53)
        T.expect(!r.isOpen && pop3.phase == .hiding, "Esc: the popup goes out (open \(r.isOpen), phase \(pop3.phase))")
        T.expect(await gone(ctx), "Esc: and is gone")
        cleanState(ctx, "Esc")

        // the pointer leaving closes it with the same motion
        enter(ctx)
        _ = await shown(ctx)
        let pop4 = r.popover!
        leave(ctx)
        T.expect(!r.isOpen && pop4.phase == .hiding, "pointer leaves: the popup goes out")
        T.expect(await gone(ctx), "pointer leaves: and is gone")
        cleanState(ctx, "pointer leaves")

        // photographs in the middle of the motion (the motion slowed down 20 times)
        OutlineMotion.durationScale = 20
        enter(ctx)
        await T.pause(0.35)
        settle(ctx)
        let mid = r.popover!.shownOpacity
        T.screenshot(ctx, "outline-mid-show-\(appearance).png")
        T.expect(mid > 0.05 && mid < 0.95, String(format: "mid-show frame photographed at opacity %.2f", mid))
        OutlineMotion.durationScale = 1
        _ = await shown(ctx, limit: 6)
        OutlineMotion.durationScale = 20
        r.closePopover()
        await T.pause(0.3)
        settle(ctx)
        let mid2 = r.popover?.shownOpacity ?? -1
        T.screenshot(ctx, "outline-mid-hide-\(appearance).png")
        T.expect(mid2 > 0.05 && mid2 < 0.95, String(format: "mid-hide frame photographed at opacity %.2f", mid2))
        OutlineMotion.durationScale = 1
        T.expect(await gone(ctx, limit: 6), "the slowed hide ends")
        cleanState(ctx, "slowed")
    }

    // MARK: reduce motion

    static func reduceMotion(_ ctx: Ctx) async {
        let r = rail(ctx)
        OutlineMotion.reduceMotionOverride = true
        enter(ctx)
        let pop = r.popover!
        let ins = await sample(pop) { pop.phase == .shown }
        T.expect(ins.contains { $0.alpha > 0.03 && $0.alpha < 0.97 }, "Reduce Motion, in: it still fades (\(fmt(ins)))")
        T.expect(ins.allSatisfy { abs($0.scale - 1) < 0.001 }, "Reduce Motion, in: no scale (\(ins.prefix(6).map { String(format: "%.3f", $0.scale) }.joined(separator: " ")))")
        T.expect(abs(pop.shownOpacity - 1) < 0.01, "Reduce Motion, in: ends fully visible")
        r.closePopover()
        let outs = await sample(pop) { r.popover == nil }
        T.expect(outs.allSatisfy { abs($0.scale - 1) < 0.001 }, "Reduce Motion, out: no scale")
        T.expect(await gone(ctx), "Reduce Motion, out: gone at the end")
        cleanState(ctx, "Reduce Motion")
        OutlineMotion.reduceMotionOverride = false
    }

    // MARK: hover

    /// The window screenshot `png`: the colour at `p` (popup coordinates).
    static func pixel(_ ctx: Ctx, _ png: String, _ p: NSPoint, in v: NSView) -> NSColor? {
        let root = ctx.wc.root
        let q = v.convert(p, to: root)
        guard let img = NSImage(contentsOfFile: (ctx.out as NSString).appendingPathComponent(png)),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        return rep.colorAt(x: Int(q.x * scale), y: Int((root.isFlipped ? q.y : root.bounds.height - q.y) * scale))?.usingColorSpace(.sRGB)
    }

    static func hover(_ ctx: Ctx) async {
        let r = rail(ctx)
        OutlineMotion.animations = false
        enter(ctx)
        guard let pop = r.popover else { T.expect(false, "hover: the popup opens"); return }
        T.expect(pop.phase == .shown && abs(pop.shownOpacity - 1) < 0.01, "animations off: the popup is in at once")
        settle(ctx)
        T.expect(pop.hovered == nil, "no row is hovered before the pointer moves")

        // the bands touch and cover the rows; the air above the first row is no row
        let d = pop.drawer
        T.expect(pop.cursorRects.count == 5 && pop.cursorRects.indices.allSatisfy { i in
            let c = pop.cursorRects[i]
            return c.cursor === NSCursor.pointingHand && c.rect.contains(rowPoint(pop, i)) && (i == 0 || abs(c.rect.minY - pop.cursorRects[i - 1].rect.maxY) < 0.01)
        }, "the pointing hand covers each row's band, bands touch (\(pop.cursorRects.count) cursor rects)")
        T.expect(!pop.cursorRects.contains { $0.rect.contains(NSPoint(x: 100, y: 3)) }, "the air above the first row has the arrow")

        move(ctx, to: rowPoint(pop, 3), in: d)
        T.expect(pop.hovered == 3, "pointer on row 3 hovers it (hovered \(String(describing: pop.hovered)))")
        move(ctx, to: NSPoint(x: rowPoint(pop, 3).x, y: OutlineRows.rowTop(3) + OutlineRows.textHeight + 2), in: d)   // in the gap under row 3: still a row band edge
        T.expect(pop.hovered == 3 || pop.hovered == 4, "the gap between rows belongs to a row (hovered \(String(describing: pop.hovered)))")
        move(ctx, to: rowPoint(pop, 2), in: d)
        T.expect(pop.hovered == 2, "pointer on row 2 hovers row 2 only (hovered \(String(describing: pop.hovered)))")
        move(ctx, to: NSPoint(x: 100, y: 3), in: d)
        T.expect(pop.hovered == nil, "pointer in the air above the first row hovers nothing")
        move(ctx, to: rowPoint(pop, 3), in: d)
        settle(ctx)
        pop.display()
        T.screenshot(ctx, "outline-hover-\(appearance).png")
        // the highlight is drawn: pixels left of the text inside the highlight differ from the same spot on a row that is not hovered
        let x = OutlineRows.highlightInset + 3
        if let hov = pixel(ctx, "outline-hover-\(appearance).png", NSPoint(x: x, y: OutlineRows.rowTop(3) + 9), in: d),
           let rest = pixel(ctx, "outline-hover-\(appearance).png", NSPoint(x: x, y: OutlineRows.rowTop(1) + 9), in: d) {
            let diff = max(abs(hov.redComponent - rest.redComponent), abs(hov.greenComponent - rest.greenComponent), abs(hov.blueComponent - rest.blueComponent))
            T.expect(diff > 0.015, String(format: "the hovered row has a highlight (%.3f against %.3f at the same place on a quiet row)", hov.redComponent, rest.redComponent))
            T.expect(diff < 0.2, String(format: "and it is soft (difference %.3f)", diff))
        } else { T.expect(false, "read the hover screenshot") }
        T.expect(pop.hoverRect.map { pop.bounds.contains($0) && $0.minX >= 4 && $0.maxX <= pop.bounds.width - 4 } == true, "the highlight sits inside the card with air on both sides (\(String(describing: pop.hoverRect)))")
        T.expect(r.activeIndex == 0, "the shown section stays the current one (active \(String(describing: r.activeIndex)))")

        // the pointer leaving the list clears it
        let e = NSEvent.enterExitEvent(with: .mouseExited, location: pop.convert(NSPoint(x: 100, y: 40), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: ctx.wc.window!.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        d.mouseExited(with: e)
        T.expect(pop.hovered == nil, "the pointer leaving the list clears the hover")
        r.closePopover()
        OutlineMotion.animations = true
        _ = await gone(ctx)
    }

    // MARK: click

    static func click(_ ctx: Ctx) async {
        let r = rail(ctx), text = ctx.c.state.doc.string as NSString
        let tv = ctx.c.textView
        func head(_ s: String) -> Int { text.range(of: s).location }
        func headTop(_ s: String) -> CGFloat { ctx.c.lineTop(forPosition: head(s), in: ctx.pane) ?? -1000 }
        OutlineMotion.animations = false
        ctx.wc.window!.makeFirstResponder(nil)
        ctx.c.run { t in t.dispatch(TransactionSpec(selection: .cursor(text.length))); return true }
        ctx.pane.scrollBy(100_000)   // the end of the page
        await T.pause(0.2)
        T.expect(ctx.pane.scrollTop > 1000, "set up: scrolled to the end (\(Int(ctx.pane.scrollTop)))")

        // a click on a row
        enter(ctx)
        let pop = r.popover!
        settle(ctx)
        let target = "Act 2: Trust and the IC"
        guard let i = r.headings.firstIndex(where: { $0.text == target }) else { T.expect(false, "the Act 2 heading is in the outline"); return }
        T.click(ctx, at: rowPoint(pop, i), in: pop.drawer)
        await T.pause(0.3)
        let sel = ctx.c.state.selection.main
        T.expect(sel.empty && sel.head == head(target), "a click on the row puts the caret at the start of the heading's text (caret \(sel.head), heading text at \(head(target)))")
        T.expect(ctx.wc.window!.firstResponder === tv, "the page has focus (first responder \(String(describing: ctx.wc.window!.firstResponder)))")
        let top = headTop(target)
        T.expect(abs(top - HeadingJump.landing) < 2, String(format: "the heading is scrolled to %.0f pt under the top, clear of the count strip (line top %.1f)", HeadingJump.landing, top))
        T.expect(r.popover == nil && !r.isOpen, "the popup closed after the jump")
        T.expect(r.activeIndex == i, "the rail's current section is the one jumped to (active \(String(describing: r.activeIndex)), want \(i))")
        settle(ctx)
        T.screenshot(ctx, "outline-jumped-\(appearance).png")
        T.type(ctx, "Z")
        T.expect(ctx.c.state.doc.string.contains("## ZAct 2: Trust and the IC"), "typing lands at the heading")
        T.backspace(ctx)
        T.expect(ctx.c.state.doc.string == text as String, "and undone with a backspace")

        // the first heading from down the page: scroll clamps at the top, the caret is there
        ctx.pane.scrollBy(100_000)
        ctx.wc.window!.makeFirstResponder(nil)
        enter(ctx)
        let pop1 = r.popover!
        settle(ctx)
        T.click(ctx, at: rowPoint(pop1, 0), in: pop1.drawer)
        await T.pause(0.3)
        T.expect(ctx.c.state.selection.main.head == head("Fireside ideas") && abs(headTop("Fireside ideas") - HeadingJump.landing) < 2, "the first row: caret at 'Fireside ideas', the heading at the landing line (line top \(Int(headTop("Fireside ideas"))))")

        // the last heading
        ctx.wc.window!.makeFirstResponder(nil)
        enter(ctx)
        let pop2 = r.popover!
        settle(ctx)
        T.click(ctx, at: rowPoint(pop2, 4), in: pop2.drawer)
        await T.pause(0.3)
        T.expect(ctx.c.state.selection.main.head == head("Act 3: Care is the craft") && ctx.wc.window!.firstResponder === tv, "the last row: caret at 'Act 3', page has focus")
        T.expect(headTop("Act 3: Care is the craft") >= 0 && headTop("Act 3: Care is the craft") < ctx.pane.bounds.height, "the Act 3 heading is on screen (line top \(Int(headTop("Act 3: Care is the craft"))))")

        // with animations on, the popup is still on screen while it goes out, and gone soon after
        OutlineMotion.animations = true
        ctx.wc.window!.makeFirstResponder(nil)
        enter(ctx)
        let pop3 = r.popover!
        _ = await shown(ctx)
        settle(ctx)
        T.click(ctx, at: rowPoint(pop3, 1), in: pop3.drawer)
        await T.pause(0.04)
        T.expect(ctx.c.state.selection.main.head == head("Opener and light moments") && pop3.phase == .hiding, "a click with animations on: the jump is at once, the popup goes out (phase \(pop3.phase))")
        T.expect(await gone(ctx), "and is gone")
        cleanState(ctx, "click")

        // a click on a hiding popup does nothing more
        let before = ctx.c.state.selection.main.head
        enter(ctx)
        _ = await shown(ctx)
        let pop4 = r.popover!
        r.closePopover()
        pop4.drawer.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: pop4.drawer.convert(rowPoint(pop4, 3), to: nil), modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ctx.wc.window!.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        T.expect(ctx.c.state.selection.main.head == before, "a click on a popup that is going out is ignored")
        _ = await gone(ctx)

        // a tick jumps the same way
        OutlineMotion.animations = false
        ctx.wc.window!.makeFirstResponder(nil)
        ctx.pane.scrollBy(-100_000)
        await T.pause(0.1)
        let tick = r.tickRects[3]
        T.click(ctx, at: NSPoint(x: tick.midX, y: tick.midY), in: r)
        await T.pause(0.3)
        T.expect(ctx.c.state.selection.main.head == head("Act 2: Trust and the IC") && ctx.wc.window!.firstResponder === tv && abs(headTop("Act 2: Trust and the IC") - HeadingJump.landing) < 2,
                 "a click on a tick: caret, scroll and focus as for a row (caret \(ctx.c.state.selection.main.head))")

        // a right click on a row still offers Copy heading link
        enter(ctx)
        let pop5 = r.popover!
        settle(ctx)
        let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: pop5.drawer.convert(rowPoint(pop5, 2), to: nil), modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ctx.wc.window!.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        T.expect(pop5.drawer.menu(for: ev)?.items.map(\.title) == [L("Copy heading link")], "a right click on a row still offers Copy heading link")
        r.closePopover()
        OutlineMotion.animations = true
        _ = await gone(ctx)
    }
}
