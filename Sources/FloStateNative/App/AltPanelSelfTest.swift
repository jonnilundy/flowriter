import AppKit
import FloCore
import FloKit

/// Flowriter: the Alternatives panel's close paths, its top edge and a click in its empty space. VM
/// only; scripts/alt-panel-vm-test.sh on Tests/fixtures/combined/pencil-case.md, in the writing
/// space's document window, once per appearance:
///   alt-close        the panel runs the full window height (the tab backing stops at it, as for
///                    Overflow); ⌥A in the add line closes it, ⌥A in the page on the text the panel
///                    shows closes it, ⌥A on other text moves it there; Esc in the page closes it
///                    (Esc in the panel's list first gives the page focus); the panel's own toggle
///                    button closes it by mouse; Format > Alternatives closes it.
///                    Screenshot alt-panel-open-<appearance>.png (a word, a version added, focus in
///                    the page: the state of the report).
///   alt-empty-click  a click in the empty panel area below the list focuses the add line with the
///                    caret ready, so typing adds a version; clicks on a version and on a tab keep
///                    their behaviour. Screenshot alt-panel-empty-click-<appearance>.png.
@MainActor
enum AltPanelScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    typealias A = AlternativesScenarios

    static let names: Set<String> = ["alt-close", "alt-empty-click"]
    static let word = "thumbtack"
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        guard names.contains(name) else { return false }
        OverflowController.animations = false
        AlternativesPanelView.animations = false
        guard let l = await A.layer(ctx) else { return true }
        SelfTestScenarios.installTestMenu()
        A.installTestMenu()
        T.expect(ctx.model.isCompact, "the writing space's document window")
        if name == "alt-close" { await close(ctx, l) } else { await emptyClick(ctx, l) }
        l.flush()
        ctx.model.flushDirtyFiles()
        return true
    }

    // MARK: helpers

    static func panel(_ ctx: Ctx) -> AlternativesPanelView { A.panel(ctx) }

    static func settle(_ ctx: Ctx) async {
        await T.pause(0.2)
        ctx.wc.root.needsLayout = true
        ctx.wc.root.layoutSubtreeIfNeeded()
        A.draw(ctx)
        ctx.wc.window!.displayIfNeeded()
    }

    /// A key the way NSApplication delivers it: the local monitors (the window's key monitor, the
    /// selection bar), then the menus' key equivalents, then the first responder.
    static func appEvent(_ ctx: Ctx, _ chars: String, ignoring: String? = nil, code: UInt16, mods: NSEvent.ModifierFlags = []) {
        let w = ctx.wc.window!
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: ignoring ?? chars,
                                 isARepeat: false, keyCode: code)!
        NSApp.sendEvent(e)
    }
    static func optionA(_ ctx: Ctx) { appEvent(ctx, "å", ignoring: "a", code: 0, mods: [.option]) }
    static func escape(_ ctx: Ctx) { appEvent(ctx, "\u{1b}", code: 53) }

    static func pageHasFocus(_ ctx: Ctx) -> Bool { ctx.wc.window!.firstResponder === ctx.c.textView }

    /// A real click on the page text (the middle of `s`'s first glyph run): focus moves to the page.
    static func clickText(_ ctx: Ctx, _ s: String, offset: Int = 1) {
        let r = A.text(ctx).range(of: s)
        let tv = ctx.c.textView
        ctx.c.ensureFullLayout()
        let rect = tv.firstRect(forCharacterRange: NSRange(location: r.location + offset, length: 1), actualRange: nil)
        let inWindow = tv.window!.convertFromScreen(rect)
        let p = tv.convert(NSPoint(x: inWindow.midX, y: inWindow.midY), from: nil)
        T.click(ctx, at: p, in: tv)
    }

    /// Open on `w` with ⌥A in the page (selection on the word), the add line focused.
    @discardableResult
    static func openOnWord(_ ctx: Ctx, _ what: String, _ w: String = "pushpin") -> NSRange {
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        let r = A.select(ctx, w)
        optionA(ctx)
        T.expect(panel(ctx).isOpen && panel(ctx).inputHasFocus, "\(what): ⌥A on a selected word opens the panel, the add line focused")
        return r
    }

    /// The panel's own toggle in the view tree (found by its accessibility label, not by type).
    static func toggleButton(_ ctx: Ctx) -> NSView? {
        func find(_ v: NSView) -> NSView? {
            if !v.isHiddenOrHasHiddenAncestor, (v.accessibilityLabel() ?? "") == "Hide Alternatives" { return v }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return find(ctx.wc.root)
    }

    /// The panel's tint and hairline run from the window's top to its bottom: nothing of the tab
    /// backing (the title band) covers them, and the backing starts where the panel ends.
    static func expectOneSurface(_ ctx: Ctx, _ what: String) {
        let p = panel(ctx), root = ctx.wc.root
        let f = p.convert(p.bounds, to: root)
        T.expect(abs(f.minY - root.bounds.minY) < 0.5 && abs(f.maxY - root.bounds.maxY) < 0.5,
                 "\(what): the panel spans the window content height (y \(f.minY) to \(f.maxY) of \(root.bounds.height))")
        let backing = root.tabBacking.frame
        T.expect(root.tabBacking.isHidden || backing.minX >= f.maxX - 0.5,
                 "\(what): the title band's backing starts at the panel's edge (backing \(Int(backing.minX))...\(Int(backing.maxX)), panel ends \(Int(f.maxX)))")
    }

    /// In the window screenshot `png`: the panel's top edge (beside the traffic lights, under the
    /// title band) has the panel's own colour, the one it has halfway down.
    static func expectTopPixels(_ ctx: Ctx, _ png: String, _ what: String) {
        let p = panel(ctx), root = ctx.wc.root
        let f = p.convert(p.bounds, to: root)
        guard let img = NSImage(contentsOfFile: (ctx.out as NSString).appendingPathComponent(png)),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { T.expect(false, "\(what): read \(png)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        let scale = CGFloat(rep.pixelsWide) / root.bounds.width
        func px(_ x: CGFloat, _ y: CGFloat) -> NSColor? { rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) }
        let x = f.maxX - 12   // clear of the traffic lights, the file name and the hairline
        guard let top = px(x, 20), let mid = px(x, root.bounds.height / 2) else { T.expect(false, "\(what): pixels"); return }
        let d = max(abs(top.redComponent - mid.redComponent), abs(top.greenComponent - mid.greenComponent), abs(top.blueComponent - mid.blueComponent))
        T.expect(d < 0.006, String(format: "%@: the panel's top edge has the panel's colour (top %.3f, middle %.3f, %d px wide image)", what, top.redComponent, mid.redComponent, rep.pixelsWide))
    }

    // MARK: alt-close

    static func close(_ ctx: Ctx, _ l: AlternativesLayer) async {
        let p = panel(ctx)

        // the report: a word, a version added, focus in the page
        let r = openOnWord(ctx, "open", word)
        A.typeText(ctx, "pushpin")
        A.returnKey(ctx)
        T.expect(l.set(level: .word, at: r.location + 1) != nil, "Return added a version")
        clickText(ctx, "pushpin")
        T.expect(pageHasFocus(ctx) && p.isOpen, "a click in the page: focus in the page, the panel stays open")
        await settle(ctx)
        expectOneSurface(ctx, "open")
        T.screenshot(ctx, "alt-panel-open-\(appearance).png")
        expectTopPixels(ctx, "alt-panel-open-\(appearance).png", "open")
        p.close()

        // keyboard: ⌥A in the add line closes the panel, focus back in the page
        openOnWord(ctx, "⌥A in the add line")
        optionA(ctx)
        T.expect(!p.isOpen, "⌥A in the add line closes the panel (open \(p.isOpen))")
        T.expect(pageHasFocus(ctx), "after ⌥A closed it, focus is in the page")
        if p.isOpen { p.close() }

        // ⌥A in the page on the word the panel shows closes it
        openOnWord(ctx, "⌥A in the page")
        clickText(ctx, "pushpin", offset: 2)
        T.expect(pageHasFocus(ctx) && p.isOpen, "a click on the word: focus in the page, the panel open on it")
        optionA(ctx)
        T.expect(!p.isOpen, "⌥A in the page on the word the panel shows closes it (open \(p.isOpen))")
        if p.isOpen { p.close() }

        // an idle panel follows the page: a phrase it does not show yet, ⌥A moves the panel there (it stays open)
        openOnWord(ctx, "⌥A on other text")
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        _ = A.select(ctx, "ruler")
        p.refresh()
        T.expect(p.rows.first?.text == "ruler", "an idle panel follows the selection onto another word (rows \(p.rows.map(\.text)))")
        _ = A.select(ctx, "a ruler, and some")
        optionA(ctx)
        T.expect(p.isOpen && p.level == .sentence && p.rows.first?.text == "a ruler, and some",
                 "⌥A on a phrase the panel does not show moves the panel to it (open \(p.isOpen), \(p.level.rawValue), rows \(p.rows.map(\.text)))")
        p.close()

        // Esc in the page closes the panel
        openOnWord(ctx, "Esc in the page")
        clickText(ctx, "pushpin")
        escape(ctx)
        T.expect(!p.isOpen, "Esc in the page (a caret, no selection) closes the panel (open \(p.isOpen))")
        if p.isOpen { p.close() }

        // Esc in the panel's list: focus to the page first (the panel stays), the next Esc closes it
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        ctx.c.textView.setSelectedRange(NSRange(location: A.text(ctx).range(of: "pushpin").location + 2, length: 0))
        T.expect(T.leader(ctx, "v") && p.isOpen, "⌘K v opens the panel on the caret")
        ctx.wc.window!.makeFirstResponder(p)
        escape(ctx)
        T.expect(pageHasFocus(ctx) && p.isOpen, "Esc in the panel's list gives the page focus, the panel stays open")
        escape(ctx)
        T.expect(!p.isOpen, "a second Esc, in the page, closes the panel (open \(p.isOpen))")
        if p.isOpen { p.close() }

        // mouse: the panel's own toggle closes it
        openOnWord(ctx, "the toggle button")
        await settle(ctx)
        let b = toggleButton(ctx)
        T.expect(b != nil, "the open panel shows its toggle (Hide Alternatives)")
        if let b = b {
            let inRoot = b.convert(b.bounds, to: ctx.wc.root)
            let pf = p.convert(p.bounds, to: ctx.wc.root)
            T.expect(pf.contains(inRoot) && inRoot.minX - pf.minX <= 20 && pf.maxY - inRoot.maxY <= 60,
                     "the toggle sits in the panel's bottom left corner, mirroring Overflow's (\(inRoot) in \(pf))")
            T.click(ctx, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY), in: b)
            await T.pause(0.1)
            T.expect(!p.isOpen, "a click on the toggle closes the panel (open \(p.isOpen))")
            T.expect(pageHasFocus(ctx), "after the click, focus is in the page")
            T.expect(toggleButton(ctx) == nil, "the toggle goes with the panel")
        }
        if p.isOpen { p.close() }

        // the menu item still toggles
        openOnWord(ctx, "Format > Alternatives")
        let item = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == L("Format") }?.items.first { $0.title == AlternativesAttach.toggleTitle }
        if let m = item?.menu, let i = m.items.firstIndex(where: { $0 === item }) { m.performActionForItem(at: i) }
        T.expect(item != nil && !p.isOpen, "Format > Alternatives closes the panel (item \(item != nil), open \(p.isOpen))")
        if p.isOpen { p.close() }

        // with the panel closed the title band is one strip again
        await settle(ctx)
        let root = ctx.wc.root
        T.expect(abs(root.tabBacking.frame.minX - root.area.frame.minX) < 0.5, "closed: the backing starts at the window's left edge again (\(Int(root.tabBacking.frame.minX)))")
    }

    // MARK: alt-empty-click

    static func emptyClick(_ ctx: Ctx, _ l: AlternativesLayer) async {
        let p = panel(ctx)
        let r = openOnWord(ctx, "empty click", word)
        A.typeText(ctx, "pushpin")
        A.returnKey(ctx)
        guard let set = l.set(level: .word, at: r.location + 1) else { T.expect(false, "a word set after Return"); return }
        clickText(ctx, "pushpin")
        T.expect(pageHasFocus(ctx) && p.isOpen && !p.inputHasFocus, "focus in the page, the add line idle")
        await settle(ctx)

        // a click in the empty area below the list: the add line, the caret ready
        let empty = NSPoint(x: p.bounds.midX, y: p.input.frame.maxY + (p.bounds.height - p.input.frame.maxY) / 2)
        T.click(ctx, at: empty, in: p)
        await T.pause(0.05)
        T.expect(p.inputHasFocus, "a click in the empty panel area focuses the add line (first responder \(String(describing: ctx.wc.window!.firstResponder)))")
        let editor = ctx.wc.window!.firstResponder as? NSTextView
        T.expect(editor?.selectedRange() == NSRange(location: 0, length: 0), "the caret waits at the start of the empty line (\(String(describing: editor?.selectedRange())))")
        await settle(ctx)
        p.display()
        T.screenshot(ctx, "alt-panel-empty-click-\(appearance).png")
        A.typeText(ctx, "eraser")
        A.returnKey(ctx)
        T.expect(l.set(set.id)?.variants.map(\.text) == ["thumbtack", "pushpin", "eraser"] && A.shown(l, set.id) == "eraser",
                 "typing after the click adds a version and shows it (\(l.set(set.id)?.variants.map(\.text) ?? []))")

        // a click lower down, near the bottom: also the add line
        clickText(ctx, "eraser")
        T.click(ctx, at: NSPoint(x: 30, y: p.bounds.height - 90), in: p)
        T.expect(p.inputHasFocus, "a click low in the empty area focuses the add line too")

        // a click on a version keeps its behaviour: shows it, the list has focus
        if let i = p.rows.firstIndex(where: { $0.text == "thumbtack" }) {
            T.click(ctx, at: NSPoint(x: p.textX + 8, y: p.rows[i].rect.midY), in: p)
            T.expect(A.shown(l, set.id) == "thumbtack" && ctx.wc.window!.firstResponder === p, "a click on a version shows it, the list keeps focus")
        } else { T.expect(false, "the thumbtack row") }

        // a click on a tab keeps its behaviour: switches the tab, the list has focus
        if let t = p.tabRects.first(where: { $0.0 == .sentence }) {
            T.click(ctx, at: NSPoint(x: t.1.midX, y: t.1.midY), in: p)
            T.expect(p.level == .sentence && ctx.wc.window!.firstResponder === p, "a click on a tab switches to it, the list keeps focus")
        } else { T.expect(false, "the Sentence tab") }
        p.close()
    }
}
