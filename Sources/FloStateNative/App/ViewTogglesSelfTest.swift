import AppKit
import FloCore
import FloKit

/// Flowriter: the view toggles (`--ui-selftest view-toggles|restart-view-toggles|integrity-reading
/// <post> <out>`, VM only; scripts/view-toggles-vm-test.sh on Tests/fixtures/view-toggles/marks.md).
///   view-toggles          the toggle is hidden while the writing tools are off and shown while on,
///                         the count does not move either way; a stored "alternatives hidden" from
///                         the retired dots toggle is dropped and the decorations draw (and hover)
///                         with no dots button, no View item and no ⌃⌘A; the Markdown toggle
///                         switches to the reading view (marks hidden on the caret line too) and
///                         back, the line at the top of the viewport staying where it was; caret
///                         moves in the reading view move nothing; ⌃⌘M reaches the View menu and
///                         nothing else claims it; screenshots view-toggles-*.png.
///                         Ends with the reading view on, for:
///   restart-view-toggles  a new process: the reading view came back from the defaults.
///   integrity-reading     the integrity suite (IntegritySelfTest.swift) in the reading view.
/// The view states go to the FLO_VIEW_DEFAULTS suite (the scripts set one), never the app's own.
@MainActor
enum ViewTogglesScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static let tol: CGFloat = 0.5
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }
    static let toolsKey = "viewToggleTestToolsWere"
    /// Run in the writing space's document window (SelfTestRunner.run).
    static let names = ["view-toggles", "restart-view-toggles", "integrity-reading"]

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        switch name {
        case "view-toggles": await toggles(ctx)
        case "restart-view-toggles": await restart(ctx)
        case "integrity-reading":
            ViewToggles.readingView = true
            await T.pause(0.3)
            T.expect(RenderPlanner.readingView, "reading view on for the integrity run")
            await Integrity.run(ctx)
            ViewToggles.readingView = false
        default: return false
        }
        return true
    }

    // MARK: helpers

    static func bar(_ ctx: Ctx) -> ViewTogglesView { ctx.wc.root.flowriterToggles }

    static func relayout(_ ctx: Ctx) async {
        ctx.wc.root.needsLayout = true
        ctx.wc.root.layoutSubtreeIfNeeded()
        ctx.wc.window!.displayIfNeeded()
        await T.pause(0.1)
    }

    /// Where the count's text sits: words start, words end, chars start, chars end (root points).
    static func countEdges(_ ctx: Ctx) -> [CGFloat] {
        let count = ctx.wc.root.flowriterCount
        let o = count.origins, s = count.style
        return [o.words, o.words + s.width(count.words), o.chars, o.chars + s.width(count.chars)].map { count.convert(NSPoint(x: $0, y: 0), to: ctx.wc.root).x }
    }

    /// A real ⌃⌘ key: nothing in the window may claim it (the editor's keymap runs there), the
    /// main menu must.
    static func shortcut(_ ctx: Ctx, _ key: String, code: UInt16) -> (window: Bool, menu: Bool) {
        let w = ctx.wc.window!
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                                 isARepeat: false, keyCode: code)!
        if w.firstResponder !== ctx.c.textView { w.makeFirstResponder(ctx.c.textView) }
        if w.performKeyEquivalent(with: e) { return (true, false) }
        return (false, NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false)
    }

    /// The app's menus as FloApp builds them, with the view toggles.
    static func installMenus() {
        NSApp.mainMenu = MainMenu.build(target: MenuRouter())
        AlternativesAttach.installMenu()
        FlowriterSpace.installMenus(in: NSApp.mainMenu!, focused: { nil })
        OverflowMenu.installMenu(in: NSApp.mainMenu!)
        ViewTogglesView.installMenu(in: NSApp.mainMenu!)
    }

    static func allItems(_ m: NSMenu) -> [NSMenuItem] {
        m.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    /// (key, modifiers) of an item as AppKit matches it: an upper-case key implies Shift.
    static func chord(_ i: NSMenuItem) -> String? {
        guard !i.keyEquivalent.isEmpty else { return nil }
        var m = i.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
        if i.keyEquivalent != i.keyEquivalent.lowercased() { m.insert(.shift) }
        return "\(m.rawValue)-\(i.keyEquivalent.lowercased())"
    }

    /// The top of the visual line holding `pos`, measured from the top of the viewport.
    static func screenTop(_ ctx: Ctx, _ pos: Int) -> CGFloat? {
        guard let top = ctx.c.lineTop(at: pos) else { return nil }
        return top - (ctx.c.scrollView.contentView.bounds.minY - ctx.c.textView.textContainerOrigin.y)
    }

    /// Switch the view with `body`; the line at the top must stay there, settled within 300 ms.
    static func keepsTop(_ ctx: Ctx, _ label: String, _ body: () -> Void) async {
        guard let a = ctx.c.topAnchor(), let before = screenTop(ctx, a.pos) else { T.expect(false, "\(label): top line measured"); return }
        let line = ctx.c.state.doc.lineAt(a.pos)
        body()
        var worst: CGFloat = 0, last: CGFloat = .nan
        for _ in 0..<19 {
            await T.pause(0.016)
            if let y = screenTop(ctx, a.pos) { worst = max(worst, abs(y - before)); last = y }
        }
        T.expect(worst <= tol, String(format: "%@: the line at the top stays (doc line %d \"%@…\": %.1f -> %.1f pt from the top, worst %.1f)",
                                      label, line.number, String(line.text.prefix(24)), before, last, worst))
    }

    /// Caret x at `pos` minus caret x at `pos + n` (0: the n characters take no width).
    static func width(_ ctx: Ctx, _ pos: Int, _ n: Int) -> CGFloat {
        guard let a = Integrity.caretRect(ctx, pos), let b = Integrity.caretRect(ctx, pos + n) else { return -1 }
        return b.minX - a.minX
    }

    // MARK: view-toggles

    static func toggles(_ ctx: Ctx) async {
        let c = ctx.c, root = ctx.wc.root
        let store = ViewToggles.defaults
        store.removeObject(forKey: ViewToggles.readingKey)
        store.set(WritingTools.isOn, forKey: toolsKey)
        ViewToggles.readingView = false
        store.set(false, forKey: ViewToggles.retiredAlternativesKey)   // what the dots toggle left behind
        ViewToggles.restore()
        T.expect(store.object(forKey: ViewToggles.retiredAlternativesKey) == nil, "a stored \"alternatives hidden\" is dropped at launch")
        T.expect(!ViewToggles.readingView, "defaults: writing view")
        installMenus()
        await T.pause(0.4)
        let text = c.state.doc.string as NSString

        // tools off: no toggles; on: toggles beside the count, the count where it was
        WritingTools.isOn = false
        await relayout(ctx)
        let count0 = countEdges(ctx), frame0 = root.flowriterCount.frame
        T.expect(bar(ctx).isHidden, "tools off: the toggles are hidden")
        WritingTools.isOn = true
        await relayout(ctx)
        let b = bar(ctx), md = b.markdown
        T.expect(!b.isHidden && !md.isHidden, "tools on: the toggle shows")
        T.expect(b.subviews.compactMap { $0 as? ViewToggleButton }.count == 1, "the three-dots button is gone (\(b.subviews.count) subview)")
        let count1 = countEdges(ctx)
        T.expect(root.flowriterCount.frame == frame0 && zip(count0, count1).allSatisfy { abs($0 - $1) <= tol },
                 "tools on: the count did not move (\(count0.map { Int($0) }) -> \(count1.map { Int($0) }))")
        let mdR = md.convert(md.bounds, to: root)
        let countMidY = root.flowriterCount.frame.midY
        T.log(String(format: "toggle: count %.0f..%.0f, markdown %.0f..%.0f (window %.0f)", count1[0], count1[3], mdR.minX, mdR.maxX, root.bounds.width))
        T.expect(mdR.minX > count1[3] + 4, "the toggle keeps clear of the count's text")
        T.expect(abs(mdR.midY - countMidY) <= 1, "the toggle sits on the count's line")
        T.expect(md.isOn, "the toggle reads on (Markdown marks shown)")
        let offColor = root.flowriterCount.style.color
        md.isOn = false; let off = md.color; md.isOn = true; let on = md.color
        T.expect(off.isEqual(offColor) && on.alphaComponent > off.alphaComponent,
                 String(format: "off draws in the count's colour, on a little stronger (alpha %.2f -> %.2f)", off.alphaComponent, on.alphaComponent))
        // hit testing: the icons take clicks, the rest of the strip does not
        let mid = NSPoint(x: root.bounds.midX, y: countMidY)
        T.expect(root.hitTest(root.convert(NSPoint(x: mdR.midX, y: mdR.midY), to: root.superview)) === md, "a click on M↓ reaches it")
        T.expect(!(root.hitTest(root.convert(mid, to: root.superview)) is ViewToggleButton), "a click on the count does not reach a toggle")

        // alternatives on the page: a word, a sentence, a paragraph
        guard let l = await T.waitFor(3, { c.alternatives }) else { T.expect(false, "alternatives attached"); return }
        let wr = text.range(of: "pencil, and the page")
        let sr = text.range(of: "The rule is simple.")
        let pr = text.range(of: "Most of what I write starts as a list. The list turns into a paragraph when one item refuses to stay short. That is the item worth writing about, and it is never the one I expected.")
        let ids = [l.addVersion("pen, and the page", level: .word, range: wr, show: false),
                   l.addVersion("The rule is short.", level: .sentence, range: sr, show: false),
                   l.addVersion("Most drafts start as a list.", level: .paragraph, range: pr, show: false)]
        T.expect(ids.allSatisfy { $0 != nil }, "three alternatives added")
        c.textView.setSelectedRange(NSRange(location: text.range(of: "**promise**").location + 4, length: 0))
        c.scrollView.contentView.scroll(to: .zero); c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
        c.textView.display()
        await T.pause(0.3)
        T.expect(l.lastDrawn.count == 3, "alternatives drawn (\(l.lastDrawn.count))")
        T.screenshot(ctx, "view-toggles-writing-\(appearance).png")
        shootBar(ctx, "view-toggles-bar-\(appearance).png")

        // no toggle: the decorations stay, hover works, nothing moves
        let g0 = PanelsScenario.lines(ctx)
        let wordSet = ids[0].map { $0.0 }
        let hoverPoint = wordSet.flatMap { l.set($0) }.flatMap { l.segments($0).first }.map { NSPoint(x: $0.rect.midX, y: $0.rect.midY) }
        if let p = hoverPoint { l.mouseMoved(p); T.expect(l.hoveredId == wordSet, "alternatives hover"); l.mouseMoved(.zero) }
        T.expect(PanelsScenario.worst(g0, PanelsScenario.lines(ctx)) <= tol, "hovering moves no line")
        let k1 = shortcut(ctx, "a", code: 0)
        T.expect(!k1.window && !k1.menu, "⌃⌘A is gone (window \(k1.window), menu \(k1.menu))")
        T.expect(l.lastDrawn.count == 3, "alternatives still drawn (\(l.lastDrawn.count) sets)")

        // the shortcut line does not list the toggle
        T.expect(!HintStrip.items.contains { $0.keys == ViewTogglesView.markdownKey.label || $0.label == "dots" || $0.label == "reading" },
                 "shortcut line: \(HintStrip.items.map { "\($0.keys) \($0.label)" })")
        // the menu: Reading View in View, checked by state, no other item on its key; no Show Alternatives
        let items = allItems(NSApp.mainMenu!)
        let mine = items.filter { $0.title == ViewTogglesView.readingTitle }
        T.expect(mine.count == 1 && mine.allSatisfy { i in NSApp.mainMenu!.items.first { $0.title == L("View") }?.submenu?.items.contains(i) == true },
                 "View menu: Reading View (\(mine.count) item)")
        T.expect(!(NSApp.mainMenu!.items.first { $0.title == L("View") }?.submenu?.items.contains { $0.title == "Show Alternatives" } ?? false), "View menu: no Show Alternatives item")
        T.expect(mine.first.map { chord($0) == "\(ViewTogglesView.markdownKey.mods.rawValue)-m" } ?? false, "Reading View keeps ⌃⌘M")
        let viewItems = NSApp.mainMenu!.items.first { $0.title == L("View") }?.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
        T.log("View menu: \(viewItems.prefix(7).joined(separator: " | "))")
        for i in mine {
            let others = items.filter { $0 !== i && chord($0) == chord(i) }
            T.expect(others.isEmpty, "no other menu item on \(i.title)'s shortcut (\(others.map(\.title)))")
        }

        // Tracking Mode: one item on ⌃⌘T, upstream's typewriter item gone, the item flips the setting
        let tracking = items.filter { $0.title == ViewTogglesView.trackingTitle }
        T.expect(tracking.count == 1 && tracking.first.map { chord($0) == "\(ViewTogglesView.trackingKey.mods.rawValue)-t" } == true, "View menu: Tracking Mode on ⌃⌘T (\(tracking.count) item)")
        T.expect(!items.contains { $0.title == L("Toggle Typewriter Scrolling") }, "View menu: no Toggle Typewriter Scrolling item")
        if let t = tracking.first {
            T.expect(items.filter { $0 !== t && chord($0) == chord(t) }.isEmpty, "no other menu item on Tracking Mode's shortcut")
            let was = ViewToggles.tracking
            (t as? ClosureMenuItem)?.handler?()
            await T.pause(0.1)
            T.expect(ViewToggles.tracking == !was && t.state == (ViewToggles.tracking ? .on : .off), "Tracking Mode item flips the setting and its check mark")
            ViewToggles.tracking = was
        }

        // the Markdown toggle: the reading view, from the middle of the post
        let clip = c.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: ((c.textView.frame.height - clip.bounds.height) / 2).rounded()))
        c.scrollView.reflectScrolledClipView(clip)
        await T.pause(0.2)
        let bold = text.range(of: "**soft**").location
        c.textView.setSelectedRange(NSRange(location: bold + 3, length: 0))   // the caret on a line with marks
        await T.pause(0.1)
        let wBold = width(ctx, bold, 2)
        T.expect(wBold > 1, String(format: "writing view: the caret line's ** marks show (%.1f pt)", wBold))
        await keepsTop(ctx, "reading view by a click") { T.click(ctx, at: NSPoint(x: md.bounds.midX, y: md.bounds.midY), in: md) }
        T.expect(ViewToggles.readingView && RenderPlanner.readingView && !md.isOn, "a click on M↓ turns the reading view on")
        let link = text.range(of: "](https://example.com/style)")
        T.expect(abs(width(ctx, bold, 2)) <= tol, String(format: "reading view: the caret line's ** marks are hidden (%.1f pt)", width(ctx, bold, 2)))
        T.expect(abs(width(ctx, link.location, link.length)) <= tol, String(format: "reading view: a link's URL is hidden (%.1f pt)", width(ctx, link.location, link.length)))
        T.expect(mine.first?.state == .on, "View > Reading View is checked")

        // caret moves in the reading view: nothing moves (Integrity's jump check)
        Integrity.jumps = []
        await Integrity.act(ctx, "reading arrow down", .move, Array(repeating: { Integrity.arrow(ctx, "Down") }, count: 6))
        await Integrity.act(ctx, "reading arrow up", .move, Array(repeating: { Integrity.arrow(ctx, "Up") }, count: 6))
        await Integrity.act(ctx, "reading arrow right", .move, Array(repeating: { Integrity.arrow(ctx, "Right") }, count: 6))
        let onLink = text.range(of: "[style guide]").location
        await Integrity.act(ctx, "reading click into a link", .move, [{ c.textView.setSelectedRange(NSRange(location: onLink + 3, length: 0)) }])
        let moves = Integrity.jumps.filter(\.visible)
        T.expect(moves.isEmpty, "reading view: caret moves move nothing (\(moves.count) jumps: \(moves.prefix(3).map { "\($0.action) line \($0.line) \($0.what)" }))")

        // screenshot: the top of the post in the reading view
        clip.scroll(to: .zero); c.scrollView.reflectScrolledClipView(clip)
        c.textView.setSelectedRange(NSRange(location: text.range(of: "**promise**").location + 4, length: 0))
        await T.pause(0.3)
        T.screenshot(ctx, "view-toggles-reading-\(appearance).png")
        clip.scroll(to: NSPoint(x: 0, y: ((c.textView.frame.height - clip.bounds.height) / 3).rounded()))
        c.scrollView.reflectScrolledClipView(clip)
        await T.pause(0.2)
        let k2 = shortcut(ctx, "m", code: 46)
        T.expect(!k2.window && k2.menu, "⌃⌘M: the editor leaves it, the View menu takes it")
        await T.pause(0.3)
        T.expect(!ViewToggles.readingView && md.isOn, "⌃⌘M goes back to the writing view")
        await keepsTop(ctx, "reading view by ⌃⌘M") { _ = shortcut(ctx, "m", code: 46) }
        await keepsTop(ctx, "writing view by ⌃⌘M") { _ = shortcut(ctx, "m", code: 46) }
        T.expect(!ViewToggles.readingView && width(ctx, bold, 2) > 1, "writing view again: marks show")

        // tools off again: the toggles go, the count stays
        WritingTools.isOn = false
        await relayout(ctx)
        T.expect(bar(ctx).isHidden && zip(count0, countEdges(ctx)).allSatisfy { abs($0 - $1) <= tol }, "tools off: toggle hidden, count unchanged")
        T.expect(root.hitTest(root.convert(NSPoint(x: mdR.midX, y: mdR.midY), to: root.superview)) !== md, "tools off: the hidden toggle takes no click")

        // leave a state for restart-view-toggles
        WritingTools.isOn = true
        ViewToggles.readingView = true
        await relayout(ctx)
        ctx.model.flushDirtyFiles()
        l.flush()
    }

    /// Top bar at the window's centre, 360 by 56 pt (screen pixels).
    static func shootBar(_ ctx: Ctx, _ name: String) {
        let w = ctx.wc.window!
        w.displayIfNeeded()
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let f = w.frame
        let path = (ctx.out as NSString).appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(f.midX - 200)),\(Int(screenH - f.maxY)),400,56", path]
        try? p.run(); p.waitUntilExit()
        T.log("screenshot \(name) exit=\(p.terminationStatus)")
    }

    // MARK: restart-view-toggles

    static func restart(_ ctx: Ctx) async {
        let c = ctx.c, root = ctx.wc.root
        installMenus()
        await relayout(ctx)
        await T.pause(0.3)
        T.expect(ViewToggles.readingView && RenderPlanner.readingView, "after a restart: still the reading view")
        let b = bar(ctx)
        T.expect(!b.isHidden && !b.markdown.isOn, "after a restart: the toggle reads off")
        let items = allItems(NSApp.mainMenu!)
        T.expect(items.first { $0.title == ViewTogglesView.readingTitle }?.state == .on, "after a restart: the View menu's check matches")
        let text = c.state.doc.string as NSString
        let bold = text.range(of: "**promise**").location
        c.textView.setSelectedRange(NSRange(location: bold + 3, length: 0))
        await T.pause(0.2)
        T.expect(abs(width(ctx, bold, 2)) <= tol, "after a restart: marks hidden from the first render (caret line too)")
        if let l = c.alternatives {
            c.textView.display()
            T.expect(l.lastDrawn.count == l.session.sets.filter(\.visible).count, "after a restart: the alternatives draw (\(l.lastDrawn.count) of \(l.session.sets.count) sets)")
        }
        T.screenshot(ctx, "view-toggles-restarted-\(appearance).png")
        _ = root
        // back to the defaults for the next run
        let tools = ViewToggles.defaults.object(forKey: toolsKey) as? Bool ?? false
        ViewToggles.readingView = false
        ViewToggles.defaults.removeObject(forKey: ViewToggles.readingKey)
        ViewToggles.defaults.removeObject(forKey: toolsKey)
        WritingTools.isOn = tools
    }
}
