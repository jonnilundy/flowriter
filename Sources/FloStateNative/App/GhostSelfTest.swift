import AppKit
import FloCore
import FloKit

/// Flowriter: Ghost scenarios for `--ui-selftest` (VM only).
///   ghost          menu, shortcut, edits around and inside a ghost, undo and redo, layout check, word count,
///                  light or dark screenshot (FLO_TEST_APPEARANCE), leaves one ghost saved
///   restart-ghost  run right after `ghost`: the saved ghost is back after a fresh open
extension SelfTestScenarios {
    /// A short sentence of its own paragraph in Tests/fixtures/integrity/workshop.md.
    static let anchor = "The reason, my reason, is what I hope to set down here."

    static func runGhostScenario(_ name: String, _ ctx: SelfTestRunner.Context) async -> Bool {
        switch name {
        case "ghost": await ghostScenario(ctx)
        case "restart-ghost": await ghostRestart(ctx)
        default: return false
        }
        return true
    }

    /// Origin and size of every layout fragment and every line fragment in it.
    static func layoutSnapshot(_ c: EditorController) -> [String] {
        guard let tlm = c.textView.textLayoutManager else { return [] }
        var out: [String] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { f in
            let fr = f.layoutFragmentFrame
            var s = String(format: "frag %.2f,%.2f %.2fx%.2f", fr.minX, fr.minY, fr.width, fr.height)
            for l in f.textLineFragments {
                let b = l.typographicBounds, p = l.glyphOrigin
                s += String(format: " | line %.2f,%.2f %.2fx%.2f @%.2f,%.2f", b.minX, b.minY, b.width, b.height, p.x, p.y)
            }
            out.append(s)
            return true
        }
        return out
    }

    /// Window point over the start of a doc range, for a real right click.
    static func windowPoint(_ ctx: SelfTestRunner.Context, _ r: NSRange) -> NSPoint {
        let tv = ctx.c.textView
        let screen = tv.firstRect(forCharacterRange: NSRange(location: r.location, length: 1), actualRange: nil)
        let win = ctx.wc.window!.convertFromScreen(screen)
        return NSPoint(x: win.midX, y: win.midY)
    }

    static func rightClickMenu(_ ctx: SelfTestRunner.Context, at r: NSRange) -> NSMenu? {
        let w = ctx.wc.window!
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: windowPoint(ctx, r), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        return ctx.c.textView.menu(for: e)
    }

