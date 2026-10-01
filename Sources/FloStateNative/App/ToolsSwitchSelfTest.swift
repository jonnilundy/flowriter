import AppKit
import FloCore
import FloKit

/// Flowriter: the word count is the writing tools switch (WritingToolsSwitch.swift). VM only;
/// scripts/tools-vm-test.sh on Tests/fixtures/combined/pencil-case.md, in the writing space's
/// document window:
///   tools              first launch: tools off, panels closed, no squiggle, dots or margin line, no
///                      hover swap; only the count takes clicks in the top strip; hover brightens it;
///                      a real click turns tools on (decorations, the view toggles), another turns them
///                      off; no line, the column or the count moves on either click; Opt-G,
///                      Opt-O and ⌘K s work with tools off and leave them off; ⌘K v
///                      and Opt-A open the panel and turn tools on; tools off leaves the
///                      panel open (closing it can move the column); the shortcut line shows only
///                      with tools on. Ends with tools on. Screenshots tools-switch-<state>-<appearance>.png
///   restart-tools      a new process: tools still on, decorations drawn; a click turns them off
///   restart-tools-off  a new process: tools still off, a plain page; then a long document scrolled
///                      to the very end: a click on and a click off move nothing (the shortcut
///                      line's band changes the scroll box height by 40 pt)
///   tools-shots        the merged build's look, one window: tools off, tools on (the view toggle and
///                      the shortcut line), reading
///                      view, Alternatives panel, Overflow panel. Screenshots tools-shots-<state>-<appearance>.png
@MainActor
enum ToolsScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    typealias A = AlternativesScenarios

    static let names: Set<String> = ["tools", "restart-tools", "restart-tools-off", "tools-shots"]
    static let word = "thumbtack", other = "pushpin"
    static let paragraph = "Writing is mostly deciding what to leave out. The rest takes care of itself, most days."
    static let ghostText = "None of it matters much."
    static let stashed = "I once tried to carry a whole notebook, but it never left the drawer."
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        guard names.contains(name) else { return false }
        OverflowController.animations = false
        AlternativesPanelView.animations = false
        T.expect(ctx.model.isCompact && !ctx.wc.root.flowriterCount.isHidden, "the document window shows the count")
        guard let l = await A.layer(ctx) else { return true }
        SelfTestScenarios.installTestMenu()
        A.installTestMenu()
        switch name {
        case "tools": await firstLaunch(ctx, l)
        case "restart-tools": await restartOn(ctx, l)
        case "tools-shots": await shots(ctx, l)
        default: await restartOff(ctx, l)
        }
        l.flush()
        ctx.c.ghosts?.flushSave()
        ctx.model.flushDirtyFiles()
        return true
    }

    // MARK: helpers

    static func count(_ ctx: Ctx) -> FlowriterCountView { ctx.wc.root.flowriterCount }

    /// What a click at `p` (count coordinates) reaches: the window's whole view tree, title bar included.
    static func hit(_ ctx: Ctx, _ p: NSPoint) -> NSView? {
        let v = count(ctx), w = ctx.wc.window!
        return w.contentView?.superview?.hitTest(v.convert(p, to: nil))
    }

    /// A real click (down through the window, up through the run loop) on the middle of the count.
    @discardableResult
    static func clickCount(_ ctx: Ctx) async -> Bool {
        let v = count(ctx), before = WritingTools.isOn
        T.click(ctx, at: NSPoint(x: v.clickRect.midX, y: v.clickRect.midY), in: v)
        let flipped = await T.waitFor(2) { WritingTools.isOn != before ? true : nil } ?? false
        await T.pause(0.05)
        A.draw(ctx)
        return flipped
    }

    static func moveMouse(_ ctx: Ctx, to p: NSPoint) {
        let v = count(ctx), w = ctx.wc.window!
        let e = NSEvent.mouseEvent(with: .mouseMoved, location: v.convert(p, to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 0, pressure: 0)!
        v.mouseMoved(with: e)
        w.displayIfNeeded()
    }

    /// Everything a toggle must not move: the column (left, top, width, scroll), every visual line,
    /// the text at five places in pane points, the count. Heights of the scroll box and the text
    /// view are left out: the shortcut line's band at the bottom comes and goes with the tools.
    static func layout(_ ctx: Ctx) -> [CGFloat] {
        let v = count(ctx), c = ctx.c, tv = c.textView
        v.refresh()
        ctx.pane.layoutSubtreeIfNeeded()
        let len = c.state.doc.length
        var g: [CGFloat] = [tv.textContainerOrigin.x, tv.textContainerOrigin.y, tv.textContainer?.size.width ?? -1, tv.frame.width,
                            c.scrollView.frame.minX, c.scrollView.frame.minY, c.scrollView.frame.width, c.scrollView.contentView.bounds.origin.y]
        for pos in [0, len / 4, len / 2, len * 3 / 4, len] {
            if let r = c.rect(forPosition: pos, in: ctx.pane) { g += [r.minX, r.minY, r.width, r.height] } else { g.append(-999) }
        }
        return g + PanelsScenario.lines(ctx).flatMap { [$0.x0, $0.x1, $0.y, $0.h] }
            + [v.origins.words, v.origins.chars, v.frame.minX, v.frame.minY, v.frame.width, v.frame.height]
    }

    /// The shortcut line follows the tools (HintStrip gate; the View menu setting is on by default).
    static func expectHints(_ ctx: Ctx, _ on: Bool, _ what: String) {
        ctx.pane.layoutSubtreeIfNeeded()
        let shown = ctx.pane.hints.map { !$0.isHidden } ?? false
        T.expect(HintStrip.isVisible == on && shown == on, "\(what): the shortcut line is \(on ? "shown" : "hidden") (gate \(HintStrip.isVisible), view \(shown ? "visible" : "hidden"))")
    }

    static func expectSame(_ a: [CGFloat], _ b: [CGFloat], _ what: String) {
        let worst = a.count == b.count ? zip(a, b).map { abs($0 - $1) }.max() ?? 0 : .infinity
        T.expect(worst == 0, String(format: "%@: nothing moved (%d numbers, worst %.2f pt)", what, a.count, worst))
        if worst > 0, a.count == b.count {
            let moved = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.prefix(8)
            T.log("\(what): moved " + moved.map { String(format: "#%d %.2f->%.2f", $0.offset, $0.element.0, $0.element.1) }.joined(separator: ", "))
        }
    }

    static func panelOpen(_ ctx: Ctx) -> Bool { ctx.wc.root.area.alternativesPanel?.isOpen == true }
    static func overflowOpen(_ ctx: Ctx) -> Bool { ctx.pane.overflow?.isOpen == true }

    static func expectPlain(_ ctx: Ctx, _ l: AlternativesLayer, _ what: String) {
        A.draw(ctx)
        T.expect(l.lastDrawn.isEmpty, "\(what): no squiggle, dots or margin line (\(l.lastDrawn.count) sets drawn of \(l.session.sets.filter(\.visible).count))")
    }

    static func expectDecorated(_ ctx: Ctx, _ l: AlternativesLayer, _ what: String) {
        A.draw(ctx)
        let w = l.session.sets.first { $0.level == .word }, p = l.session.sets.first { $0.level == .paragraph }
        T.expect(w.flatMap { l.lastDrawn[$0.id]?.squiggle } == true && p.flatMap { l.lastDrawn[$0.id]?.margin } == true,
                 "\(what): the word's squiggle and the paragraph's margin line are drawn (\(l.lastDrawn.count) sets)")
    }

    static func focusText(_ ctx: Ctx) {
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    static func shot(_ ctx: Ctx, _ state: String) { T.screenshot(ctx, "tools-switch-\(state)-\(appearance).png") }

    // MARK: scenarios

    static func firstLaunch(_ ctx: Ctx, _ l: AlternativesLayer) async {
        T.expect(!WritingTools.isOn, "first launch: writing tools off")
        T.expect(!panelOpen(ctx) && !overflowOpen(ctx), "first launch: panels closed")
        expectHints(ctx, false, "first launch")

        // a word with a version, a paragraph with a version, a ghost made with the shortcut while off
        let wr = A.text(ctx).range(of: word), pr = A.text(ctx).range(of: paragraph)
        T.expect(l.addVersion(other, level: .word, range: wr, show: false) != nil, "a version of \"\(word)\"")
        T.expect(l.addVersion("Writing is mostly leaving things out.", level: .paragraph, range: pr, show: false) != nil, "a version of the paragraph")
        _ = A.select(ctx, ghostText)
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(ctx.c.ghosts?.ranges.count == 1 && !WritingTools.isOn, "Opt-G ghosts the sentence with tools off and leaves them off")
        focusText(ctx)
        expectPlain(ctx, l, "tools off")

        // no hover swap while off
        let doc0 = A.text(ctx) as String
        if let s = l.session.sets.first(where: { $0.level == .word }) {
            A.hover(ctx, l, s)
            T.expect(l.hoveredId == nil, "tools off: hovering the word finds nothing")
            ctx.c.textView.setSelectedRange(NSRange(location: s.to, length: 0))
            A.arrow(ctx, down: true)
            T.expect(A.text(ctx) as String == doc0, "tools off: Down does not swap the word")
        }
        focusText(ctx)

        // only the count takes clicks in the top strip; the rest still drags the window
        let v = count(ctx)
        let inside = NSPoint(x: v.clickRect.midX, y: v.clickRect.midY)
        T.expect(hit(ctx, inside) === v, "a click on the count reaches the count")
        T.expect(hit(ctx, NSPoint(x: v.clickRect.maxX + 40, y: v.clickRect.midY)) !== v
                 && hit(ctx, NSPoint(x: v.clickRect.minX - 40, y: v.clickRect.midY)) !== v, "beside the count the strip is not the count (window drag)")
        moveMouse(ctx, to: inside)
        T.expect(v.hovering, "hover: the count brightens")
        shot(ctx, "hover-off")
        moveMouse(ctx, to: NSPoint(x: 20, y: v.clickRect.midY))
        T.expect(!v.hovering, "the pointer leaves: the count goes quiet again")
        A.draw(ctx)
        shot(ctx, "off")

        // click: on, nothing moves
        let g0 = layout(ctx), t0 = v.text
        T.expect(await clickCount(ctx), "a click on the count turns tools on")
        T.expect(WritingTools.isOn && UserDefaults.standard.bool(forKey: "FlowriterWritingToolsOn"), "tools on, stored")
        expectDecorated(ctx, l, "tools on")
        expectHints(ctx, true, "tools on")
        expectSame(g0, layout(ctx), "tools on")
        T.expect(v.text == t0, "the count reads the same (\(v.text))")
        let toggles = ctx.wc.root.flowriterToggles
        let click = v.convert(v.clickRect, to: toggles)
        T.expect(!toggles.isHidden && !click.intersects(toggles.markdown.frame),
                 String(format: "tools on: the view toggle shows, clear of the count's click area (%.1f ... %.1f, icon at %.1f)",
                        click.minX, click.maxX, toggles.markdown.frame.minX))
        if let s = l.session.sets.first(where: { $0.level == .word }) {
            A.hover(ctx, l, s)
            T.expect(l.hoveredId == s.id, "tools on: hovering the word finds it")
            l.mouseMoved(NSPoint(x: -100, y: -100))
        }
        // the shortcut line fades out on a key and back after 2 s: shoot it settled
        _ = await T.waitFor(3) { ctx.pane.hints.map { $0.alphaValue >= 0.999 ? true : nil } ?? true }
        A.draw(ctx)
        shot(ctx, "on")
        moveMouse(ctx, to: inside)
        shot(ctx, "hover-on")
        moveMouse(ctx, to: NSPoint(x: 20, y: v.clickRect.midY))

        // click: off again, nothing moves
        T.expect(await clickCount(ctx), "a second click turns tools off")
        T.expect(!WritingTools.isOn, "tools off")
        expectPlain(ctx, l, "tools off again")
        expectHints(ctx, false, "tools off again")
        expectSame(g0, layout(ctx), "tools off")
        T.expect(ctx.c.ghosts?.ranges.count == 1, "the ghost stays through both clicks")

        // the shortcuts work with tools off
        T.expect(T.appKey(ctx, "o", code: 31, mods: [.option]) && overflowOpen(ctx) && !WritingTools.isOn,
                 "Opt-O opens Overflow, tools stay off")
        T.appKey(ctx, "o", code: 31, mods: [.option])
        T.expect(!overflowOpen(ctx), "Opt-O closes it")
        focusText(ctx)
        _ = A.select(ctx, stashed)
        T.leader(ctx, "s")
        T.expect(!(A.text(ctx) as String).contains(stashed) && overflowOpen(ctx) && !WritingTools.isOn, "⌘K s stashes the paragraph, tools stay off")
        for _ in 0..<3 where !(A.text(ctx) as String).contains(stashed) { T.undo(ctx) }
        T.log("undo after the stash: paragraph back \((A.text(ctx) as String).contains(stashed))")
        ctx.pane.overflow?.setOpen(false)
        focusText(ctx)

        let caretOn = A.text(ctx).range(of: word).location + 2
        ctx.c.textView.setSelectedRange(NSRange(location: caretOn, length: 0))
        T.expect(T.leader(ctx, "v") && panelOpen(ctx) && WritingTools.isOn,
                 "⌘K v opens Alternatives and turns tools on")
        expectDecorated(ctx, l, "after ⌘K v")
        let g1 = layout(ctx)
        T.expect(await clickCount(ctx) && !WritingTools.isOn, "a click on the count turns tools off")
        T.expect(panelOpen(ctx), "tools off leaves the Alternatives panel open")
        expectPlain(ctx, l, "tools off with the panel open")
        expectSame(g1, layout(ctx), "tools off with the panel open")
        ctx.wc.root.area.alternativesPanel?.close()
        focusText(ctx)
        _ = A.select(ctx, "pencil")
        let hitAdd = T.appKey(ctx, "a", code: 0, mods: [.option])
        T.expect(hitAdd && panelOpen(ctx) && WritingTools.isOn, "Opt-A opens Alternatives on the selection and turns tools on")
        ctx.wc.root.area.alternativesPanel?.close()
        focusText(ctx)
        T.expect(WritingTools.isOn && !panelOpen(ctx), "ends with tools on, the panel closed")
    }

    /// The shortcut line settled (it fades out on a key and back after 2 s), panels drawn.
    static func settle(_ ctx: Ctx) async {
        await T.pause(0.2)
        ctx.pane.layoutSubtreeIfNeeded()
        _ = await T.waitFor(3) { ctx.pane.hints.map { $0.isHidden || $0.alphaValue >= 0.999 ? true : nil } ?? true }
        A.draw(ctx)
        ctx.wc.window!.displayIfNeeded()
    }

    /// The pixels agree with the layout: in the window screenshot `png`, the first ink on the line
    /// "The last line stays where it is." sits as far from where the layout puts the line as it does
    /// in the settled tools-on shot (the T's side bearing); a column that moved for a panel while the
    /// text view kept drawing the old place failed this. Returns ink minus layout.
    nonisolated(unsafe) static var bearing: CGFloat?
    @discardableResult
    static func expectDrawnWhereLaidOut(_ ctx: Ctx, _ png: String, _ what: String) -> CGFloat {
        let path = (ctx.out as NSString).appendingPathComponent(png)
        let at = A.text(ctx).range(of: "The last line").location
        guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data),
              let r = ctx.c.rect(forPosition: at, in: ctx.pane) else { T.expect(false, "\(what): screenshot and line rect"); return 0 }
        let w = ctx.wc.window!, inWin = ctx.pane.convert(r, to: nil)
        let scale = CGFloat(rep.pixelsWide) / w.frame.width
        let y = Int(((w.frame.height - inWin.midY) * scale).rounded())
        let left = ctx.wc.root.area.alternativesPanel.flatMap { $0.isOpen ? ctx.pane.convert(NSRect(x: $0.panelWidth(in: ctx.wc.root.area), y: 0, width: 1, height: 1), to: nil).minX : nil } ?? 0
        func lum(_ x: Int) -> CGFloat { guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }; return (c.redComponent + c.greenComponent + c.blueComponent) / 3 }
        let x0 = Int((left + 8) * scale), bg = lum(x0)
        var ink: Int?
        for x in x0..<min(rep.pixelsWide, x0 + Int(600 * scale)) where abs(lum(x) - bg) > 0.25 { ink = x; break }
        let drawn = ink.map { CGFloat($0) / scale } ?? -1
        guard let b = bearing else {
            bearing = drawn - inWin.minX
            T.expect(ink != nil && abs(drawn - inWin.minX) < 6, String(format: "%@: first ink %.1f pt after the laid out line start (%.1f pt)", what, drawn - inWin.minX, inWin.minX))
            return drawn - inWin.minX
        }
        T.expect(abs(drawn - inWin.minX - b) <= 1.5, String(format: "%@: the text is drawn where it is laid out (ink at %.1f pt, layout %.1f pt + %.1f)", what, drawn, inWin.minX, b))
        return drawn - inWin.minX
    }

    static func shots(_ ctx: Ctx, _ l: AlternativesLayer) async {
        ViewToggles.readingView = false
        let wr = A.text(ctx).range(of: word), pr = A.text(ctx).range(of: paragraph)
        T.expect(l.addVersion(other, level: .word, range: wr, show: false) != nil, "a version of \"\(word)\"")
        T.expect(l.addVersion("Writing is mostly leaving things out.", level: .paragraph, range: pr, show: false) != nil, "a version of the paragraph")
        _ = A.select(ctx, ghostText)
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(ctx.c.ghosts?.ranges.count == 1, "a ghost")
        let caret = NSMaxRange(A.text(ctx).range(of: "where it is."))   // end of the last line, clear of the pixel checks
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        ctx.c.textView.setSelectedRange(NSRange(location: caret, length: 0))

        WritingTools.isOn = false
        await settle(ctx)
        expectPlain(ctx, l, "shots: tools off")
        T.screenshot(ctx, "tools-shots-off-\(appearance).png")

        WritingTools.isOn = true
        await settle(ctx)
        expectDecorated(ctx, l, "shots: tools on")
        expectHints(ctx, true, "shots: tools on")
        T.expect(!ctx.wc.root.flowriterToggles.isHidden, "shots: the view toggles show")
        T.log("shots: shortcut line \(ctx.pane.hints?.shown.joined(separator: " | ") ?? "-")")
        T.screenshot(ctx, "tools-shots-on-\(appearance).png")
        expectDrawnWhereLaidOut(ctx, "tools-shots-on-\(appearance).png", "tools on (baseline)")

        ViewToggles.readingView = true
        await settle(ctx)
        T.screenshot(ctx, "tools-shots-reading-\(appearance).png")
        ViewToggles.readingView = false
        await settle(ctx)

        ctx.c.textView.setSelectedRange(NSRange(location: A.text(ctx).range(of: word).location + 2, length: 0))
        T.expect(T.leader(ctx, "v") && panelOpen(ctx), "shots: ⌘K v opens Alternatives")
        await settle(ctx)
        T.screenshot(ctx, "tools-shots-alternatives-\(appearance).png")
        expectDrawnWhereLaidOut(ctx, "tools-shots-alternatives-\(appearance).png", "Alternatives open")
        ctx.wc.root.area.alternativesPanel?.close()
        focusText(ctx)
        await settle(ctx)
        T.screenshot(ctx, "tools-shots-closed-\(appearance).png")
        expectDrawnWhereLaidOut(ctx, "tools-shots-closed-\(appearance).png", "Alternatives closed")

        _ = A.select(ctx, stashed)
        T.leader(ctx, "s")
        T.expect(!(A.text(ctx) as String).contains(stashed) && overflowOpen(ctx), "shots: ⌘K s stashes the paragraph into Overflow")
        ctx.c.textView.setSelectedRange(NSRange(location: NSMaxRange(A.text(ctx).range(of: "where it is.")), length: 0))
        await settle(ctx)
        T.screenshot(ctx, "tools-shots-overflow-\(appearance).png")
    }

    static func restartOn(_ ctx: Ctx, _ l: AlternativesLayer) async {
        T.expect(WritingTools.isOn, "restart: tools still on")
        T.expect(!panelOpen(ctx) && !overflowOpen(ctx), "restart: panels closed")
        T.expect(l.session.sets.count == 2 && ctx.c.ghosts?.ranges.count == 1, "restart: both versions and the ghost are back")
        expectDecorated(ctx, l, "restart with tools on")
        expectHints(ctx, true, "restart with tools on")
        let g0 = layout(ctx)
        T.expect(await clickCount(ctx) && !WritingTools.isOn, "a click turns tools off")
        expectPlain(ctx, l, "after the click")
        expectSame(g0, layout(ctx), "tools off after restart")
    }

    static func restartOff(_ ctx: Ctx, _ l: AlternativesLayer) async {
        T.expect(!WritingTools.isOn, "restart: tools still off")
        T.expect(l.session.sets.count == 2, "restart: the versions are still there (\(l.session.sets.count))")
        expectPlain(ctx, l, "restart with tools off")
        expectHints(ctx, false, "restart with tools off")
        await endOfLongDocument(ctx)
    }

    /// A long document scrolled to the very end: the shortcut line's band changes the scroll box's
    /// height by 40 pt as the tools go on and off, and a click on the count must still move nothing.
    /// Both ways: scrolled to the end with tools off (the taller box), and with tools on.
    static func endOfLongDocument(_ ctx: Ctx) async {
        let filler = (1...40).map { "Filler paragraph \($0) keeps the page long enough to scroll well past one screen of text." }
        let end = ctx.c.state.doc.length
        _ = ctx.c.run { t in t.dispatch(TransactionSpec(changes: [Change(from: end, insert: "\n\n" + filler.joined(separator: "\n\n"))])); return true }
        focusText(ctx)
        await T.pause(0.1)
        for startOn in [false, true] {
            let state = startOn ? "on" : "off", other = startOn ? "off" : "on"
            T.expect(WritingTools.isOn == startOn, "at the end: tools \(state) to start")
            await scrollToEnd(ctx, "tools \(state)")
            let g0 = layout(ctx), box0 = ctx.c.scrollView.frame.height
            T.expect(await clickCount(ctx) && WritingTools.isOn != startOn, "at the end, tools \(state): a click turns them \(other)")
            expectHints(ctx, !startOn, "at the end, tools \(other)")
            T.log(String(format: "at the end: scroll box %.1f -> %.1f pt", box0, ctx.c.scrollView.frame.height))
            expectSame(g0, layout(ctx), "at the end, from \(state): tools \(other)")
            if !startOn { shot(ctx, "end-on") }
            T.expect(await clickCount(ctx) && WritingTools.isOn == startOn, "at the end: a second click turns them \(state) again")
            expectSame(g0, layout(ctx), "at the end, from \(state): tools \(state) again")
            await T.pause(0.3)
            expectSame(g0, layout(ctx), "at the end, from \(state): 0.3 s later")
            if !startOn {
                shot(ctx, "end-off")
                T.expect(await clickCount(ctx) && WritingTools.isOn, "tools on for the second round")
            }
        }
        T.expect(await clickCount(ctx) && !WritingTools.isOn, "ends with tools off")
    }

    /// Scroll so the document's last point is the box's last point (whole points: AppKit rounds a
    /// fractional clip origin on the next frame change, which is not a move the tools made).
    static func scrollToEnd(_ ctx: Ctx, _ what: String) async {
        ctx.pane.layoutSubtreeIfNeeded()
        let clip = ctx.c.scrollView.contentView
        let docH = ctx.c.scrollView.documentView?.frame.height ?? 0
        clip.scroll(to: NSPoint(x: 0, y: max(0, (docH - clip.bounds.height).rounded(.down))))
        ctx.c.scrollView.reflectScrolledClipView(clip)
        await T.pause(0.1)
        A.draw(ctx)
        T.expect(clip.bounds.origin.y > 0 && docH - clip.bounds.maxY < 1,
                 String(format: "%@: a long document scrolled to the very end (y %.1f, box %.1f, document %.1f)", what, clip.bounds.origin.y, clip.bounds.height, docH))
    }
}
