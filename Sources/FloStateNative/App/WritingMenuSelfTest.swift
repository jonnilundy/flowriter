import AppKit
import FloCore
import FloKit

/// Flowriter: the trimmed right-click menu (`--ui-selftest writing-menu <post> <out>`, VM only;
/// scripts/writing-ui-vm-test.sh on Tests/fixtures/combined/pencil-case.md), in the writing space's
/// document window: the menu's titles and shortcuts for a selection, ghost text, text with versions,
/// a misspelled word (guesses on top, Ignore / Learn), a misspelled word in a selection, and plain
/// text (no menu); each action works; a real right click (window event, the menu tracked and
/// dismissed) pops the same menu or none; screenshot hints-menu-<appearance>.png.
@MainActor
enum WritingMenuScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        guard name == "writing-menu" else { return false }
        await writingMenu(ctx)
        return true
    }

    /// No AI: every text view reports Writing Tools off, and neither the main menu nor a right-click menu holds a Writing Tools item.
    static func expectNoWritingTools(_ ctx: Ctx, rightClickMenus: [NSMenu?] = []) {
        func behaviorOff(_ tv: NSTextView) -> Bool {
            if #available(macOS 15.0, *) { return tv.writingToolsBehavior == .none && tv.allowedWritingToolsResultOptions.isEmpty }
            return true
        }
        T.expect(behaviorOff(ctx.c.textView), "page: Writing Tools off")
        if let ov = ctx.pane.overflow { T.expect(behaviorOff(ov.panel.textView), "overflow panel: Writing Tools off") }
        if let w = ctx.c.textView.window {
            NoWritingTools.configureFieldEditor(of: w)
            if let fe = w.fieldEditor(true, for: nil) as? NSTextView { T.expect(behaviorOff(fe), "field editor (find, rename, add-version, settings): Writing Tools off") }
        }
        let main = NSApp.mainMenu.map { NoWritingTools.items(in: $0).map(\.title) } ?? []
        T.expect(main.isEmpty, "main menu: no Writing Tools item \(main)")
        let edit = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Edit" })?.submenu
        if let edit = edit { edit.delegate?.menuNeedsUpdate?(edit) }
        let editItems = edit.map { NoWritingTools.items(in: $0).map(\.title) } ?? []
        T.expect(editItems.isEmpty, "Edit menu: no Writing Tools item \(editItems)")
        for m in rightClickMenus {
            let found = m.map { NoWritingTools.items(in: $0).map(\.title) } ?? []
            T.expect(found.isEmpty, "right-click menu: no Writing Tools item \(found)")
        }
    }

    /// The overflow panel's own right-click menu, as a click on its text would build it.
    static func overflowMenu(_ ctx: Ctx) -> NSMenu? {
        guard let tv = ctx.pane.overflow?.panel.textView else { return nil }
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: tv.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        return e.flatMap { tv.menu(for: $0) }
    }

    static func text(_ ctx: Ctx) -> NSString { ctx.c.state.doc.string as NSString }
    static func range(_ ctx: Ctx, _ s: String) -> NSRange { text(ctx).range(of: s) }
    static func caretAtStart(_ ctx: Ctx) { ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0)) }
    static func titles(_ m: NSMenu?) -> [String] { m?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? [] }
    static func menu(_ ctx: Ctx, on s: String, offset: Int = 2) -> NSMenu? {
        let r = range(ctx, s)
        return SelfTestScenarios.rightClickMenu(ctx, at: NSRange(location: r.location + offset, length: 0))
    }
    static func perform(_ m: NSMenu?, _ title: String) {
        guard let m = m, let i = m.items.firstIndex(where: { $0.title == title }) else { T.expect(false, "menu has \"\(title)\""); return }
        m.performActionForItem(at: i)
    }
    static func insert(_ ctx: Ctx, _ s: String, after anchor: String) {
        let at = NSMaxRange(range(ctx, anchor))
        _ = ctx.c.run { t in t.dispatch(TransactionSpec(changes: [Change(from: at, insert: s)])); return true }
    }

    static let upstreamTitles = ["Cut", "Copy", "Paste", "Paste as plain text", "Format", "Paragraph", "Insert", "Select all", "Select All",
                                 "Open link", "Copy link", "Spelling and Grammar", "Substitutions", "Transformations", "Speech", "Services"]

    static func shortcut(_ it: NSMenuItem) -> String {
        guard !it.keyEquivalent.isEmpty else { return "" }
        var s = ""
        let m = it.keyEquivalentModifierMask
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        return s + it.keyEquivalent.uppercased()
    }

    // MARK: writing-menu

    static func writingMenu(_ ctx: Ctx) async {
        let c = ctx.c
        await PanelsScenario.resize(ctx, width: 1280)
        guard let g = c.ghosts, let l = c.alternatives, ctx.pane.overflow != nil else { T.expect(false, "ghost, alternatives and overflow attached"); return }
        T.expect(c.contextMenuProvider != nil, "the writing space sets its own right-click menu")
        let panel = AlternativesAttach.panel(ctx.wc.root.area)

        // 1. a selection: the three writing actions with their shortcuts, nothing else
        let sel = range(ctx, "pencil in my bag")
        c.textView.setSelectedRange(sel)
        let m1 = menu(ctx, on: "pencil in my bag", offset: 3)
        T.expect(titles(m1) == [WritingMenu.ghostTitle, AlternativesAttach.addTitle, OverflowMenu.stashTitle],
                 "selection: \(titles(m1))")
        let keys = m1?.items.map(shortcut) ?? []
        T.expect(keys == ["⌥G", "⌥A", ""], "selection: shortcuts shown \(keys)")
        let upstream = titles(m1).filter { upstreamTitles.contains($0) }
        T.expect(upstream.isEmpty && m1?.items.allSatisfy({ $0.submenu == nil }) == true, "no Cut/Copy/Paste, Format, Paragraph, Insert, Select all or submenus (\(upstream))")
        T.expect(m1?.allowsContextMenuPlugIns == false, "no Services in the menu")
        expectNoWritingTools(ctx, rightClickMenus: [m1, overflowMenu(ctx)])
        perform(m1, AlternativesAttach.addTitle)
        await T.pause(0.4)
        T.expect(panel.isOpen && panel.hasFocus, "Add Alternative… opens the panel on the selection, field focused")
        panel.close()
        await T.pause(0.3)

        // 2. ghost text: Revive only
        let ghostRange = range(ctx, "Some days it is the only tool I need.")
        _ = g.ghost(from: ghostRange.location, to: NSMaxRange(ghostRange))
        caretAtStart(ctx)
        let m2 = menu(ctx, on: "Some days it is", offset: 4)
        T.expect(titles(m2) == [WritingMenu.reviveTitle] && m2.map { shortcut($0.items[0]) } == "⌥G", "ghost text: \(titles(m2)) \(m2.map { shortcut($0.items[0]) } ?? "")")
        perform(m2, WritingMenu.reviveTitle)
        T.expect(g.ranges.isEmpty, "Revive from the menu brings the text back")

        // 3. text with versions: Show Alternatives opens the panel on it
        let word = range(ctx, "thumbtack")
        let ids = l.addVersion("paperclip", author: .me, level: .word, range: word, show: false)
        T.expect(ids != nil, "a version of \"thumbtack\" added")
        caretAtStart(ctx)
        let m3 = menu(ctx, on: "thumbtack", offset: 3)
        T.expect(titles(m3) == [WritingMenu.showAlternativesTitle] && m3.map { shortcut($0.items[0]) } == "", "text with versions: \(titles(m3))")
        perform(m3, WritingMenu.showAlternativesTitle)
        await T.pause(0.4)
        T.expect(panel.isOpen && panel.rows.count == 2, "Show Alternatives opens the panel with the word's 2 versions (\(panel.rows.count) rows)")
        panel.close()
        await T.pause(0.3)

        // 4. a misspelled word: the guesses on top, then Ignore / Learn Spelling
        insert(ctx, " I recieve it.", after: "The last line stays where it is.")
        caretAtStart(ctx)
        let m4 = menu(ctx, on: "recieve", offset: 3)
        let t4 = titles(m4)
        let sep = t4.firstIndex(of: "-") ?? t4.count
        T.expect(sep > 0 && t4.prefix(sep).contains("receive"), "misspelled word: guesses on top \(t4.prefix(sep))")
        T.expect(Array(t4.suffix(from: sep)) == ["-", WritingMenu.ignoreSpellingTitle, WritingMenu.learnSpellingTitle], "then Ignore and Learn Spelling (\(t4))")
        perform(m4, "receive")
        T.expect(text(ctx).contains("I receive it.") && !text(ctx).contains("recieve"), "a guess replaces the word")
        // a misspelled word inside a selection: spelling on top, the writing actions below
        insert(ctx, " It is beleive.", after: "I receive it.")
        let bel = range(ctx, "It is beleive.")
        c.textView.setSelectedRange(bel)
        let m5 = menu(ctx, on: "beleive", offset: 2)
        let t5 = titles(m5)
        T.expect(t5.first != WritingMenu.ghostTitle && t5.contains("believe") && Array(t5.suffix(4)) == ["-", WritingMenu.ghostTitle, AlternativesAttach.addTitle, OverflowMenu.stashTitle],
                 "misspelled word in a selection: \(t5)")
        // Ignore Spelling holds for this document
        caretAtStart(ctx)
        perform(menu(ctx, on: "beleive", offset: 2), WritingMenu.ignoreSpellingTitle)
        let m6 = menu(ctx, on: "beleive", offset: 2)
        T.expect(m6 == nil, "after Ignore Spelling the word offers nothing: \(titles(m6))")

        // 5. plain text, no selection: no menu at all
        caretAtStart(ctx)
        let m7 = menu(ctx, on: "pencil in my bag", offset: 3)
        T.expect(m7 == nil, "plain text without a selection: no menu (\(titles(m7)))")

        // 6. the real right click (window event): the same menus pop up, and none on plain text
        caretAtStart(ctx)
        let real0 = await realRightClick(ctx, at: range(ctx, "pencil in my bag"), offset: 3, shot: nil)
        T.expect(real0.menu == nil, "real right click on plain text: no menu (\(real0.menu ?? []), selection \(real0.selection))")
        c.textView.setSelectedRange(range(ctx, "pencil in my bag"))
        let real1 = await realRightClick(ctx, at: range(ctx, "pencil in my bag"), offset: 3, shot: "hints-menu-\(appearance).png")
        T.expect(real1.menu == [WritingMenu.ghostTitle, AlternativesAttach.addTitle, OverflowMenu.stashTitle], "real right click on a selection pops \(real1.menu ?? [])")
        caretAtStart(ctx)
    }

    final class Box: @unchecked Sendable { var menu: [String]?; var shot: String?; var rect = CGRect.zero; var windowNumber = 0; var downs = 0 }

    /// A right mouse down sent to the window (NSView.rightMouseDown pops the menu and tracks it
    /// modally); the menu is read when it starts tracking, optionally screenshotted, then dismissed,
    /// or, with `choose`, that item is picked with the keyboard (Down arrow to it, Return) as a
    /// person would, so the action runs the way a real pick runs it.
    static func realRightClick(_ ctx: Ctx, at r: NSRange, offset: Int, shot: String?, choose: String? = nil) async -> (menu: [String]?, selection: NSRange) {
        let w = ctx.wc.window!
        w.makeFirstResponder(ctx.c.textView)
        await T.pause(0.2)
        let box = Box()
        box.shot = shot.map { (ctx.out as NSString).appendingPathComponent($0) }
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let f = w.frame
        box.rect = CGRect(x: f.minX, y: screenH - f.maxY, width: f.width, height: f.height)
        box.windowNumber = w.windowNumber
        let obs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard let m = n.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                box.menu = m.items.map { $0.isSeparatorItem ? "-" : $0.title }
                if let want = choose, let i = m.items.firstIndex(where: { $0.title == want }) {
                    box.downs = m.items.prefix(i + 1).filter { !$0.isSeparatorItem && $0.isEnabled }.count
                }
            }
            let wn = box.windowNumber
            DispatchQueue.global().async {
                usleep(450_000)
                func key(_ ch: String, _ code: UInt16) {
                    NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: wn, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                                     isARepeat: false, keyCode: code)!, atStart: false)
                }
                if box.downs > 0 {
                    for _ in 0..<box.downs { key(String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), 125); usleep(60_000) }
                    key("\r", 36)
                    return
                }
                if let path = box.shot {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-R", "\(Int(box.rect.minX)),\(Int(box.rect.minY)),\(Int(box.rect.width)),\(Int(box.rect.height))", path]
                    try? p.run(); p.waitUntilExit()
                }
                // the menu's event loop runs in a private mode (main-queue blocks and timers wait), so
                // dismiss it the way a person would: Escape (postEvent is safe off the main thread)
                let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: wn, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53)!
                NSApp.postEvent(esc, atStart: false)
            }
        }
        let loc = SelfTestScenarios.windowPoint(ctx, NSRange(location: r.location + offset, length: 0))
        let e = NSEvent.mouseEvent(with: .rightMouseDown, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(NSEvent.mouseEvent(with: .rightMouseUp, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: false)
        w.sendEvent(e)   // returns once the menu is dismissed (at once when there is none)
        await T.pause(0.2)
        NotificationCenter.default.removeObserver(obs)
        if let s = shot { T.log("screenshot \(s) \(FileManager.default.fileExists(atPath: box.shot!) ? "written" : "MISSING")") }
        return (box.menu, ctx.c.textView.selectedRange())
    }
}
