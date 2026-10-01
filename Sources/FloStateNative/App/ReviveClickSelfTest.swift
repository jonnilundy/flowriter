import AppKit
import FloCore
import FloKit

/// Flowriter: Revive the way a writer reaches for it (`--ui-selftest revive-click <post> <out>`,
/// VM only; scripts/writing-ui-vm-test.sh on Tests/fixtures/combined/pencil-case.md). Every pick is a
/// real right click sent to the window with the item chosen by keyboard while the menu tracks.
///   right click at the start, middle and end of a ghost, no selection: Revive revives the whole
///   ghost, the sidecar on disk drops it, Cmd-Z brings it back, Cmd-Shift-Z revives it again
///   the same on a ghost that is a lazy list continuation line (the shape of the bug report)
///   Option-G with the caret at the start, middle and end of a ghost: the whole ghost
///   a selection inside a ghost, and one partly over a ghost: Revive revives the whole ghost
///   a selection over two ghosts: Revive revives both; one Cmd-Z brings both back
@MainActor
enum ReviveClickScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        guard name == "revive-click" else { return false }
        await reviveClick(ctx)
        return true
    }

    static func text(_ ctx: Ctx) -> NSString { ctx.c.state.doc.string as NSString }
    static func range(_ ctx: Ctx, _ s: String) -> NSRange { text(ctx).range(of: s) }

    /// The author ghosts the sidecar file on disk holds, as quotes.
    static func diskGhosts(_ ctx: Ctx) -> [String]? {
        guard let g = ctx.c.ghosts else { return nil }
        g.flushSave()
        let url = SidecarStore.url(for: URL(fileURLWithPath: ctx.file))
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ghosts = json["ghosts"] as? [[String: Any]] else { return [] }
        return ghosts.compactMap { ($0["anchor"] as? [String: Any])?["quote"] as? String }.sorted()
    }

    static func reviveClick(_ ctx: Ctx) async {
        let c = ctx.c
        await PanelsScenario.resize(ctx, width: 1280)
        guard let g = c.ghosts else { T.expect(false, "ghost layer attached"); return }
        ctx.wc.window!.makeFirstResponder(c.textView)
        // the shape of the report: a ghost on a line that continues a nested list item
        let tail = "\n\n- dfk\n  - sdlkf\nfun in the sun  that"
        let end = c.state.doc.length
        _ = c.run { t in t.dispatch(TransactionSpec(changes: [Change(from: end, insert: tail)])); return true }
        await T.pause(0.3)

        func ghostText() -> [String] { g.ranges.map { text(ctx).substring(with: NSRange(location: $0.from, length: $0.length)) } }
        func ghost(_ s: String) -> NSRange {
            let r = range(ctx, s)
            _ = g.ghost(from: r.location, to: NSMaxRange(r))
            return r
        }
        func caretAway() { c.textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        func describe(_ m: [String]?) -> String { m.map { "\($0)" } ?? "no menu" }

        // 1. right click at the start, middle and end of a ghost with no selection
        for sentence in ["Some days it is the only tool I need.", "fun in the sun"] {
            let n = (sentence as NSString).length
            for (label, offset) in [("start", 0), ("middle", n / 2), ("end", n - 1)] {
                g.set([])
                let r = ghost(sentence)
                caretAway()
                await T.pause(0.1)
                let docBefore = text(ctx) as String
                T.expect(diskGhosts(ctx) == [sentence], "\"\(sentence)\" ghosted and on disk (\(diskGhosts(ctx) ?? []))")
                let res = await WritingMenuScenarios.realRightClick(ctx, at: r, offset: offset, shot: nil, choose: WritingMenu.reviveTitle)
                T.expect(res.menu?.first == WritingMenu.reviveTitle, "\(label) of \"\(sentence)\": right click offers Revive (\(describe(res.menu)))")
                T.expect(g.ranges.isEmpty, "\(label) of \"\(sentence)\": Revive revives the whole ghost (left \(ghostText()))")
                T.expect((text(ctx) as String) == docBefore, "\(label) of \"\(sentence)\": the text is unchanged")
                T.expect(diskGhosts(ctx) == [], "\(label) of \"\(sentence)\": the sidecar on disk has no ghost (\(diskGhosts(ctx) ?? []))")
                if label == "middle" {
                    T.undo(ctx)
                    T.expect(ghostText() == [sentence], "Cmd-Z brings the ghost back (\(ghostText()))")
                    T.expect(diskGhosts(ctx) == [sentence], "and the sidecar on disk has it again (\(diskGhosts(ctx) ?? []))")
                    T.key(ctx, "z", code: 6, mods: [.command, .shift])
                    T.expect(g.ranges.isEmpty, "Cmd-Shift-Z revives it again (\(ghostText()))")
                    T.expect(diskGhosts(ctx) == [], "and the sidecar on disk drops it again (\(diskGhosts(ctx) ?? []))")
                }
            }
        }

        // 2. Option-G with the caret inside a ghost, no selection
        let sentence = "None of it matters much."
        let n = (sentence as NSString).length
        for (label, offset) in [("start", 0), ("middle", n / 2), ("end", n)] {
            g.set([])
            let r = ghost(sentence)
            c.textView.setSelectedRange(NSRange(location: r.location + offset, length: 0))
            T.appKey(ctx, "g", code: 5, mods: [.option])
            T.expect(g.ranges.isEmpty, "Option-G, caret at the \(label) of the ghost: the whole ghost revived (left \(ghostText()))")
        }
        T.undo(ctx)
        T.expect(ghostText() == [sentence], "Cmd-Z after Option-G brings the ghost back (\(ghostText()))")

        // 3. a selection inside a ghost: Option-G and Revive revive the whole ghost
        g.set([])
        var r = ghost(sentence)
        c.textView.setSelectedRange(NSRange(location: r.location + 3, length: 6))
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(g.ranges.isEmpty, "Option-G on a word inside a ghost revives the whole ghost (left \(ghostText()))")
        g.set([])
        r = ghost(sentence)
        c.textView.setSelectedRange(NSRange(location: r.location + 3, length: 6))
        var res = await WritingMenuScenarios.realRightClick(ctx, at: r, offset: 5, shot: nil, choose: WritingMenu.reviveTitle)
        T.expect(res.menu?.first == WritingMenu.reviveTitle, "a word selected inside a ghost: right click offers Revive (\(describe(res.menu)))")
        T.expect(g.ranges.isEmpty, "Revive with a word selected inside the ghost revives the whole ghost (left \(ghostText()))")

        // 3b. the ghost selected with the white space after it (a drag a little past the end, a
        // line selected with its line break): that is still ghost text, so it revives; it used to
        // ghost the space too, which looks like nothing happened
        g.set([])
        r = ghost("fun in the sun")
        c.textView.setSelectedRange(NSRange(location: r.location, length: r.length + 1))
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(g.ranges.isEmpty, "Option-G on the ghost and the space after it revives it (left \(ghostText().map { $0.debugDescription }))")
        g.set([])
        r = ghost("fun in the sun")
        c.textView.setSelectedRange(NSRange(location: r.location, length: r.length + 2))
        res = await WritingMenuScenarios.realRightClick(ctx, at: r, offset: r.length, shot: nil, choose: WritingMenu.reviveTitle)
        T.expect(res.menu?.first == WritingMenu.reviveTitle, "right click on the space after a selected ghost offers Revive (\(describe(res.menu)))")
        T.expect(g.ranges.isEmpty, "and Revive revives it (left \(ghostText().map { $0.debugDescription }))")
        g.set([])
        r = ghost(sentence)
        c.textView.setSelectedRange(NSRange(location: r.location, length: r.length + 1))   // with its line break
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(g.ranges.isEmpty, "Option-G on a ghost line with its line break revives it (left \(ghostText().map { $0.debugDescription }))")

        // 4. a selection partly over a ghost (from its middle into the plain text after it)
        g.set([])
        r = ghost(sentence)
        let after = range(ctx, "I once tried")
        c.textView.setSelectedRange(NSRange(location: r.location + 8, length: NSMaxRange(after) - (r.location + 8)))
        res = await WritingMenuScenarios.realRightClick(ctx, at: r, offset: 12, shot: nil, choose: WritingMenu.reviveTitle)
        T.expect(res.menu?.first == WritingMenu.reviveTitle, "a selection partly over a ghost: right click on the ghost offers Revive (\(describe(res.menu)))")
        T.expect(g.ranges.isEmpty, "Revive revives the whole ghost the selection partly covers (left \(ghostText()))")
        T.expect(diskGhosts(ctx) == [], "the sidecar on disk has no ghost (\(diskGhosts(ctx) ?? []))")

        // 5. a selection over two ghosts: Revive revives both, one Cmd-Z brings both back
        g.set([])
        let first = "Some days it is the only tool I need."
        let r1 = ghost(first)
        let r2 = ghost(sentence)
        c.textView.setSelectedRange(NSRange(location: r1.location + 5, length: (r2.location + 6) - (r1.location + 5)))
        res = await WritingMenuScenarios.realRightClick(ctx, at: r1, offset: 10, shot: nil, choose: WritingMenu.reviveTitle)
        T.expect(res.menu?.first == WritingMenu.reviveTitle, "a selection over two ghosts: right click on the first offers Revive (\(describe(res.menu)))")
        T.expect(g.ranges.isEmpty, "Revive revives both ghosts the selection touches (left \(ghostText()))")
        T.expect(diskGhosts(ctx) == [], "the sidecar on disk has no ghost (\(diskGhosts(ctx) ?? []))")
        T.undo(ctx)
        T.expect(ghostText() == [first, sentence], "one Cmd-Z brings both ghosts back (\(ghostText()))")
        T.expect(diskGhosts(ctx) == [first, sentence].sorted(), "and the sidecar on disk has both (\(diskGhosts(ctx) ?? []))")
        T.key(ctx, "z", code: 6, mods: [.command, .shift])
        T.expect(g.ranges.isEmpty, "Cmd-Shift-Z revives both again (\(ghostText()))")
        // the same with the shortcut: a selection from inside one ghost to inside the next
        T.undo(ctx)
        c.textView.setSelectedRange(NSRange(location: r1.location + 5, length: (r2.location + 6) - (r1.location + 5)))
        T.appKey(ctx, "g", code: 5, mods: [.option])
        T.expect(ghostText().count == 1 && ghostText()[0].hasPrefix("Some days") && ghostText()[0].hasSuffix("matters much."),
                 "Option-G on a selection with plain text between two ghosts ghosts it all, as one ghost (\(ghostText()))")
        caretAway()
        await T.pause(0.2)
    }
}