    /// Does TextKit hold a faded colour for the character at `pos`?
    static func fadedColorAlpha(_ c: EditorController, at pos: Int) -> CGFloat? {
        guard let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: pos) else { return nil }
        var alpha: CGFloat?
        tlm.enumerateRenderingAttributes(from: loc, reverse: false) { _, attrs, r in
            if let col = attrs[.foregroundColor] as? NSColor { alpha = col.usingColorSpace(.sRGB)?.alphaComponent }
            return false
        }
        return alpha
    }

    static func ghostScenario(_ ctx: SelfTestRunner.Context) async {
        let c = ctx.c
        guard let g = c.ghosts else { T.expect(false, "ghost layer attached"); return }
        T.expect(g.ranges.isEmpty, "no ghosts in a fresh post")
        let anchor = Self.anchor
        let nsAnchor = anchor as NSString
        func slice(_ r: GhostRange) -> String { (c.state.doc.string as NSString).substring(with: NSRange(location: r.from, length: r.length)) }
        func ghostText() -> [String] { g.ranges.map(slice) }
        func select(_ s: String) -> NSRange? {
            let r = text(ctx).range(of: s)
            guard r.location != NSNotFound else { return nil }
            c.textView.setSelectedRange(r)
            return r
        }
        await T.pause(0.5)

        // 1. layout check: ghost and revive through the real context menu move nothing
        let before = layoutSnapshot(c)
        T.expect(!before.isEmpty, "layout snapshot has \(before.count) fragments")
        let words0 = g.wordCount()
        guard let ar = select(anchor) else { T.expect(false, "anchor sentence found"); return }
        let menu = rightClickMenu(ctx, at: NSRange(location: ar.location + 4, length: 0))
        T.expect(menu?.items.first?.title == "Ghost it", "right click on a selection offers Ghost it (\(menu?.items.first?.title ?? "no menu"))")
        if let m = menu, m.numberOfItems > 0 { m.performActionForItem(at: 0) }
        await T.pause(0.3)
        T.expect(ghostText() == [anchor], "menu Ghost it ghosts the selection (\(ghostText()))")
        T.expect(text(ctx).substring(with: ar) == anchor, "ghosting left the text as it was")
        let a = fadedColorAlpha(c, at: ar.location + 5) ?? -1
        T.expect(a > 0 && a < 0.2, "TextKit holds a faded colour for ghost text (alpha \(a))")
        T.expect((fadedColorAlpha(c, at: ar.location + nsAnchor.length + 3) ?? 1) > 0.5 || fadedColorAlpha(c, at: ar.location + nsAnchor.length + 3) == nil,
                 "text after the ghost is not faded")
        let during = layoutSnapshot(c)
        T.expect(during == before, "ghosting changed 0 of \(before.count) fragments (origin or size)")
        let words1 = g.wordCount()
        let gone = GhostMath.wordCount(anchor, ghosts: [])
        T.expect(words0 - words1 == gone, "word count drops by the ghost's \(gone) words (\(words0) to \(words1))")
        let menu2 = rightClickMenu(ctx, at: NSRange(location: ar.location + 4, length: 0))
        T.expect(menu2?.items.first?.title == "Revive", "right click on ghost text offers Revive (\(menu2?.items.first?.title ?? "no menu"))")
        if let m = menu2, m.numberOfItems > 0 { m.performActionForItem(at: 0) }
        await T.pause(0.3)
        T.expect(g.ranges.isEmpty, "menu Revive brings the text back")
        T.expect((fadedColorAlpha(c, at: ar.location + 5) ?? 1) > 0.5 || fadedColorAlpha(c, at: ar.location + 5) == nil, "revived text is not faded")
        let after = layoutSnapshot(c)
        T.expect(after == before, "reviving changed 0 of \(before.count) fragments (origin or size)")
        T.expect(g.wordCount() == words0, "word count is back to \(words0)")

        // 2. the shortcut (Option-G) toggles
        ctx.wc.window!.makeFirstResponder(c.textView)
        await T.pause(0.3)
        _ = select(anchor)
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(ghostText() == [anchor], "Option-G ghosts the selection (\(ghostText()))")
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(g.ranges.isEmpty, "Option-G again revives it")
        _ = select(anchor)
        T.appKey(ctx, "g", code: 5, mods: [.option])
        let docAtGhost = text(ctx) as String

        // 3. edits around the ghost: it follows
        func ghostIs(_ s: String, _ what: String) { T.expect(ghostText() == [s], "\(what): ghost is \(ghostText().first.map { "\"\($0.prefix(60))\"" } ?? "gone")") }
        c.textView.setSelectedRange(NSRange(location: text(ctx).range(of: "Building this workshop").location, length: 0))
        T.type(ctx, "AB")
        ghostIs(anchor, "typing before the ghost")
        let end = c.state.doc.length
        c.textView.setSelectedRange(NSRange(location: end, length: 0))
        T.type(ctx, "CD")
        ghostIs(anchor, "typing after the ghost")
        // right after the ghost's last letter: the new text stays out
        let ghostEnd = g.ranges[0].to
        c.textView.setSelectedRange(NSRange(location: ghostEnd, length: 0))
        T.type(ctx, "Q")
        ghostIs(anchor, "typing at the ghost's end stays outside it")
        T.backspace(ctx)
        // inside: the new text joins the ghost
        let mid = g.ranges[0].from + 10
        c.textView.setSelectedRange(NSRange(location: mid, length: 0))
        T.type(ctx, "XY")
        let inside = (anchor as NSString).replacingCharacters(in: NSRange(location: 10, length: 0), with: "XY")
        ghostIs(inside, "typing inside the ghost joins it")
        T.backspace(ctx, 2)
        ghostIs(anchor, "deleting what was typed inside")
        // undo all the typing (the ghost stays), then Ghost it itself, then redo everything
        let editedDoc = text(ctx) as String
        var undos = 0
        while (text(ctx) as String) != docAtGhost, undos < 40 { T.undo(ctx); undos += 1; if ghostText().isEmpty { break } }
        T.expect((text(ctx) as String) == docAtGhost, "undo took the text back to the moment of Ghost it (\(undos) undos)")
        ghostIs(anchor, "after undoing all the typing")
        T.undo(ctx)
        T.expect(g.ranges.isEmpty, "one more Cmd-Z undoes Ghost it")
        for _ in 0..<(undos + 1) { T.key(ctx, "z", code: 6, mods: [.command, .shift]) }
        T.expect((text(ctx) as String) == editedDoc, "redo brought the typing back")
        ghostIs(anchor, "after redoing Ghost it and the typing")
        T.expect(text(ctx).substring(with: NSRange(location: g.ranges[0].from, length: g.ranges[0].length)) == anchor, "ghost range still spans exactly the sentence")
        T.expect(layoutSnapshot(c).count == before.count, "same fragment count after the edits")

        // 3b. a ghost in the middle of a paragraph: edits in the same paragraph, before and after it
        let mid1 = "but never stopped to ask myself"
        let saved = g.ranges
        g.set([])
        _ = select(mid1)
        g.toggle()
        ghostIs(mid1, "a ghost in the middle of a paragraph")
        c.textView.setSelectedRange(NSRange(location: text(ctx).range(of: "I sanded, glued").location, length: 0))
        T.type(ctx, "So ")
        ghostIs(mid1, "typing earlier in the same paragraph")
        c.textView.setSelectedRange(NSRange(location: text(ctx).range(of: "**why I keep at it**").location, length: 0))
        T.type(ctx, "really ")
        ghostIs(mid1, "typing later in the same paragraph")
        T.backspace(ctx, 7)
        T.undo(ctx); T.undo(ctx)
        ghostIs(mid1, "after undo in the same paragraph")
        g.set(saved)

        // 3c. Ghost it and Revive are in the undo stack
        let savedRanges = g.ranges
        g.set([])
        _ = select(mid1)
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(ghostText() == [mid1], "ghosted for the undo test")
        T.undo(ctx)
        T.expect(g.ranges.isEmpty, "Cmd-Z undoes Ghost it")
        T.key(ctx, "z", code: 6, mods: [.command, .shift])
        T.expect(ghostText() == [mid1], "Cmd-Shift-Z redoes it")
        let docBefore = text(ctx) as String
        c.textView.setSelectedRange(NSRange(location: c.state.doc.length, length: 0))
        T.type(ctx, "Z")
        T.undo(ctx)   // undoes the typing first
        T.expect(ghostText() == [mid1] && (text(ctx) as String) == docBefore, "Cmd-Z after typing undoes the typing, the ghost stays")
        T.undo(ctx)   // now the ghost
        T.expect(g.ranges.isEmpty, "the next Cmd-Z undoes Ghost it")
        T.key(ctx, "z", code: 6, mods: [.command, .shift])
        _ = select(mid1)
        g.revive(from: g.ranges[0].from, to: g.ranges[0].to)
        T.expect(g.ranges.isEmpty, "Revive")
        T.undo(ctx)
        T.expect(ghostText() == [mid1], "Cmd-Z undoes Revive")
        g.set(savedRanges)

        // 4. the screenshot: a ghosted sentence and a proposed one in the body
        g.set(g.ranges.filter { slice($0) == anchor })
        let cl = text(ctx).range(of: "Why do I fuss over the grain of every board?")
        let hb = text(ctx).range(of: "A quick answer is")
        var set = g.ranges
        if cl.location != NSNotFound { set.append(GhostRange(from: cl.location, to: NSMaxRange(cl), origin: .author)) }
        if hb.location != NSNotFound {
            let para = text(ctx).paragraphRange(for: hb)
            set.append(GhostRange(from: para.location, to: NSMaxRange(para) - 1, origin: .proposed))
        }
        g.set(set)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        c.textView.scrollRangeToVisible(NSRange(location: cl.location + 900, length: 0))
        await T.pause(0.3)
        c.textView.scrollRangeToVisible(NSRange(location: max(0, cl.location - 200), length: 0))
        await T.pause(0.5)
        let hd = text(ctx).range(of: "Why Not\n").location
        T.log("probe heading alpha \(String(describing: fadedColorAlpha(c, at: hd + 2))) proposed alpha \(String(describing: fadedColorAlpha(c, at: hb.location + 5)))")
        T.expect(fadedColorAlpha(c, at: hd + 2) == nil, "the heading between ghosts is not faded")
        let mode = ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light"
        T.screenshot(ctx, "ghost-\(mode).png")

        // 5. leave one author ghost saved for restart-ghost
        g.set(g.ranges.filter { slice($0) == anchor && $0.origin == .author })
        T.expect(g.ranges.count == 1, "one author ghost left to save")
        await T.pause(0.8)
        let root = (ctx.file as NSString).deletingLastPathComponent
        let files = (FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".json") }
        T.expect(files.contains { (try? String(contentsOfFile: root + "/" + $0, encoding: .utf8))?.contains("ghost") == true }, "sidecar with the ghost written (\(files))")
        T.expect(T.diskBytes(ctx.file).flatMap { String(data: $0, encoding: .utf8) }?.contains("ghost") != true, "the .md holds no ghost data")
        ctx.model.flushDirtyFiles()
    }

    static func ghostRestart(_ ctx: SelfTestRunner.Context) async {
        guard let g = ctx.c.ghosts else { T.expect(false, "ghost layer attached"); return }
        await T.pause(0.4)
        let t = text(ctx)
        T.expect(g.ranges.count == 1, "one ghost is back after reopening (\(g.ranges.count))")
        if let r = g.ranges.first {
            T.expect(t.substring(with: NSRange(location: r.from, length: r.length)) == anchor, "it covers the same sentence")
            let a = fadedColorAlpha(ctx.c, at: r.from + 5) ?? -1
            T.expect(a > 0 && a < 0.2, "and is drawn faded (alpha \(a))")
        }
    }
}
