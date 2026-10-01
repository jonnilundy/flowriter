import AppKit
import FloCore
import FloKit

/// Alternatives scenarios for `--ui-selftest` (VM only; scripts/alternatives-vm-test.sh).
/// Run in order on one copy of Tests/fixtures/alternatives/pencil-case.md: `alt-word`,
/// `alt-sentence`, `alt-paragraph`, then `alt-reopen` (a new process on the saved files).
/// Screenshots get the appearance as suffix (FLO_TEST_APPEARANCE, default light).
@MainActor
enum AlternativesScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        switch name {
        case "alt-word": await word(ctx)
        case "alt-sentence": await sentence(ctx)
        case "alt-paragraph": await paragraph(ctx)
        case "alt-reopen": await reopen(ctx)
        default: return false
        }
        return true
    }

    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }
    static func shot(_ ctx: Ctx, _ name: String) { T.screenshot(ctx, "alternatives-\(name)-\(appearance).png") }

    // MARK: helpers

    static func layer(_ ctx: Ctx) async -> AlternativesLayer? {
        AlternativesPanelView.animations = false   // frames and screenshots right after open / close
        await T.pause(0.6)   // the window's first layouts (sidebar, tab strip) settle
        ctx.wc.window?.contentView?.needsLayout = true
        ctx.wc.window?.contentView?.layoutSubtreeIfNeeded()
        if ctx.wc.window?.firstResponder !== ctx.c.textView {
            T.log("note: first responder after open is \(String(describing: ctx.wc.window?.firstResponder)); focusing the text")
            ctx.wc.window?.makeFirstResponder(ctx.c.textView)
        }
        let l = await T.waitFor(3) { ctx.c.alternatives }
        T.expect(l != nil, "alternatives layer attached")
        return l
    }

    static func panel(_ ctx: Ctx) -> AlternativesPanelView { AlternativesAttach.panel(ctx.wc.root.area) }
    static func text(_ ctx: Ctx) -> NSString { ctx.c.state.doc.string as NSString }
    static func select(_ ctx: Ctx, _ s: String) -> NSRange {
        let r = text(ctx).range(of: s)
        ctx.c.textView.setSelectedRange(r)
        return r
    }

    static func draw(_ ctx: Ctx) {
        ctx.c.textView.display()
        ctx.wc.window!.displayIfNeeded()
    }

    /// The dots sit centred under the set's last text segment (within 1 pt), on the squiggle's line,
    /// and touch no other set's dots or squiggle.
    static func expectDotsCentered(_ l: AlternativesLayer, _ s: AlternativeSet, _ label: String) {
        guard let last = l.segments(s).last, let ds = Optional(l.dots(s)), ds.count == 3 else { T.expect(false, "\(label): dots exist"); return }
        let cx = (ds[0].minX + ds[2].maxX) / 2
        T.expect(abs(cx - last.rect.midX) <= 1, String(format: "%@: dots centred under the text (dots %.1f, text %.1f..%.1f, centre %.1f)", label, cx, last.rect.minX, last.rect.maxX, last.rect.midX))
        T.expect(abs(ds[1].midY - (last.baseline + AlternativesLayer.underlineOffset)) <= 0.5, "\(label): dots sit on the squiggle's line")
        let own = l.squiggleSpans(s)
        T.expect(!own.contains { $0.x1 > ds[0].minX && $0.x0 < ds[2].maxX }, "\(label): no squiggle runs through its own dots")
        var clash: [String] = []
        for o in l.session.sets where o.id != s.id && o.visible {
            if l.dots(o).contains(where: { r in ds.contains { $0.insetBy(dx: -1, dy: -1).intersects(r) } }) { clash.append("\(o.id) dots") }
            if l.squiggleSpans(o).contains(where: { sp in abs(sp.y - (last.baseline + AlternativesLayer.underlineOffset)) < 6 && sp.x1 > ds[0].minX - 1 && sp.x0 < ds[2].maxX + 1 }) { clash.append("\(o.id) squiggle") }
        }
        T.expect(clash.isEmpty, "\(label): dots clear of neighbouring sets' decoration \(clash)")
    }

    static func arrow(_ ctx: Ctx, down: Bool) {
        let ch = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        T.key(ctx, ch, code: down ? 125 : 126, mods: [.function, .numericPad])
    }
    static func returnKey(_ ctx: Ctx) { T.key(ctx, "\r", code: 36) }
    static func escape(_ ctx: Ctx) { T.key(ctx, "\u{1b}", code: 53) }
    static func deleteKey(_ ctx: Ctx) { T.key(ctx, "\u{7f}", code: 51) }
    static func redo(_ ctx: Ctx) { T.key(ctx, "z", code: 6, mods: [.command, .shift]) }

    /// Type into whatever has focus (the panel's field).
    static func typeText(_ ctx: Ctx, _ s: String) { for ch in s { T.key(ctx, String(ch), code: ch == " " ? 49 : 0) } }

    /// A mouse move over the middle of a set's first text segment (the text view's own handler).
    static func hover(_ ctx: Ctx, _ l: AlternativesLayer, _ s: AlternativeSet, margin: Bool = false) {
        let p: NSPoint
        if margin, let m = l.marginLine(s) { p = NSPoint(x: m.midX, y: m.midY) }
        else { guard let seg = l.segments(s).first else { return }; p = NSPoint(x: seg.rect.midX, y: seg.rect.midY) }
        let w = ctx.wc.window!
        let e = NSEvent.mouseEvent(with: .mouseMoved, location: ctx.c.textView.convert(p, to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 0, pressure: 0)!
        ctx.c.textView.mouseMoved(with: e)
    }

    static func shown(_ l: AlternativesLayer, _ id: String) -> String {
        guard let s = l.set(id), let v = s.variants.first(where: { $0.id == s.currentId }) else { return "<none>" }
        return l.text(of: v, in: s)
    }

    static func currentIndex(_ l: AlternativesLayer, _ id: String) -> Int {
        guard let s = l.set(id) else { return -1 }
        return s.variants.firstIndex { $0.id == s.currentId } ?? -1
    }

    /// Rects of each probe string's first occurrence (view coordinates).
    static func geometry(_ ctx: Ctx, _ l: AlternativesLayer, _ probes: [String]) -> [String: [NSRect]] {
        ctx.c.ensureFullLayout()
        var out: [String: [NSRect]] = [:]
        for p in probes {
            let r = text(ctx).range(of: p)
            if r.location != NSNotFound { out[p] = l.segments(r.location, NSMaxRange(r)).map(\.rect) }
        }
        return out
    }

    /// Height of the paragraph (source line) that holds `s`.
    static func paragraphHeight(_ ctx: Ctx, _ l: AlternativesLayer, containing s: String) -> CGFloat {
        let t = text(ctx)
        let r = t.range(of: s)
        guard r.location != NSNotFound, let p = AltText.paragraph(in: t, at: r.location) else { return -1 }
        let segs = l.segments(p.location, NSMaxRange(p))
        guard let a = segs.first, let b = segs.last else { return -1 }
        return b.rect.maxY - a.rect.minY
    }

    /// Integrity: text before the edited paragraph does not move; text after it moves only by
    /// the paragraph's change in height, and never sideways.
    static func expectOnlyReflow(_ ctx: Ctx, _ l: AlternativesLayer, before: [String: [NSRect]], after: [String: [NSRect]],
                                 above: [String], below: [String], dh: CGFloat, _ what: String) {
        var worst: CGFloat = 0
        var detail: [String] = []
        for p in above {
            guard let a = before[p], let b = after[p], a.count == b.count else { detail.append("\(p): missing"); worst = .infinity; continue }
            for (x, y) in zip(a, b) { worst = max(worst, abs(x.minX - y.minX), abs(x.minY - y.minY), abs(x.width - y.width)) }
        }
        for p in below {
            guard let a = before[p], let b = after[p], a.count == b.count else { detail.append("\(p): missing"); worst = .infinity; continue }
            for (x, y) in zip(a, b) { worst = max(worst, abs(x.minX - y.minX), abs((y.minY - x.minY) - dh), abs(x.width - y.width)) }
        }
        T.expect(worst < 0.01, "\(what): text outside the swapped paragraph moved only by its reflow (dh \(dh), worst deviation \(String(format: "%.3f", worst)) pt) \(detail.joined(separator: ","))")
    }

    static func expectTextOutside(_ ctx: Ctx, before: String, range: NSRange, articleSlack: Int, _ what: String) {
        let now = text(ctx) as String
        let b = before as NSString, n = now as NSString
        let headLen = max(0, range.location - articleSlack)
        let head = b.substring(to: headLen), tail = b.substring(from: NSMaxRange(range))
        T.expect(n.substring(to: headLen) == head && now.hasSuffix(tail), "\(what): every character outside the swapped range is unchanged")
    }

    static func diskText(_ ctx: Ctx) -> String { (try? String(contentsOfFile: ctx.file, encoding: .utf8)) ?? "" }

    static func sidecarJSON(_ l: AlternativesLayer) -> String { (try? String(contentsOf: l.sidecarURL, encoding: .utf8)) ?? "" }

    /// Wait for the document autosave and the sidecar save.
    static func settle(_ ctx: Ctx, _ l: AlternativesLayer) async {
        l.flush()
        ctx.model.flushDirtyFiles()
        await T.pause(0.2)
    }

    static let above = ["I keep a pencil in my bag.", "Pencil case"]
    static let below = ["Writing is mostly deciding", "The last line stays where it is."]

    // MARK: word

    static func word(_ ctx: Ctx) async {
        guard let l = await layer(ctx) else { return }
        let p = panel(ctx)
        installTestMenu()

        // Add Alternative… (the menu item) on a selected word: the panel opens on the Word tab, field focused
        let r = select(ctx, "thumbtack")
        let add = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == L("Format") }?.items.first { $0.title == AlternativesAttach.addTitle }
        T.expect(add != nil && add?.keyEquivalent == "a" && add?.keyEquivalentModifierMask == [.option], "Format menu has \(AlternativesAttach.addTitle) on ⌥A")
        if let m = add?.menu, let i = m.items.firstIndex(where: { $0 === add }) { m.performActionForItem(at: i) }
        T.expect(p.isOpen && p.level == .word, "panel open on the Word tab (open \(p.isOpen), level \(p.level.rawValue))")
        T.expect(p.hasFocus, "the panel's field has focus")
        T.expect(p.rows.count == 1 && p.rows.first?.text == "thumbtack", "panel lists the current text as the only version (\(p.rows.map(\.text)))")

        let g0 = geometry(ctx, l, above + below)
        let h0 = paragraphHeight(ctx, l, containing: "thumbtack")
        let before = text(ctx) as String
        typeText(ctx, "eraser")
        returnKey(ctx)
        guard let set = l.set(level: .word, at: r.location + 2) else { T.expect(false, "a word set exists after Return"); return }
        let id = set.id
        T.expect(text(ctx).range(of: "also holds an eraser, a ruler").location != NSNotFound, "Return added the version and shows it: \"a thumbtack\" became \"an eraser\"")
        T.expect(set.variants.map(\.text) == ["thumbtack", "eraser"] && set.variants.allSatisfy { $0.author == .me }, "the set holds thumbtack + eraser, both by the writer")
        T.expect(p.rows.count == 2 && p.rows.last?.current == true && p.rows.first?.original == true, "panel rows: original thumbtack, current eraser")
        expectTextOutside(ctx, before: before, range: r, articleSlack: 2, "word swap")
        let g1 = geometry(ctx, l, above + below)
        expectOnlyReflow(ctx, l, before: g0, after: g1, above: above, below: below, dh: paragraphHeight(ctx, l, containing: "eraser") - h0, "word swap")

        typeText(ctx, "pushpin")
        draw(ctx); p.display()
        shot(ctx, "panel-typing")
        returnKey(ctx)
        T.expect(shown(l, id) == "pushpin" && text(ctx).range(of: "holds a pushpin,").location != NSNotFound, "a second version: \"a pushpin\" (article back to a)")
        // an AI version (the model API; the UI only shows its mark)
        l.addVersion("paperclip", author: .ai, level: .word, range: NSRange(location: l.set(id)!.from, length: l.set(id)!.to - l.set(id)!.from), show: false)
        p.refresh()
        T.expect(p.rows.map(\.author) == [.me, .me, .me, .ai], "panel marks: three bullets, one bot (\(p.rows.map(\.author.rawValue)))")
        ctx.c.textView.setSelectedRange(NSRange(location: l.set(id)!.to, length: 0))
        p.refresh()
        draw(ctx)
        T.expect(l.lastDrawn[id]?.squiggle == true && l.lastDrawn[id]?.highlightedDot == true, "squiggle drawn, middle dot highlighted (not the original)")
        expectPlainList(p, "panel")
        expectDotsCentered(l, l.set(id)!, "word")
        shot(ctx, "panel")
        // hover on a version that is not shown: colour only
        if let row = p.rows.indices.first(where: { !p.rows[$0].current }) {
            let w = ctx.wc.window!
            let pt = p.convert(NSPoint(x: p.textX + 10, y: p.rows[row].rect.midY), to: nil)
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { p.mouseMoved(with: e) }
            p.display()
            shot(ctx, "panel-hover")
            p.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                      context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        }
        // a wider window: the panel grows with the margin
        if let w = ctx.wc.window {
            let f0 = w.frame
            w.setFrame(NSRect(x: f0.minX, y: f0.minY, width: 1500, height: f0.height), display: true)
            ctx.wc.root.layoutSubtreeIfNeeded()
            await T.pause(0.5)
            ctx.wc.root.layoutSubtreeIfNeeded()
            p.refresh(); p.display()
            T.log(String(format: "panel at 1500 pt: %.0f pt wide", p.bounds.width))
            expectPlainList(p, "wide panel")
            shot(ctx, "panel-wide")
            w.setFrame(f0, display: true)
            ctx.wc.root.layoutSubtreeIfNeeded()
            await T.pause(0.5)
            ctx.wc.root.layoutSubtreeIfNeeded()
            p.refresh()
        }

        // hover + arrows in the page
        escape(ctx)
        T.expect(ctx.wc.window!.firstResponder === ctx.c.textView, "Escape returns focus to the text")
        T.expect(!p.isOpen, "Escape ends the Add Alternative session: the panel closes")
        if let s = l.set(id) {
            T.expect(ctx.c.textView.selectedRange() == NSRange(location: s.from, length: s.to - s.from),
                     "Escape gives the page its selection back, on the shown version (\(ctx.c.textView.selectedRange()))")
        }
        hover(ctx, l, l.set(id)!)
        T.expect(l.hoveredId == id, "hover finds the set under the pointer")
        let caretBefore = ctx.c.state.selection.main.head
        arrow(ctx, down: true)     // pushpin -> paperclip
        T.expect(shown(l, id) == "paperclip", "Down swaps to the next version in place (\(shown(l, id)))")
        arrow(ctx, down: true)     // paperclip -> thumbtack (wraps)
        T.expect(shown(l, id) == "thumbtack" && text(ctx).range(of: "holds a thumbtack,").location != NSNotFound, "Down wraps to the original: \"a thumbtack\"")
        draw(ctx)
        T.expect(l.lastDrawn[id]?.highlightedDot == false, "middle dot plain on the original")
        arrow(ctx, down: false)    // back to paperclip
        arrow(ctx, down: false)    // pushpin
        T.expect(shown(l, id) == "pushpin", "Up steps back (\(shown(l, id)))")
        T.expect(abs(ctx.c.state.selection.main.head - caretBefore) <= 3, "hover swaps do not move the caret into the text")

        // undo / redo restore text and the current version
        let textPushpin = text(ctx) as String
        T.undo(ctx)
        T.expect(shown(l, id) == "paperclip" && l.set(id)?.variants[currentIndex(l, id)].text == "paperclip", "Undo: back to paperclip (text and current version)")
        T.undo(ctx)
        T.expect(shown(l, id) == "thumbtack" && l.set(id)?.currentId == l.set(id)?.originalId, "Undo again: the original is current")
        redo(ctx); redo(ctx)
        T.expect(shown(l, id) == "pushpin" && text(ctx) as String == textPushpin, "Redo twice: pushpin, same text as before")

        // arrows in the panel preview in the page
        AlternativesAttach.toggle(ctx.wc.root.area)   // opens on the caret (Escape closed it)
        ctx.c.textView.setSelectedRange(NSRange(location: l.set(id)!.from + 1, length: 0))
        p.refresh()
        ctx.wc.window!.makeFirstResponder(p)
        T.expect(p.level == .word && p.rows.count == 4, "panel follows the caret onto the word (\(p.level.rawValue), \(p.rows.count) rows)")
        arrow(ctx, down: true)
        T.expect(shown(l, id) == "paperclip" && p.rows[3].current, "panel Down previews paperclip in the page")
        p.display()
        shot(ctx, "panel-ai")
        arrow(ctx, down: false); arrow(ctx, down: false)
        T.expect(shown(l, id) == "eraser" && text(ctx).range(of: "holds an eraser,").location != NSNotFound, "panel Up twice: eraser, \"an eraser\" in the page")

        // Delete in the panel removes the shown version; down to one version, the underline goes
        let r2 = select(ctx, "ruler")
        AlternativesAttach.addAlternative(ctx.wc.root.area)
        typeText(ctx, "tape measure"); returnKey(ctx)
        guard let ruler = l.set(level: .word, at: r2.location + 1) else { T.expect(false, "ruler set"); return }
        T.expect(text(ctx).range(of: "a tape measure, and").location != NSNotFound, "second word set: ruler -> tape measure")
        ctx.wc.window!.makeFirstResponder(p)
        deleteKey(ctx)
        T.expect(l.set(ruler.id) == nil && text(ctx).range(of: "an eraser, a ruler, and").location != NSNotFound,
                 "Delete removed the shown version; one left, so the set is gone and the original text stays")
        draw(ctx)
        T.expect(l.lastDrawn[ruler.id] == nil, "no underline on ruler any more")

        // the word screenshot: panel closed, the eraser version shown
        AlternativesAttach.toggle(ctx.wc.root.area)
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        l.mouseMoved(.zero)
        draw(ctx)
        await T.pause(0.2)
        shot(ctx, "word")

        // a short word (3 letters) next to the eraser set: its dots are wider than the word
        let r3 = select(ctx, "ruler")
        AlternativesAttach.addAlternative(ctx.wc.root.area)
        typeText(ctx, "pen"); returnKey(ctx)
        if let pen = l.set(level: .word, at: r3.location + 1) {
            ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
            l.mouseMoved(.zero)
            draw(ctx)
            expectDotsCentered(l, pen, "short word")
            expectDotsCentered(l, l.set(id)!, "word beside a short word")
            await T.pause(0.2)
            shot(ctx, "dots-short")
            ctx.wc.window!.makeFirstResponder(p)
            deleteKey(ctx)   // back to "ruler"
            AlternativesAttach.toggle(ctx.wc.root.area)
            T.expect(l.set(pen.id) == nil && text(ctx).range(of: "an eraser, a ruler, and").location != NSNotFound, "short word set removed, ruler back")
        } else { T.expect(false, "short word set exists") }
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        draw(ctx)

        await settle(ctx, l)
        let md = diskText(ctx)
        T.expect(md.contains("holds an eraser, a ruler") && !md.contains("pushpin") && !md.contains("paperclip") && !md.contains("thumbtack"),
                 "the .md holds only the current text")
        let json = sidecarJSON(l)
        T.expect(json.contains("\"pushpin\"") && json.contains("\"paperclip\"") && json.contains("\"ai\""), "sidecar \(l.sidecarURL.lastPathComponent) holds every version")
    }

    // MARK: sentence

    static func sentence(_ ctx: Ctx) async {
        guard let l = await layer(ctx) else { return }
        let p = panel(ctx)
        T.expect(l.session.sets.count == 1, "the word set came back from the sidecar (\(l.session.sets.count) sets)")
        let target = "None of it matters much."
        let r = text(ctx).range(of: target)
        ctx.c.textView.setSelectedRange(NSRange(location: r.location + 5, length: 0))
        AlternativesAttach.toggle(ctx.wc.root.area)
        T.expect(p.isOpen, "the versions action (⌘K v) opens the panel on the caret")
        ctx.wc.window!.makeFirstResponder(p)
        T.key(ctx, String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124, mods: [.function, .numericPad])
        T.expect(p.level == .sentence && p.rows.first?.text == target, "Right switches to the Sentence tab on \"\(p.rows.first?.text ?? "")\"")
        let g0 = geometry(ctx, l, above + below)
        let h0 = paragraphHeight(ctx, l, containing: target)
        let before = text(ctx) as String
        typeText(ctx, "Nothing in it is precious.")   // typing in the panel goes to the field
        returnKey(ctx)
        guard let s = l.set(level: .sentence, at: r.location + 2) else { T.expect(false, "sentence set"); return }
        T.expect(shown(l, s.id) == "Nothing in it is precious.", "sentence version shown in place")
        expectTextOutside(ctx, before: before, range: r, articleSlack: 0, "sentence swap")
        expectOnlyReflow(ctx, l, before: g0, after: geometry(ctx, l, above + below), above: above, below: below,
                         dh: paragraphHeight(ctx, l, containing: "precious") - h0, "sentence swap")
        l.addVersion("The rest is clutter I carry anyway, and I would not miss much of it if it all fell out of my bag on the train one grey morning in March.", author: .ai, level: .sentence,
                     range: NSRange(location: s.from, length: s.to - s.from), show: false)

        // hover + Down to the long AI version: the paragraph may wrap to another line
        escape(ctx)
        let h1 = paragraphHeight(ctx, l, containing: "precious")
        let g1 = geometry(ctx, l, above + below)
        hover(ctx, l, l.set(s.id)!)
        arrow(ctx, down: true)
        T.expect(shown(l, s.id).hasPrefix("The rest is clutter"), "Down shows the AI version")
        expectOnlyReflow(ctx, l, before: g1, after: geometry(ctx, l, above + below), above: above, below: below,
                         dh: paragraphHeight(ctx, l, containing: "clutter") - h1, "long sentence swap")
        T.expect(l.set(s.id)?.variants.last?.author == .ai, "the AI version keeps its author while untouched")
        // editing the shown AI version makes it the writer's
        ctx.c.textView.setSelectedRange(NSRange(location: l.set(s.id)!.from + 4, length: 0))
        T.type(ctx, "x")
        T.expect(l.set(s.id)?.variants.last?.author == .me, "typing inside the shown AI version makes it author \"me\"")
        T.undo(ctx)
        T.expect(shown(l, s.id).hasPrefix("The rest is clutter I carry"), "undo the typing")
        T.undo(ctx)
        T.expect(shown(l, s.id) == "Nothing in it is precious.", "undo the swap: the previous sentence version is current again")
        redo(ctx)
        T.expect(shown(l, s.id).hasPrefix("The rest is clutter"), "redo the swap")
        T.undo(ctx)
        T.expect(p.rows.count == 3, "panel lists original + two versions")
        expectDotsCentered(l, l.set(s.id)!, "sentence")
        shot(ctx, "sentence")
        // the original stays the first line: remove it and the oldest version left takes its place, on top
        p.remove(row: 0)
        T.expect(p.rows.count == 2 && p.rows.first?.original == true && p.rows.first?.text == "Nothing in it is precious.",
                 "removing the original: the oldest version left is the original, on the first line (\(p.rows.map { $0.text.prefix(12) }))")
        expectPlainList(p, "sentence")
        AlternativesAttach.toggle(ctx.wc.root.area)
        await settle(ctx, l)
    }

    // MARK: paragraph

    static func paragraph(_ ctx: Ctx) async {
        guard let l = await layer(ctx) else { return }
        let p = panel(ctx)
        T.expect(l.session.sets.count == 2, "word + sentence sets came back (\(l.session.sets.count))")
        let para = "Writing is mostly deciding what to leave out. The rest takes care of itself, most days."
        let r = text(ctx).range(of: para)
        ctx.c.textView.setSelectedRange(NSRange(location: r.location + 3, length: 0))
        AlternativesAttach.toggle(ctx.wc.root.area)
        ctx.wc.window!.makeFirstResponder(p)
        p.setLevel(.paragraph)
        T.expect(p.rows.first?.text == para, "Paragraph tab targets the whole paragraph")
        let aboveP = ["I keep a pencil in my bag.", "The case also holds", "Pencil case"]
        let belowP = ["The last line stays where it is."]
        let g0 = geometry(ctx, l, aboveP + belowP)
        let h0 = paragraphHeight(ctx, l, containing: "Writing is mostly")
        let before = text(ctx) as String
        ctx.wc.window!.makeFirstResponder(p.input)
        typeText(ctx, "Writing is choosing what stays. Everything else can wait for another draft, or for nobody at all.")
        returnKey(ctx)
        guard let s = l.set(level: .paragraph, at: r.location + 1) else { T.expect(false, "paragraph set"); return }
        T.expect(shown(l, s.id).hasPrefix("Writing is choosing"), "paragraph version shown")
        expectTextOutside(ctx, before: before, range: r, articleSlack: 0, "paragraph swap")
        expectOnlyReflow(ctx, l, before: g0, after: geometry(ctx, l, aboveP + belowP), above: aboveP, below: belowP,
                         dh: paragraphHeight(ctx, l, containing: "Writing is choosing") - h0, "paragraph swap")
        draw(ctx)
        T.expect(l.lastDrawn[s.id]?.margin == true && l.lastDrawn[s.id]?.squiggle == false, "paragraph: margin line, no squiggle")

        // hover the margin line + Up
        escape(ctx)
        hover(ctx, l, l.set(s.id)!, margin: true)
        T.expect(l.hoveredId == s.id, "hovering the margin line targets the paragraph")
        arrow(ctx, down: false)
        T.expect(shown(l, s.id) == para, "Up shows the original paragraph")
        T.undo(ctx)
        T.expect(shown(l, s.id).hasPrefix("Writing is choosing"), "undo: the new paragraph again")
        redo(ctx)
        T.expect(shown(l, s.id) == para, "redo: the original paragraph")
        T.undo(ctx)
        l.mouseMoved(.zero)
        ctx.c.textView.setSelectedRange(NSRange(location: l.set(s.id)!.from + 2, length: 0))
        p.refresh()
        draw(ctx)
        await T.pause(0.2)
        shot(ctx, "paragraph")
        AlternativesAttach.toggle(ctx.wc.root.area)
        await settle(ctx, l)
        let md = diskText(ctx)
        T.expect(md.contains("Writing is choosing what stays.") && !md.contains("deciding what to leave out"), "the .md holds the current paragraph only")
    }

    // MARK: reopen

    static func reopen(_ ctx: Ctx) async {
        guard let l = await layer(ctx) else { return }
        let sets = l.session.sets
        T.expect(sets.map(\.level.rawValue).sorted() == ["paragraph", "sentence", "word"], "reopen: word, sentence and paragraph sets are back (\(sets.map(\.level.rawValue)))")
        for s in sets {
            let v = s.variants.first { $0.id == s.currentId }!
            T.expect(l.text(of: v, in: s) == v.text, "reopen: \(s.level.rawValue) anchor holds its current text \"\(v.text.prefix(24))\"")
        }
        let word = sets.first { $0.level == .word }!
        T.expect(shown(l, word.id) == "eraser" && word.variants.count == 4, "reopen: word shows eraser, 4 versions")
        T.expect(sets.first { $0.level == .sentence }.map { shown(l, $0.id) } == "Nothing in it is precious.", "reopen: sentence current version kept")
        T.expect(sets.first { $0.level == .paragraph }.map { shown(l, $0.id).hasPrefix("Writing is choosing") } == true, "reopen: paragraph current version kept")
        draw(ctx)
        T.expect(l.lastDrawn.count == 3, "reopen: all three drawn (\(l.lastDrawn.count))")
        hover(ctx, l, word)
        T.expect(l.hoveredId == word.id && ctx.wc.window!.firstResponder === ctx.c.textView,
                 "reopen: hover on the word (hovered \(l.hoveredId ?? "nil"), segments \(l.segments(word).map(\.rect)), responder \(String(describing: ctx.wc.window!.firstResponder)))")
        arrow(ctx, down: true)
        T.expect(shown(l, word.id) == "pushpin", "reopen: swaps still work (\(shown(l, word.id)))")
        T.undo(ctx)
        T.expect(shown(l, word.id) == "eraser", "reopen: undo")
        await settle(ctx, l)
    }

    /// The panel is a plain list: the tabs and the bullets start on one column, the add line's
    /// text starts on the versions' text column, nothing comes closer than the side padding to
    /// the far edge, and the original is the first line.
    static func expectPlainList(_ p: AlternativesPanelView, _ what: String) {
        p.display()   // the tab rects come from drawing
        let pad = AlternativesPanelView.pad
        let tab0 = (p.tabRects.first?.1.minX ?? -100) + 6
        T.expect(abs(tab0 - pad) < 0.5 && abs(p.markX - 3 - pad) < 0.5,
                 String(format: "%@: tabs and bullets start on one column (tab %.1f, bullet %.1f, pad %.0f)", what, tab0, p.markX - 3, pad))
        T.expect(abs(p.fieldTextX - p.textX) < 0.5,
                 String(format: "%@: the add line's text starts on the versions' column (%.1f vs %.1f)", what, p.fieldTextX, p.textX))
        T.expect(p.input.frame.maxX <= p.bounds.width - pad + 0.5,
                 String(format: "%@: the add line keeps %.0f pt from the far edge (ends at %.1f of %.0f)", what, pad, p.input.frame.maxX, p.bounds.width))
        T.expect(p.input.layer?.backgroundColor == nil && !p.input.isBordered && !p.input.drawsBackground,
                 "\(what): the add line has no box (no fill, no border)")
        if p.rows.count > 1 { T.expect(p.rows.first?.original == true && p.rows.dropFirst().allSatisfy { !$0.original }, "\(what): the original is the first line, and only it (\(p.rows.map { $0.original }))") }
    }

    /// The self-test process has no app menu: a Format menu for the items to land in.
    static func installTestMenu() {
        if NSApp.mainMenu == nil { NSApp.mainMenu = NSMenu() }
        if NSApp.mainMenu?.items.contains(where: { $0.submenu?.title == L("Format") }) != true {
            let item = NSMenuItem(title: L("Format"), action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: L("Format"))
            NSApp.mainMenu?.addItem(item)
        }
        AlternativesAttach.installMenu()
    }
}
