import AppKit
import FloCore
import FloKit

/// Flowriter: ghost, alternatives and overflow together on one post, in the writing space's
/// document window (VM only; scripts/combined-vm-test.sh, Tests/fixtures/combined/pencil-case.md).
///   combined          add a version, ghost a sentence, stash a paragraph, edit around and inside
///                     them, swap, delete the ghost's whole sentence (undo brings the ghost back),
///                     undo everything and redo it, save; checks after every step that
///                     each anchor covers its text and moved once per change (the shared hook),
///                     then the sidecar on disk against the .md (offsets into the .md, frontmatter
///                     included), no AI in the menus, and a screenshot (merged-<appearance>.png)
///   restart-combined  a new process on the saved files: everything is back, one key still moves
///                     every anchor once, undo is exact
@MainActor
enum CombinedScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    typealias A = AlternativesScenarios

    static let word = "thumbtack", other = "pushpin"
    static let ghostText = "None of it matters much."
    static let stashed = "I once tried to carry a whole notebook, but it never left the drawer."
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        switch name {
        case "combined": await combined(ctx)
        case "restart-combined": await restart(ctx)
        default: return false
        }
        return true
    }

    struct Parts { let g: GhostLayer; let l: AlternativesLayer; let ov: OverflowController; let hook: SidecarEditHook }

    static func parts(_ ctx: Ctx) async -> Parts? {
        OverflowController.animations = false
        guard let l = await A.layer(ctx) else { return nil }
        guard let g = ctx.c.ghosts else { T.expect(false, "ghost layer attached"); return nil }
        guard let ov = ctx.pane.overflow else { T.expect(false, "overflow attached"); return nil }
        guard let hook = ctx.c.sidecarHook else { T.expect(false, "sidecar hook attached"); return nil }
        T.expect(hook.session === l.shared && hook.session === g.store.session && hook.session === SidecarSession.shared(for: ctx.file),
                 "ghosts, alternatives and overflow share one session and one hook")
        // menus with the features' key equivalents (the self test has no app menu)
        SelfTestScenarios.installTestMenu()
        A.installTestMenu()
        return Parts(g: g, l: l, ov: ov, hook: hook)
    }

    static func text(_ ctx: Ctx) -> NSString { ctx.c.state.doc.string as NSString }
    static func slice(_ ctx: Ctx, _ from: Int, _ to: Int) -> String {
        let t = text(ctx)
        guard from >= 0, to <= t.length, to >= from else { return "<out of range \(from)..<\(to)>" }
        return t.substring(with: NSRange(location: from, length: to - from))
    }
    static func caret(_ ctx: Ctx, at s: String, after: Bool = false, offset: Int = 0) {
        let r = text(ctx).range(of: s)
        let p = (after ? NSMaxRange(r) : r.location) + offset
        ctx.c.textView.setSelectedRange(NSRange(location: p, length: 0))
    }

    /// Every anchor covers its text, in the layers and in the shared session alike.
    static func check(_ ctx: Ctx, _ p: Parts, shows: String, ghost: String, _ what: String) {
        let s = p.hook.session
        var bad: [String] = []
        if s.sidecar.alternatives.count != 1 { bad.append("\(s.sidecar.alternatives.count) sets") }
        if let set = s.sidecar.alternatives.first {
            let live = slice(ctx, set.anchor.from, set.anchor.to)
            if live != shows { bad.append("set covers \"\(live)\"") }
            if p.l.session.sets.map(\.anchor) != s.sidecar.alternatives.map(\.anchor) { bad.append("layer sets differ from the session") }
        }
        if p.g.ranges.count != 1 || s.sidecar.ghosts.count != 1 { bad.append("\(p.g.ranges.count) ghost ranges, \(s.sidecar.ghosts.count) ghosts") }
        if let r = p.g.ranges.first {
            let live = slice(ctx, r.from, r.to)
            if live != ghost { bad.append("ghost covers \"\(live)\"") }
            if let a = s.sidecar.ghosts.first?.anchor, a.from != r.from || a.to != r.to { bad.append("ghost layer \(r.from)..<\(r.to) vs session \(a.from)..<\(a.to)") }
        }
        if s.anchoredText != ctx.c.state.doc.units { bad.append("session anchored to another text") }
        T.expect(bad.isEmpty, "\(what): anchors on their text \(bad.isEmpty ? "(\"\(shows)\", \"\(ghost.prefix(24))\")" : bad.joined(separator: "; "))")
    }

    /// Run `body` and check how many edits the hook applied (once per keystroke or command).
    static func follows(_ p: Parts, _ want: Int, _ what: String, _ body: () -> Void) {
        let n0 = p.hook.session.followCount
        body()
        let n = p.hook.session.followCount - n0
        T.expect(n == want, "\(what): the hook followed \(n) edit\(n == 1 ? "" : "s") (want \(want))")
    }

    static func combined(_ ctx: Ctx) async {
        guard let p = await parts(ctx) else { return }
        let original = text(ctx) as String
        UserDefaults.standard.removeObject(forKey: OverflowSidecarStore.openKey(ctx.file))
        p.ov.setOpen(false)
        T.expect(p.hook.session.sidecar.isEmpty, "a fresh post has an empty sidecar")
        T.expect(original.hasPrefix("---\ntitle:") && (T.diskBytes(ctx.file).flatMap { String(data: $0, encoding: .utf8) }) == original,
                 "the editor holds the whole .md, frontmatter included")

        // 1. the three features on one post
        let wr = text(ctx).range(of: word)
        guard let ids = p.l.addVersion(other, author: .me, level: .word, range: wr, show: false) else { T.expect(false, "version added"); return }
        let setId = ids.0
        _ = A.select(ctx, ghostText)
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(p.g.ranges.count == 1, "Option-G ghosted the sentence")
        _ = A.select(ctx, stashed)
        follows(p, 1, "stash (⌘K then s)") { _ = T.leader(ctx, "s") }
        T.expect(!text(ctx).contains(stashed) && p.ov.text == stashed && p.ov.isOpen, "the paragraph moved to the open overflow panel")
        check(ctx, p, shows: word, ghost: ghostText, "after add, ghost and stash")
        let d0 = text(ctx) as String

        // 2. edits around and inside them, through real keys
        caret(ctx, at: "I keep a pencil")
        follows(p, 7, "typing 7 keys before every anchor") { T.type(ctx, "Hello. ") }
        check(ctx, p, shows: word, ghost: ghostText, "typing before them")
        caret(ctx, at: "The last line stays where it is.", after: true)
        follows(p, 4, "typing 4 keys after every anchor") { T.type(ctx, " yes") }
        check(ctx, p, shows: word, ghost: ghostText, "typing after them")
        caret(ctx, at: "None of it", after: true)
        follows(p, 7, "typing 7 keys inside the ghost") { T.type(ctx, " really") }
        check(ctx, p, shows: word, ghost: "None of it really matters much.", "typing inside the ghost")
        caret(ctx, at: "some string.", after: true)
        follows(p, 1, "one key between the set and the ghost") { T.type(ctx, "!") }
        check(ctx, p, shows: word, ghost: "None of it really matters much.", "typing between them")
        caret(ctx, at: word, after: true)
        follows(p, 1, "one key right after the word") { T.type(ctx, "s") }
        check(ctx, p, shows: word, ghost: "None of it really matters much.", "typing at the set's end stays outside it")
        follows(p, 1, "backspace") { T.backspace(ctx) }

        // 3. swap with the pointer on the word and Down: the swap moves the anchors itself
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        guard let set = p.l.set(setId) else { T.expect(false, "set present"); return }
        A.hover(ctx, p.l, set)
        T.expect(p.l.hoveredId == setId, "the pointer is on the word")
        follows(p, 0, "Down swaps the version (anchored: not followed again)") { A.arrow(ctx, down: true) }
        check(ctx, p, shows: other, ghost: "None of it really matters much.", "after the swap")
        T.expect(text(ctx).contains("holds a pushpin, a ruler"), "the page shows the other version")
        caret(ctx, at: " really", after: true)
        follows(p, 7, "seven backspaces inside the ghost") { T.backspace(ctx, 7) }
        check(ctx, p, shows: other, ghost: ghostText, "deleting inside the ghost")

        // 3b. an edit that deletes the ghost's whole text drops the ghost; undo brings it back, redo drops it again
        let beforeCut = text(ctx) as String
        ctx.c.textView.setSelectedRange(text(ctx).range(of: " " + ghostText))
        follows(p, 1, "one backspace over the ghost's whole sentence") { T.backspace(ctx) }
        T.expect(p.g.ranges.isEmpty && p.hook.session.sidecar.ghosts.isEmpty,
                 "the ghost goes with its text (\(p.g.ranges.count) ranges, \(p.hook.session.sidecar.ghosts.count) in the session)")
        T.undo(ctx)
        T.expect((text(ctx) as String) == beforeCut, "undo puts the sentence back")
        check(ctx, p, shows: other, ghost: ghostText, "undo of the deletion brings the ghost back")
        if let a = GhostScenarioProbe.alpha(ctx.c, at: p.g.ranges.first.map { $0.from + 3 } ?? 0) {
            T.expect(a > 0 && a < 0.2, "the restored ghost is drawn faded (alpha \(a))")
        }
        A.redo(ctx)
        T.expect(!text(ctx).contains(ghostText) && p.g.ranges.isEmpty && p.hook.session.sidecar.ghosts.isEmpty, "redo deletes the sentence and its ghost again")
        T.undo(ctx)
        check(ctx, p, shows: other, ghost: ghostText, "a second undo brings the ghost back again")
        let d1 = text(ctx) as String

        // 4. undo everything back to the stash, checking every step; then the stash; then redo all
        var undos = 0
        var stepOK = true
        while (text(ctx) as String) != d0, undos < 60 {
            T.undo(ctx); undos += 1
            let s = p.hook.session.sidecar
            if let a = s.alternatives.first, ![word, other].contains(slice(ctx, a.anchor.from, a.anchor.to)) { stepOK = false }
            if let r = p.g.ranges.first, !slice(ctx, r.from, r.to).hasPrefix("None of it") { stepOK = false }
            if s.alternatives.count != 1 || p.g.ranges.count != 1 { stepOK = false }
        }
        T.expect((text(ctx) as String) == d0, "undo took the page back to the moment of the stash (\(undos) undos)")
        T.expect(stepOK, "after every undo step the set covers a version and the ghost its sentence")
        check(ctx, p, shows: word, ghost: ghostText, "after undoing the edits")
        T.undo(ctx)
        T.expect(text(ctx).contains(stashed) && p.ov.text.isEmpty, "one more undo brings the stashed paragraph back and empties the panel")
        check(ctx, p, shows: word, ghost: ghostText, "after undoing the stash")
        var redos = 0
        while (text(ctx) as String) != d1, redos < 70 { A.redo(ctx); redos += 1 }
        T.expect((text(ctx) as String) == d1, "redo brought every change back (\(redos) redos)")
        T.expect(p.ov.text == stashed, "the redone stash is in the panel again")
        check(ctx, p, shows: other, ghost: ghostText, "after redo")

        // 5. save and read the files back
        p.g.flushSave(); p.l.flush(); p.ov.setOpen(true); p.ov.flush()
        ctx.model.flushDirtyFiles()
        await T.pause(0.5)
        verifyDisk(ctx, p, shows: other, variants: [word, other])

        // 6. nothing AI in the menus or the page's context menu
        noAIMenus(ctx)

        // 7. the screenshot: a ghost, a version (hovered: its dots), the overflow panel open
        await shot(ctx, p, setId: setId, "merged-\(appearance).png")
    }

    static func verifyDisk(_ ctx: Ctx, _ p: Parts, shows: String, variants: [String]) {
        let md = (T.diskBytes(ctx.file).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
        T.expect(md == (text(ctx) as String), "the .md on disk is exactly the page (\(md.utf16.count) units)")
        for leak in ["flowriter", "\"variants\"", "ghosted", stashed, "schemaVersion"] {
            T.expect(!md.contains(leak), "the .md holds no sidecar data (\"\(leak.prefix(20))\")")
        }
        let url = SidecarStore.url(for: URL(fileURLWithPath: ctx.file))
        guard let data = FileManager.default.contents(atPath: url.path), let decoded = try? SidecarCodec.decode(data) else {
            T.expect(false, "sidecar \(url.lastPathComponent) readable"); return
        }
        let sc = decoded.sidecar
        let mdUnits = Array(md.utf16)
        func mdSlice(_ a: TextAnchor) -> String {
            guard a.from >= 0, a.to <= mdUnits.count, a.to > a.from else { return "<\(a.from)..<\(a.to)>" }
            return String(utf16CodeUnits: Array(mdUnits[a.from..<a.to]), count: a.length)
        }
        let fm = (md as NSString).range(of: "---\n\n").location + 5
        T.expect(decoded.documentSHA256 == SidecarStore.sha256(md), "documentSHA256 is the hash of the .md on disk")
        if let set = sc.alternatives.first, sc.alternatives.count == 1 {
            T.expect(mdSlice(set.anchor) == shows && set.anchor.quote == shows, "set offsets point into the .md at \"\(mdSlice(set.anchor))\" (quote \"\(set.anchor.quote)\")")
            T.expect(set.anchor.from > fm, "offsets count the frontmatter (set at \(set.anchor.from), body starts at \(fm))")
            T.expect(Set(set.variants.map(\.text)) == Set(variants) && set.current?.text == shows, "variants \(set.variants.map(\.text)), current \"\(set.current?.text ?? "")\"")
        } else { T.expect(false, "one set in the file (\(sc.alternatives.count))") }
        if let g = sc.ghosts.first, sc.ghosts.count == 1 {
            T.expect(mdSlice(g.anchor) == ghostText && g.anchor.quote == ghostText, "ghost offsets point into the .md at \"\(mdSlice(g.anchor))\"")
            T.expect(g.author == .me && g.state == .ghosted, "ghost by me, ghosted")
        } else { T.expect(false, "one ghost in the file (\(sc.ghosts.count))") }
        T.expect(sc.sortedOverflow.map(\.text) == [stashed], "overflow holds the stashed paragraph (\(sc.overflow.count) items)")
        T.expect(sc.unresolved.isEmpty, "nothing unresolved")
    }

    static func noAIMenus(_ ctx: Ctx) {
        let menu = MainMenu.build(target: MenuRouter())
        FlowriterSpace.installMenus(in: menu, focused: { nil })
        OverflowMenu.installMenu(in: menu)
        let saved = NSApp.mainMenu
        NSApp.mainMenu = menu
        AlternativesAttach.installMenu()
        NSApp.mainMenu = saved
        func titles(_ m: NSMenu) -> [String] { m.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
        let sel = A.select(ctx, "pencil in my bag")
        let context = SelfTestScenarios.rightClickMenu(ctx, at: NSRange(location: sel.location + 3, length: 0)).map(titles) ?? []
        let all = titles(menu) + context
        let words = ["AI", "Lab", "Suggest", "Generate", "Rewrite", "Assistant", "Writing Checks", "Check Feedback", "Trim", "Proposed"]
        let hits = all.filter { t in words.contains { w in t.range(of: "\\b\(w)\\b", options: .regularExpression) != nil } }
        T.expect(hits.isEmpty, "no AI items in \(all.count) menu items (app menus and the page's right-click menu): \(hits)")
        for item in [AlternativesAttach.addTitle, AlternativesAttach.toggleTitle, OverflowMenu.stashTitle] {
            T.expect(all.contains(item), "the merged features' item \"\(item)\" is there")
        }
        T.expect(all.contains(OverflowMenu.toggleTitles.0) || all.contains(OverflowMenu.toggleTitles.1), "the Overflow menu has Show / Hide Overflow")
        T.expect(context.contains(OverflowMenu.stashTitle) && context.contains("Ghost it"), "the right-click menu on a selection has Ghost it and Stash in Overflow (\(context.prefix(6)))")
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    static func shot(_ ctx: Ctx, _ p: Parts, setId: String, _ name: String) async {
        p.ov.setOpen(true)
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        caret(ctx, at: "The last line")
        ctx.c.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        await T.pause(0.4)
        if let s = p.l.set(setId) { A.hover(ctx, p.l, s) }
        A.draw(ctx)
        await T.pause(0.3)
        if let right = p.ov.columnRight {
            T.expect(p.ov.panel.frame.minX >= right + 12, "the open panel leaves the page column clear (panel at \(Int(p.ov.panel.frame.minX)), column ends at \(Int(right)), \(Int(p.ov.panel.frame.width)) pt wide)")
        }
        T.screenshot(ctx, name)
    }

    static func restart(_ ctx: Ctx) async {
        guard let p = await parts(ctx) else { return }
        let md0 = T.diskBytes(ctx.file)
        await T.pause(0.3)
        T.expect(p.ov.text == stashed && p.ov.isOpen, "overflow panel is back, open, with the paragraph")
        check(ctx, p, shows: other, ghost: ghostText, "after restart")
        if let a = GhostScenarioProbe.alpha(ctx.c, at: p.g.ranges.first.map { $0.from + 3 } ?? 0) {
            T.expect(a > 0 && a < 0.2, "the ghost is drawn faded after restart (alpha \(a))")
        }
        T.expect(p.l.session.sets.first?.variants.count == 2, "both versions are back")
        T.expect(T.diskBytes(ctx.file) == md0, "opening did not write the .md")
        let before = text(ctx) as String
        caret(ctx, at: "I keep a pencil")
        follows(p, 1, "one key after restart") { T.type(ctx, "Z") }
        check(ctx, p, shows: other, ghost: ghostText, "typing after restart")
        T.undo(ctx)
        T.expect((text(ctx) as String) == before, "undo is exact after restart")
        check(ctx, p, shows: other, ghost: ghostText, "undo after restart")
        // the swap back and its undo after restart
        guard let set = p.l.session.sets.first else { return }
        A.hover(ctx, p.l, set)
        A.arrow(ctx, down: true)
        check(ctx, p, shows: word, ghost: ghostText, "swap after restart")
        T.undo(ctx)
        check(ctx, p, shows: other, ghost: ghostText, "undo of the swap after restart")
        T.expect((text(ctx) as String) == before, "the page is as it was opened")
        p.g.flushSave(); p.l.flush(); p.ov.flush()
        ctx.model.flushDirtyFiles()
        await T.pause(0.4)
        verifyDisk(ctx, p, shows: other, variants: [word, other])
        await shot(ctx, p, setId: set.id, "merged-restarted-\(appearance).png")
    }
}

/// The ghost scenario's faded-colour probe, for the combined scenarios.
@MainActor
enum GhostScenarioProbe {
    static func alpha(_ c: EditorController, at pos: Int) -> CGFloat? { SelfTestScenarios.fadedColorAlpha(c, at: pos) }
}
