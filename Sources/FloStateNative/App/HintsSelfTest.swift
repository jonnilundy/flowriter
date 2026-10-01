import AppKit
import FloCore
import FloKit

/// Flowriter: the shortcut line (`--ui-selftest hints | hints-restart <post> <out>`, VM only;
/// scripts/writing-ui-vm-test.sh on Tests/fixtures/combined/pencil-case.md), in the writing space's
/// document window:
///   hints          the line is there with its three hints (⌥G ghost, ⌥A alternative, ⌥O overflow,
///                  six spaces apart) in the count's font and colour, centred,
///                  on the Overflow button's centre line, in a band the text never enters (last line
///                  above it after scrolling to the end); it fades on a key (opacity only, <= 200 ms)
///                  and returns after 2 s idle, no line of text moves while it fades; narrow windows
///                  drop hints from the right on one line; an open Overflow panel keeps it clear; the
///                  HintStrip API (register, unregister, setVisible); the shortcut keys (WritingKeys.swift):
///                  each ⌥ key acts and types nothing, in the page and in the Overflow panel; ⌘K then
///                  g, a, o, s, v, l act; ⌘K then x types x and ends the leader; Esc and the 2 s
///                  timeout end it; the line shows the leader letters in the same band while it waits;
///                  the View menu item turns the line off and on and the setting is stored;
///                  screenshots hints-strip-<appearance>.png and hints-leader-<appearance>.png. Ends
///                  with the line turned off, for:
///   hints-restart  a new process honours the stored setting (no line, no band), then turns it back on
@MainActor
enum HintsScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        switch name {
        case "hints": await hints(ctx)
        case "hints-restart": await hintsRestart(ctx)
        default: return false
        }
        return true
    }

    static func text(_ ctx: Ctx) -> NSString { ctx.c.state.doc.string as NSString }
    static func range(_ ctx: Ctx, _ s: String) -> NSRange { text(ctx).range(of: s) }

    // MARK: hints

    static let gap = "      "
    static let fullLine = ["⌥G ghost", "⌥A alternative", "⌥O overflow"].joined(separator: gap)
    static let leaderLine = "g ghost   a alternative   o overflow   s stash   v versions   l link   r recent"

    static func strip(_ ctx: Ctx) -> ShortcutHintsView? { ctx.pane.hints }

    /// Visible text lines of the page, in pane coordinates (their boxes).
    static func visibleLineBoxes(_ ctx: Ctx) -> [CGRect] {
        let c = ctx.c, tv = c.textView
        guard let tlm = tv.textLayoutManager else { return [] }
        let o = tv.textContainerOrigin
        let visible = c.scrollView.contentView.bounds
        var out: [CGRect] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            for lf in f.textLineFragments where lf.characterRange.length > 0 {
                let r = CGRect(x: f.layoutFragmentFrame.minX + o.x, y: f.layoutFragmentFrame.minY + lf.typographicBounds.minY + o.y,
                               width: f.layoutFragmentFrame.width, height: lf.typographicBounds.height)
                guard r.intersects(visible) else { continue }
                out.append(tv.convert(r.intersection(visible), to: ctx.pane))
            }
            return true
        }
        return out
    }

    static func hints(_ ctx: Ctx) async {
        UserDefaults.standard.removeObject(forKey: ShortcutHintsView.defaultsKey)
        await PanelsScenario.resize(ctx, width: 1280)
        let c = ctx.c, pane = ctx.pane
        ctx.wc.window!.makeFirstResponder(c.textView)
        guard let h = strip(ctx) else { T.expect(false, "the pane has a shortcut line"); return }
        pane.applyColumnLayout()
        await T.pause(0.3)

        // 1. on by default, the three hints, the count's font and colour, centred on the window
        T.expect(ShortcutHintsView.enabled && !h.isHidden && h.alphaValue == 1, "on by default and visible")
        T.expect(h.line == fullLine, "the line reads \"\(h.line)\"")
        T.expect(ShortcutHintsView.gap == gap && HintStrip.items.map(\.keys) == ["⌥G", "⌥A", "⌥O"], "six spaces between hints, a key's glyphs together (\(HintStrip.items.map(\.keys)))")
        T.expect(!h.line.contains("swap") && !h.line.contains("versions") && !h.line.contains("stash") && !h.line.contains("dots") && !h.line.contains("reading"),
                 "the normal line has no swap, versions, stash, dots or reading")
        let count = ctx.wc.root.flowriterCount
        T.expect(h.style.font == count.style.font && h.style.color == count.style.color, "same font (\(h.style.font.fontName) \(h.style.font.pointSize)) and colour as the count at the top")
        let tr = h.convert(h.textRect, to: nil)
        let winMid = ctx.wc.window!.contentView!.bounds.midX
        T.expect(abs(tr.midX - winMid) <= 1, String(format: "centred on the window (line centre %.1f, window centre %.1f)", tr.midX, winMid))
        T.expect(abs(h.frame.maxY - pane.bounds.height) < 0.5 && h.frame.height == ShortcutHintsView.band, "the line sits in the \(Int(ShortcutHintsView.band)) pt band at the bottom")
        if let b = pane.overflow?.button, !b.isHidden {
            let lineMid = h.convert(h.textRect, to: pane).midY
            T.expect(abs(lineMid - b.frame.midY) <= 0.5, String(format: "the line shares the Overflow button's centre line (%.1f, %.1f)", lineMid, b.frame.midY))
        }

        // 2. the band is kept free: the scroll box ends above it, the last line clears it
        T.expect(c.scrollView.frame.maxY <= h.frame.minY + 0.5, String(format: "the page ends above the band (%.1f <= %.1f)", c.scrollView.frame.maxY, h.frame.minY))
        func underStrip() -> Int { visibleLineBoxes(ctx).filter { $0.maxY > h.frame.minY + 0.5 }.count }
        var worst = 0
        for y in stride(from: CGFloat(0), through: max(0, c.textView.frame.height), by: 120) {
            c.scrollView.contentView.scroll(to: CGPoint(x: 0, y: y)); c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
            worst = max(worst, underStrip())
        }
        T.expect(worst == 0, "no line of text drawn under the line at any scroll position (\(worst))")
        let end = c.state.doc.length
        c.textView.setSelectedRange(NSRange(location: end, length: 0))
        c.textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        let maxY = max(0, c.textView.frame.height - c.scrollView.contentView.bounds.height)
        c.scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxY)); c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
        await T.pause(0.2)
        let last = visibleLineBoxes(ctx).last
        T.expect(last != nil && last!.maxY <= h.frame.minY && last!.height > 10, String(format: "scrolled to the end, the last line is whole above the band (bottom %.1f, band top %.1f)", last?.maxY ?? -1, h.frame.minY))
        c.scrollView.contentView.scroll(to: .zero); c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
        await T.pause(0.2)
        h.alphaValue = 1
        T.screenshot(ctx, "hints-strip-\(appearance).png")

        // 3. fades on a key, stays faded while typing, back after 2 s; no line moves while it fades
        c.textView.setSelectedRange(NSRange(location: NSMaxRange(range(ctx, "The last line stays where it is.")), length: 0))
        await T.pause(0.3)
        let fades0 = h.fadeCount
        T.type(ctx, "a")
        let before = PanelsScenario.lines(ctx)
        await T.pause(0.07)
        let mid = h.layer?.presentation()?.opacity ?? -1
        T.expect(h.isFaded, "a key fades it out")
        var moved: CGFloat = 0
        for _ in 0..<12 { await T.pause(0.016); moved = max(moved, PanelsScenario.worst(before, PanelsScenario.lines(ctx))) }
        let out = h.layer?.presentation()?.opacity ?? h.layer?.opacity ?? -1
        T.expect(ShortcutHintsView.reduceMotion || (mid > 0.02 && mid < 0.98), "the fade is animated (opacity \(String(format: "%.2f", mid)) at 70 ms)")
        T.expect(out < 0.02, "gone within 250 ms (opacity \(String(format: "%.2f", out)))")
        var visibleWhileTyping = false
        for ch in "bcdef" {
            await T.pause(0.5)
            T.type(ctx, String(ch))
            if !h.isFaded { visibleWhileTyping = true }
        }
        T.expect(!visibleWhileTyping, "stays faded while typing (a key every 0.5 s for 2.5 s)")
        let settled = PanelsScenario.lines(ctx)
        await T.pause(1.6)
        T.expect(h.isFaded, "still faded 1.6 s after the last key")
        var back = false
        for _ in 0..<50 {
            await T.pause(0.016)
            moved = max(moved, PanelsScenario.worst(settled, PanelsScenario.lines(ctx)))
            if !h.isFaded { back = true }
        }
        await T.pause(0.3)
        let final = h.layer?.presentation()?.opacity ?? h.layer?.opacity ?? -1
        T.expect(back && final > 0.98, "back about 2 s after the last key (opacity \(String(format: "%.2f", final)))")
        T.expect(moved <= PanelsScenario.tol, String(format: "no line moved while it faded out and in (worst %.2f pt)", moved))
        T.expect(h.fadeCount == fades0 + 1, "one fade for the whole burst of typing (\(h.fadeCount - fades0))")
        T.backspace(ctx, 6)
        await T.pause(2.4)

        // 4. narrow windows drop hints from the right, on one line
        for width: CGFloat in [760, 560, 420] {
            await PanelsScenario.resize(ctx, width: width)
            pane.applyColumnLayout()
            let shown = h.shown
            let full = HintStrip.items.map { "\($0.keys) \($0.label)" }
            let lineW = h.style.width(h.line)
            T.expect(!shown.isEmpty && Array(full.prefix(shown.count)) == shown && lineW <= h.bounds.width - 2 * ShortcutHintsView.sidePadding,
                     String(format: "%.0f pt window: %d of 3 hints, from the left, %.0f pt line in %.0f pt", width, shown.count, lineW, h.bounds.width))
            if width == 420 {
                // three short hints fit the narrowest window (400 pt): the drop is checked on the fit itself
                T.expect(shown.count == 3 && h.fitting(260).count < 3 && Array(full.prefix(h.fitting(260).count)) == h.fitting(260),
                         "a 260 pt band drops hints from the right (\(h.fitting(260).count) left)")
            }
        }
        await PanelsScenario.resize(ctx, width: 1280)
        pane.applyColumnLayout()

        // 5. an open Overflow panel: the line stays clear of it
        if let ov = pane.overflow {
            ov.setOpen(true, animated: false)
            pane.updateSideReserve(animated: false)
            let lineInPane = h.convert(h.textRect, to: pane)
            T.expect(lineInPane.maxX <= ov.panel.frame.minX, String(format: "Overflow open: the line ends at %.0f, the panel starts at %.0f", lineInPane.maxX, ov.panel.frame.minX))
            ov.setOpen(false, animated: false)
            pane.updateSideReserve(animated: false)
        }

        await keys(ctx, h)

        // 6. the API for other features: an extra hint, hide and show from outside (not stored)
        HintStrip.register(keys: "⌃⌘M", label: "marks")
        await T.pause(0.1)
        T.expect(h.line == fullLine + gap + "⌃⌘M marks", "HintStrip.register adds a hint at the end (\(h.line.suffix(24)))")
        HintStrip.unregister(label: "marks")
        await T.pause(0.1)
        T.expect(h.line == fullLine, "HintStrip.unregister removes it")
        HintStrip.setVisible(false)
        await T.pause(0.1)
        T.expect(h.isHidden && abs(c.scrollView.frame.maxY - (pane.bounds.height - 12)) < 0.5 && ShortcutHintsView.enabled,
                 "HintStrip.setVisible(false) hides the line and gives the band back, the stored setting stays on")
        HintStrip.setVisible(true)
        await T.pause(0.1)
        T.expect(!h.isHidden && c.scrollView.frame.maxY <= h.frame.minY + 0.5, "HintStrip.setVisible(true) shows it again")

        // 7. View > Show Shortcut Hints: off and on, stored
        let viewMenu = NSMenu(title: "View")
        ShortcutHintsView.installMenu(in: viewMenu, at: 0)
        let item = viewMenu.items[0]
        T.expect(item.title == ShortcutHintsView.menuTitle && item.state == .on, "View menu item \"\(item.title)\" is checked")
        viewMenu.performActionForItem(at: 0)
        await T.pause(0.2)
        T.expect(item.state == .off && h.isHidden && !ShortcutHintsView.enabled, "the menu item turns the line off")
        T.expect(UserDefaults.standard.object(forKey: ShortcutHintsView.defaultsKey) as? Bool == false, "the setting is stored")
        T.expect(abs(c.scrollView.frame.maxY - (pane.bounds.height - 12)) < 0.5, "the band is given back to the page when off")
        viewMenu.performActionForItem(at: 0)
        await T.pause(0.2)
        T.expect(item.state == .on && !h.isHidden && c.scrollView.frame.maxY <= h.frame.minY + 0.5, "and on again")
        // leave it off for hints-restart (a new process)
        ShortcutHintsView.setEnabled(false)
        UserDefaults.standard.synchronize()
    }

    // MARK: keys

    static func select(_ ctx: Ctx, _ s: String) {
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        ctx.c.textView.setSelectedRange(range(ctx, s))
    }

    static func panelOpen(_ ctx: Ctx) -> Bool { ctx.wc.root.area.alternativesPanel?.isOpen == true }

    /// The shortcut keys: ⌥G ⌥A ⌥O and the ⌘K leader (WritingKeys.swift).
    static func keys(_ ctx: Ctx, _ h: ShortcutHintsView) async {
        let c = ctx.c, pane = ctx.pane, area = ctx.wc.root.area
        guard let g = c.ghosts, let ov = pane.overflow else { T.expect(false, "ghosts and Overflow attached"); return }
        g.set([])
        ov.setOpen(false, animated: false)
        area.alternativesPanel?.close()
        let sentence = "The last line stays where it is."
        let doc0 = c.state.doc.string
        let overflow0 = ov.text
        func untouched(_ what: String) {
            T.expect(c.state.doc.string == doc0 && ov.text == overflow0, "\(what): no character typed in the page or in Overflow")
        }
        func lineBox() -> CGRect { h.textRect }
        let normalBox = lineBox(), normalFrame = h.frame, normalFont = h.style.font

        // ⌥G ghosts, again revives; ⌥A opens the panel on the selection; ⌥O opens and closes Overflow
        select(ctx, sentence)
        T.expect(T.appKey(ctx, "g", code: 5, mods: [.option]), "⌥G is taken by the window before the page sees it")
        T.expect(g.ranges.count == 1, "⌥G ghosts the selection (\(g.ranges.count) ghosts)")
        untouched("⌥G")
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(g.ranges.isEmpty, "⌥G again revives it")
        untouched("⌥G again")
        select(ctx, "pencil")
        T.expect(T.appKey(ctx, "a", code: 0, mods: [.option]) && panelOpen(ctx), "⌥A adds an alternative: the panel opens on the selection")
        untouched("⌥A")
        area.alternativesPanel?.close()
        ctx.wc.window!.makeFirstResponder(c.textView)
        T.expect(T.appKey(ctx, "o", code: 31, mods: [.option]) && ov.isOpen, "⌥O opens Overflow")
        untouched("⌥O")
        // in the Overflow panel's own text view
        ctx.wc.window!.makeFirstResponder(ov.panel.textView)
        T.expect(T.appKey(ctx, "o", code: 31, mods: [.option]) && !ov.isOpen, "⌥O in the Overflow text closes it")
        untouched("⌥O in Overflow")
        ov.setOpen(true, animated: false)
        ctx.wc.window!.makeFirstResponder(ov.panel.textView)
        select(ctx, sentence)
        ctx.wc.window!.makeFirstResponder(ov.panel.textView)
        T.expect(T.appKey(ctx, "g", code: 5, mods: [.option]) && g.ranges.count == 1, "⌥G in the Overflow text acts on the page selection")
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(g.ranges.isEmpty, "⌥G in the Overflow text again revives")
        untouched("⌥G in Overflow")
        ov.setOpen(false, animated: false)
        select(ctx, sentence)

        // the leader: the line shows the letters, same band and font, nothing shifts
        T.expect(T.appKey(ctx, "k", code: 40, mods: [.command]) && HintStrip.leader && WritingKeys.leaderActive, "⌘K starts the leader")
        T.expect(h.line == leaderLine, "leader line: \"\(h.line)\"")
        T.expect(h.frame == normalFrame && h.textRect.minY == normalBox.minY && h.textRect.height == normalBox.height && h.style.font == normalFont,
                 "leader line: same band, same line height, same font")
        T.expect(abs(h.convert(h.textRect, to: nil).midX - ctx.wc.window!.contentView!.bounds.midX) <= 1, "leader line is centred")
        h.alphaValue = 1
        T.screenshot(ctx, "hints-leader-\(appearance).png")
        T.appKey(ctx, "\u{1b}", code: 53)
        T.expect(!HintStrip.leader && !WritingKeys.leaderActive && h.line == fullLine, "Esc ends the leader, the normal line is back")
        T.expect(c.state.doc.string == doc0, "Esc typed nothing")
        T.appKey(ctx, "k", code: 40, mods: [.command])
        await T.pause(WritingKeys.leaderTimeout + 0.4)
        T.expect(!HintStrip.leader && !WritingKeys.leaderActive && h.line == fullLine, "the leader ends after 2 s, the normal line is back")

        // ⌘K then a letter
        select(ctx, sentence)
        T.expect(T.leader(ctx, "g") && g.ranges.count == 1 && !HintStrip.leader, "⌘K g ghosts the selection")
        T.expect(T.leader(ctx, "g") && g.ranges.isEmpty, "⌘K g again revives it")
        select(ctx, "pencil")
        T.expect(T.leader(ctx, "a") && panelOpen(ctx), "⌘K a adds an alternative")
        area.alternativesPanel?.close()
        ctx.wc.window!.makeFirstResponder(c.textView)
        T.expect(T.leader(ctx, "v") && panelOpen(ctx), "⌘K v shows the versions panel")
        area.alternativesPanel?.close()
        ctx.wc.window!.makeFirstResponder(c.textView)
        T.expect(T.leader(ctx, "o") && ov.isOpen, "⌘K o opens Overflow")
        T.expect(T.leader(ctx, "o") && !ov.isOpen, "⌘K o closes it")
        select(ctx, sentence)
        T.expect(T.leader(ctx, "s") && ov.isOpen && ov.text.contains(sentence) && !c.state.doc.string.contains(sentence), "⌘K s stashes the selection in Overflow")
        T.undo(ctx)
        ov.setOpen(false, animated: false)
        ov.text = overflow0
        ctx.wc.window!.makeFirstResponder(c.textView)
        T.expect(c.state.doc.string == doc0, "the stash is undone")
        // in the Overflow panel's text
        ov.setOpen(true, animated: false)
        ctx.wc.window!.makeFirstResponder(ov.panel.textView)
        T.expect(T.appKey(ctx, "k", code: 40, mods: [.command]) && HintStrip.leader, "⌘K starts the leader in the Overflow text too")
        T.expect(T.appKey(ctx, "o", code: 31) && !ov.isOpen, "⌘K o in the Overflow text closes it")

        // ⌘K then a link
        select(ctx, "pencil")
        T.expect(T.leader(ctx, "l"), "⌘K l is taken by the leader")
        T.expect(c.state.doc.string.contains("[pencil]("), "⌘K l inserts a link on the selection (\(c.state.doc.string.range(of: "[pencil](").map { String(c.state.doc.string[$0.lowerBound...].prefix(20)) } ?? "no link"))")
        T.undo(ctx)
        T.expect(c.state.doc.string == doc0, "the link is undone")

        // ⌘K then any other key: the key is typed, the leader is over
        c.textView.setSelectedRange(NSRange(location: NSMaxRange(range(ctx, sentence)), length: 0))
        T.appKey(ctx, "k", code: 40, mods: [.command])
        let taken = T.appKey(ctx, "x", code: 7)
        T.expect(!taken && !HintStrip.leader && !WritingKeys.leaderActive, "⌘K x: the leader ends and x goes on to the page")
        T.expect(c.state.doc.string == (doc0 as NSString).replacingCharacters(in: NSRange(location: NSMaxRange(range(ctx, sentence)), length: 0), with: "x"), "⌘K x typed x")
        T.expect(h.line == fullLine, "and the normal line is back")
        T.undo(ctx)
        T.expect(c.state.doc.string == doc0, "x is undone")
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        g.set([])
    }

    static func hintsRestart(_ ctx: Ctx) async {
        let pane = ctx.pane, c = ctx.c
        pane.applyColumnLayout()
        await T.pause(0.3)
        T.expect(!ShortcutHintsView.enabled, "the stored setting is off after a restart")
        T.expect(pane.hints?.isHidden ?? true, "no line after a restart with the setting off")
        T.expect(abs(c.scrollView.frame.maxY - (pane.bounds.height - 12)) < 0.5, "and no band")
        ShortcutHintsView.setEnabled(true)
        await T.pause(0.2)
        T.expect(pane.hints?.isHidden == false && ShortcutHintsView.enabled, "turned back on")
        UserDefaults.standard.synchronize()
    }
}
