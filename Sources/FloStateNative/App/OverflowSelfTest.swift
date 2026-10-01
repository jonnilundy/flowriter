import AppKit
import FloCore
import FloKit

/// Flowriter Overflow scenarios for `--ui-selftest` (VM only):
///   scripts/ui-vm-test.sh overflow restart-overflow
///   FLO_TEST_APPEARANCE=dark scripts/ui-vm-test.sh overflow-shots
///   scripts/ui-vm-test.sh overflow-typing restart-overflow-typing
/// `restart-overflow` must follow `overflow` in the same run (and `restart-overflow-typing` must follow
/// `overflow-typing`): it is a second process reading what the first one saved.
extension SelfTestScenarios {
    static func runOverflowScenario(_ name: String, _ ctx: SelfTestRunner.Context) async -> Bool {
        switch name {
        case "overflow": await overflowMain(ctx)
        case "restart-overflow": await overflowRestart(ctx)
        case "overflow-shots": await overflowShots(ctx)
        case "overflow-typing": await overflowTyping(ctx)
        case "restart-overflow-typing": await overflowTypingRestart(ctx)
        default: return false
        }
        return true
    }

    static let paragraph = "The reason, my reason, is what I hope to set down here."
    static let sample = """
    The table paragraph is good but too long. Try it after the plank line.

    Every woodworker says "patience". Find a better word.

    https://example.com/notes/joinery.html

    Outline
    - why not
    - the joiner
    - what stopping looks like
    """

    /// A menu bar like the app's, so key equivalents reach the Overflow menu.
    static func installTestMenu() {
        guard NSApp.mainMenu == nil || NSApp.mainMenu?.items.contains(where: { $0.title == "Overflow" }) == false else { return }
        let m = NSMenu()
        let app = NSMenuItem(); app.submenu = NSMenu(); m.addItem(app)
        let win = NSMenuItem(); let wm = NSMenu(title: "Window"); win.submenu = wm; m.addItem(win)
        NSApp.windowsMenu = wm
        NSApp.mainMenu = m
        OverflowMenu.installMenu(in: m)
    }

    /// A key chord through the main menu (as the window does for menu key equivalents).
    @discardableResult
    static func menuKey(_ ctx: SelfTestRunner.Context, _ chars: String, code: UInt16, mods: NSEvent.ModifierFlags) -> Bool {
        let w = ctx.wc.window!
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        if ctx.c.textView.performKeyEquivalent(with: e) { return true }
        return NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
    }

    /// Geometry of the page column: anything that reflowed the text changes one of these numbers.
    static func columnGeometry(_ ctx: SelfTestRunner.Context) -> [CGFloat] {
        let c = ctx.c, tv = c.textView
        let len = c.state.doc.length
        var g: [CGFloat] = [tv.textContainerOrigin.x, tv.textContainerOrigin.y, tv.textContainer?.size.width ?? -1, tv.frame.width, tv.frame.height,
                            c.scrollView.frame.minX, c.scrollView.frame.width, c.scrollView.contentView.bounds.origin.y]
        for pos in [0, len / 4, len / 2, len * 3 / 4, len] {
            if let r = c.rect(forPosition: pos, in: ctx.pane) { g += [r.minX, r.minY, r.width, r.height] } else { g.append(-999) }
        }
        return g
    }

    /// What the text view draws for the visible column, as bytes.
    static func columnPixels(_ ctx: SelfTestRunner.Context) -> Data? {
        let tv = ctx.c.textView
        let r = tv.visibleRect
        guard let rep = tv.bitmapImageRepForCachingDisplay(in: r) else { return nil }
        tv.cacheDisplay(in: r, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func overflowMain(_ ctx: SelfTestRunner.Context) async {
        OverflowController.animations = false
        installTestMenu()
        guard let ov = ctx.pane.overflow else { T.expect(false, "pane has an Overflow controller"); return }
        let original = ctx.c.state.doc.string
        // a clean start: the open state is saved per viewer and an earlier run may have left it open
        UserDefaults.standard.removeObject(forKey: OverflowSidecarStore.openKey(ctx.file))
        ov.setOpen(false)
        // another feature's state in the same document sidecar (the shared session)
        let session = SidecarSession.shared(for: ctx.file)
        let quote = "A careless cut is a wasted board."
        let qr = text(ctx).range(of: quote)
        session.update { _ = try? $0.addGhost(from: qr.location, to: NSMaxRange(qr)) }
        await T.pause(0.4)

        // 1. toggle: button and shortcut. The text column must not move.
        T.expect(!ov.isOpen && ov.panel.isHidden, "panel starts closed")
        T.expect(ov.button.frame.maxX <= ctx.pane.bounds.width && ov.button.frame.minY > ctx.pane.bounds.height / 2, "toggle button sits at the bottom right")
        let rail = (ctx.pane.superview as? EditorAreaView)?.rail
        let railBefore = rail?.isHidden   // the writing space hides the outline rail anyway
        let g0 = columnGeometry(ctx), p0 = columnPixels(ctx)
        T.click(ctx, at: NSPoint(x: ov.button.frame.midX, y: ov.button.frame.midY), in: ctx.pane)
        await T.pause(0.1)
        T.expect(ov.isOpen && !ov.panel.isHidden, "clicking the button opens the panel")
        T.expect(rail?.isHidden == true, "the outline rail is hidden while the panel is open")
        T.expect(abs(ov.panel.frame.maxX - ctx.pane.bounds.width) < 0.5 && ov.panel.frame.width >= OverflowController.minPanelWidth, "panel is on the right edge (\(Int(ov.panel.frame.width)) pt wide)")
        if let right = ov.columnRight, ctx.pane.bounds.width - right >= OverflowController.minPanelWidth + 24 {
            T.expect(ov.panel.frame.minX >= right + 12, "the panel stays clear of the page column (panel at \(Int(ov.panel.frame.minX)), column ends at \(Int(right)))")
        }
        // the panel's tint and hairline run up to the window top: nothing of the tab backing covers them
        let rootView = ctx.wc.root
        let panelInRoot = ov.panel.convert(ov.panel.bounds, to: rootView)
        T.expect(abs(panelInRoot.minY - rootView.bounds.minY) < 0.5 && abs(panelInRoot.maxY - rootView.bounds.maxY) < 0.5, "panel spans the window content height (y \(panelInRoot.minY) to \(panelInRoot.maxY) of \(rootView.bounds.height))")
        T.expect(rootView.tabBacking.frame.maxX <= panelInRoot.minX + 0.5, "the tab backing stops at the panel (backing ends \(Int(rootView.tabBacking.frame.maxX)), panel starts \(Int(panelInRoot.minX)))")
        let g1 = columnGeometry(ctx), p1 = columnPixels(ctx)
        T.expect(g0 == g1, "opening does not move the text column (\(g0.count) geometry values equal)")
        T.expect(p0 != nil && p0 == p1, "opening does not change what the text view draws (\(p0?.count ?? 0) bytes)")
        T.appKey(ctx, "o", code: 31, mods: [.option])
        T.expect(!ov.isOpen && ov.panel.isHidden, "Option-O closes it")
        T.expect(rail?.isHidden == railBefore, "the outline rail is back as it was when it closes (hidden \(String(describing: railBefore)))")
        T.expect(columnGeometry(ctx) == g0, "closing does not move the text column")
        T.appKey(ctx, "o", code: 31, mods: [.option])
        T.expect(ov.isOpen, "Option-O opens it again")
        T.expect(columnGeometry(ctx) == g0, "opened again: column still where it was")
        ov.setOpen(false)
        T.expect(ctx.c.scrollView.frame == ctx.pane.scrollBox, "the editor's scroll view is never resized by the panel")

        // 2. stash from the context menu, one undo puts it back
        let r = text(ctx).range(of: paragraph)
        T.expect(r.location != NSNotFound, "found the paragraph to stash")
        ctx.c.textView.setSelectedRange(r)
        // on the selection: the writing space's menu offers the selection's actions only there
        let menu = SelfTestScenarios.rightClickMenu(ctx, at: NSRange(location: r.location + 3, length: 0))
        let idx = menu?.items.firstIndex { $0.title == OverflowMenu.stashTitle }
        T.expect(idx != nil, "right-click menu has \"\(OverflowMenu.stashTitle)\" with a selection")
        if let i = idx { menu?.performActionForItem(at: i) }
        T.expect(!(ctx.c.state.doc.string as NSString).contains(paragraph), "the paragraph is gone from the page")
        T.expect(ov.text == paragraph && ov.isOpen, "the paragraph is in the panel and the panel opened (\"\(ov.text.prefix(30))\")")
        T.expect(ctx.c.state.doc.string.range(of: "\n\n\n") == nil, "no blank hole left where it was")
        let afterStash = ctx.c.state.doc.string
        if let g = session.sidecar.ghosts.first {
            let t = ctx.c.state.doc.string as NSString
            T.expect(g.anchor.to <= t.length && t.substring(with: NSRange(location: g.anchor.from, length: g.anchor.length)) == quote,
                     "the ghost's anchor moved with the text the stash removed before it")
        } else { T.expect(false, "ghost present in the shared session") }
        T.undo(ctx)
        T.expect(ctx.c.state.doc.string == original, "one Command-Z restores the page exactly (\(ctx.c.state.doc.length) vs \(original.utf16.count) units)")
        T.expect(ov.text.isEmpty, "the same Command-Z took the stashed text out of the panel (\"\(ov.text.prefix(20))\")")
        T.key(ctx, "z", code: 6, mods: [.command, .shift])
        T.expect(ctx.c.state.doc.string == afterStash && ov.text == paragraph, "redo stashes it again (panel \"\(ov.text.prefix(20))\")")
        T.undo(ctx)
        ctx.c.textView.window?.makeFirstResponder(ctx.c.textView)
        // the same through the shortcut, then redo leaves the page as after the stash
        ov.text = ""
        ctx.c.textView.setSelectedRange(text(ctx).range(of: paragraph))
        let handled = T.leader(ctx, "s")
        T.expect(handled && ctx.c.state.doc.string == afterStash && ov.text == paragraph,
                 "⌘K then s stashes the selection (handled \(handled), docOK \(ctx.c.state.doc.string == afterStash), panel \"\(ov.text.prefix(20))\")")
        T.undo(ctx)
        T.expect(ctx.c.state.doc.string == original, "undo after the shortcut restores the page")
        // no selection: nothing happens
        ctx.c.textView.setSelectedRange(NSRange(location: 3, length: 0))
        T.expect(!ov.stashSelection() && ctx.c.state.doc.string == original, "stash with no selection does nothing")

        // 3. edit in the panel
        ov.text = paragraph
        ov.panel.textView.window?.makeFirstResponder(ov.panel.textView)
        ov.panel.textView.setSelectedRange(NSRange(location: (ov.text as NSString).length, length: 0))
        T.type(ctx, "\n\nnote: check the ending")
        T.expect(ov.text == paragraph + "\n\nnote: check the ending", "typing in the panel edits it (\"\(ov.text.suffix(24))\")")
        T.expect(ov.panel.textView.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true, "panel font is monospaced (\(ov.panel.textView.font?.fontName ?? "nil"))")
        if let pf = ov.panel.textView.font, let body = ctx.c.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            T.expect(pf.pointSize < body.pointSize, "panel text is smaller than the page (\(pf.pointSize) vs \(body.pointSize))")
        }

        // 4. drag back into the page
        ov.text = "DRAGGED-BACK text"
        await dragPanelToPage(ctx, ov)

        // 5. "Move into page" from the panel's right-click menu
        ov.text = "MOVED-IN line\n\nkeep this"
        let mi = (ov.text as NSString).range(of: "MOVED-IN line")
        ov.panel.textView.setSelectedRange(mi)
        let tvp = ov.panel.textView
        let rectOnScreen = tvp.firstRect(forCharacterRange: mi, actualRange: nil)
        let rectInView = tvp.convert(ctx.wc.window!.convertFromScreen(rectOnScreen), from: nil)
        let pm = tvp.menu(for: rightClick(ctx, in: tvp, at: NSPoint(x: rectInView.minX + 6, y: rectInView.midY)))
        let mIdx = pm?.items.firstIndex { $0.title == "Move into page" }
        T.expect(mIdx != nil, "panel right-click menu has \"Move into page\"")
        ctx.c.textView.setSelectedRange(NSRange(location: ctx.c.state.doc.length, length: 0))
        if let i = mIdx { pm?.performActionForItem(at: i) }
        T.expect(ctx.c.state.doc.string.hasSuffix("MOVED-IN line") && !ov.text.contains("MOVED-IN"),
                 "\"Move into page\" puts the text at the page caret and takes it out of the panel (page ends \"\(ctx.c.state.doc.string.suffix(20))\", panel \"\(ov.text)\")")
        T.undo(ctx)

        // 6. save: the document sidecar next to the post; the .md untouched; other sidecar state kept
        ov.text = sample
        ov.setOpen(true)
        ov.flush()
        ctx.model.flushDirtyFiles()
        let docURL = URL(fileURLWithPath: ctx.file)
        let sidecarURL = SidecarStore.url(for: docURL)
        let onDisk = SidecarStore.load(for: docURL, documentText: ctx.c.state.doc.string).sidecar
        T.expect(FileManager.default.fileExists(atPath: sidecarURL.path), "sidecar written: \(sidecarURL.lastPathComponent)")
        T.expect(OverflowItems.join(onDisk.sortedOverflow.map(\.text)) == sample, "sidecar holds the panel text as \(onDisk.overflow.count) overflow items, in order")
        T.expect(onDisk.ghosts.count == 1, "the ghost another feature put in the session is in the same file (\(onDisk.ghosts.count))")
        T.expect(OverflowSidecarStore().load(documentPath: ctx.file, documentText: ctx.c.state.doc.string).open, "open state saved")
        let md = String(data: T.diskBytes(ctx.file) ?? Data(), encoding: .utf8) ?? ""
        T.expect(!md.contains("Outline\n- why not") && !md.contains("table paragraph"), "the .md does not contain the panel's text")
        ov.text = sample + "\n\nlast line"
        await T.pause(0.9)   // the debounce alone saves
        let after = SidecarStore.load(for: docURL, documentText: ctx.c.state.doc.string).sidecar
        T.expect(after.sortedOverflow.last?.text == "last line", "a pause after typing saves on its own")
        T.expect(after.ghosts.count == 1 && after.sortedOverflow.count == OverflowItems.split(sample).count + 1, "the ghost is still there after overflow saves (\(after.ghosts.count))")
        T.expect(Set(onDisk.overflow.map(\.id)).isSubset(of: Set(after.overflow.map(\.id))), "existing items keep their ids when the text after them changes")
        ov.flush()
        try? (ov.text).write(toFile: (ctx.file as NSString).deletingLastPathComponent + "/overflow-expected.txt", atomically: true, encoding: .utf8)
        T.screenshot(ctx, "overflow-open.png")
    }

    /// Real key events posted to this process: the path a keyboard takes (window server event,
    /// NSApp.sendEvent, the text input context), not a synthesized NSEvent.
    static func postKeys(_ s: String, shift: Bool = false) async {
        let codes: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
                                             "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
                                             "n": 45, "m": 46, " ": 49, "\n": 36]
        let pid = ProcessInfo.processInfo.processIdentifier
        for ch in s {
            guard let code = codes[ch] else { T.log("postKeys: no key code for \(ch.debugDescription)"); continue }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                if shift { e?.flags = .maskShift }
                e?.postToPid(pid)
                await T.pause(0.012)
            }
        }
        await T.pause(0.15)
    }

    /// The panel as it was in a recorded session (build 69): three items, the caret at the end.
    static let typingStart = "after\n\nsomethinge else here\n\na linke of something"

    /// Typing in the panel the way a person does: real key events, Return for a new line, a pause
    /// longer than the save debounce. What was typed stays, spaced as typed, one Return a line break
    /// inside an item and a blank line between items, and the sidecar holds the same items.
    static func overflowTyping(_ ctx: SelfTestRunner.Context) async {
        OverflowController.animations = false
        installTestMenu()
        guard let ov = ctx.pane.overflow else { T.expect(false, "pane has an Overflow controller"); return }
        let tv = ov.panel.textView
        let docURL = URL(fileURLWithPath: ctx.file)
        func saved() -> [String] { SidecarStore.load(for: docURL, documentText: ctx.c.state.doc.string).sidecar.sortedOverflow.map(\.text) }

        // 1. no system text after the caret: macOS inline predictions put grey text into the panel as
        // marked text, and in build 69 the typed word went away with the prediction
        T.expect(tv.inlinePredictionType == .no, "panel: inline predictions off (type \(tv.inlinePredictionType.rawValue))")
        if #available(macOS 15.0, *) { T.expect(tv.mathExpressionCompletionType == .no, "panel: math completion off (type \(tv.mathExpressionCompletionType.rawValue))") }
        T.expect(!tv.isAutomaticTextReplacementEnabled && !tv.isAutomaticSpellingCorrectionEnabled, "panel: text replacement and autocorrect off")
        WritingMenuScenarios.expectNoWritingTools(ctx, rightClickMenus: [WritingMenuScenarios.overflowMenu(ctx)])

        ov.text = typingStart
        ov.flush()
        ov.setOpen(true)
        await T.pause(0.3)
        // the page has a selection, then the panel gets the focus (as a click does)
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 12))
        ctx.wc.window!.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (ov.text as NSString).length, length: 0))
        T.expect(saved() == ["after", "somethinge else here", "a linke of something"], "start: three items in the sidecar (\(saved().count))")

        // 2. Return, then type on the new empty line; wait past the save debounce
        await postKeys("\ndone")
        T.expect(ov.text == typingStart + "\ndone", "Return then typing on the new line puts the text there (\(ov.text.suffix(26).debugDescription))")
        await T.pause(0.9)
        T.expect(ov.text == typingStart + "\ndone", "the typed line is still there after the save (\(ov.text.suffix(26).debugDescription))")
        T.expect(saved() == ["after", "somethinge else here", "a linke of something\ndone"],
                 "one Return is a line break inside the item: still three items, the last two lines long (\(saved().map(\.debugDescription)))")

        // 3. a composed character (accent menu, input methods): marked text, then committed
        tv.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await T.pause(0.1)
        tv.insertText("\u{E9}", replacementRange: NSRange(location: NSNotFound, length: 0))
        await T.pause(0.5)
        T.expect(ov.text == typingStart + "\ndone\u{E9}" && !tv.hasMarkedText(), "a composed character is committed in place (\(ov.text.suffix(8).debugDescription))")
        if let st = tv.textStorage, st.length > 0 {
            let a = st.attributes(at: st.length - 1, effectiveRange: nil), b = st.attributes(at: 0, effectiveRange: nil)
            T.expect((a[.font] as? NSFont) == (b[.font] as? NSFont) && (a[.paragraphStyle] as? NSParagraphStyle) == (b[.paragraphStyle] as? NSParagraphStyle)
                     && (a[.foregroundColor] as? NSColor) == (b[.foregroundColor] as? NSColor), "the committed character has the panel's font, colour and line height")
        }
        T.backspace(ctx)

        // 4. a blank line starts a new item; Shift-Return is a line break too
        await postKeys("\n\nfirst line\nsecond line")
        await postKeys("\n", shift: true)
        await postKeys("third line")
        await T.pause(0.9)
        let expected = typingStart + "\ndone\n\nfirst line\nsecond line\nthird line"
        T.expect(ov.text == expected, "the panel holds exactly what was typed (\(ov.text.suffix(40).debugDescription))")
        T.expect(saved() == ["after", "somethinge else here", "a linke of something\ndone", "first line\nsecond line\nthird line"],
                 "a blank line separates items, single Returns stay inside one (\(saved().map(\.debugDescription)))")

        // 5. mid-line typing and paste
        let mid = (ov.text as NSString).range(of: "second").location + 6
        tv.setSelectedRange(NSRange(location: mid, length: 0))
        await postKeys(" half")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(" pasted", forType: .string)
        tv.paste(nil)
        await T.pause(0.9)
        let final = expected.replacingOccurrences(of: "second line", with: "second half pasted line")
        T.expect(ov.text == final, "typing and pasting mid-line edit that line (\(ov.text.suffix(48).debugDescription))")

        // 6. spacing on screen: one Return is one line down, a blank line two
        let ns = ov.text as NSString
        func lineY(_ s: String) -> CGFloat { tv.firstRect(forCharacterRange: NSRange(location: ns.range(of: s).location, length: 1), actualRange: nil).minY }
        let step = lineY("first line") - lineY("second half")   // screen coordinates: y grows upwards
        let gap = lineY("done") - lineY("first line")
        T.expect(step > 4 && abs(gap - 2 * step) < 1, "on screen: a line break is one line (\(Int(step)) pt), a blank line two (\(Int(gap)) pt)")
        T.expect(abs(lineY("a linke") - lineY("done") - step) < 1, "the line typed after Return sits one line below (\(Int(lineY("a linke") - lineY("done"))) pt)")

        // 7. closing and opening the panel keeps it; a fresh load from disk gives the same text back
        ov.setOpen(false); ov.setOpen(true)
        T.expect(ov.text == final, "closing and opening keeps the text")
        ov.flush()
        T.expect(OverflowItems.join(saved()) == final, "the sidecar on disk joins back to exactly the panel text")
        try? final.write(toFile: (ctx.file as NSString).deletingLastPathComponent + "/overflow-typing-expected.txt", atomically: true, encoding: .utf8)
        T.screenshot(ctx, "overflow-typing.png")
    }

    static func overflowTypingRestart(_ ctx: SelfTestRunner.Context) async {
        OverflowController.animations = false
        let dir = (ctx.file as NSString).deletingLastPathComponent
        guard let expected = try? String(contentsOfFile: dir + "/overflow-typing-expected.txt", encoding: .utf8) else { T.expect(false, "expected text from the first run"); return }
        guard let ov = ctx.pane.overflow else { T.expect(false, "pane has an Overflow controller"); return }
        T.expect(ov.text == expected, "after restart the panel holds exactly the typed text (\(ov.text.suffix(40).debugDescription))")
        T.expect(ov.isOpen, "after restart the panel is open")
        // typing goes on working in the reopened panel
        ctx.wc.window!.makeFirstResponder(ov.panel.textView)
        ov.panel.textView.setSelectedRange(NSRange(location: (ov.text as NSString).length, length: 0))
        await postKeys("\nafter restart")
        await T.pause(0.9)
        T.expect(ov.text == expected + "\nafter restart", "typing after a restart works (\(ov.text.suffix(30).debugDescription))")
        T.screenshot(ctx, "overflow-typing-restarted.png")
    }

    static func overflowRestart(_ ctx: SelfTestRunner.Context) async {
        OverflowController.animations = false
        let dir = (ctx.file as NSString).deletingLastPathComponent
        guard let expected = try? String(contentsOfFile: dir + "/overflow-expected.txt", encoding: .utf8) else { T.expect(false, "expected text from the first run"); return }
        guard let ov = ctx.pane.overflow else { T.expect(false, "pane has an Overflow controller"); return }
        T.expect(ov.text == expected, "after restart the panel holds the same text (\(ov.text.utf16.count) units)")
        T.expect(ov.isOpen && !ov.panel.isHidden, "after restart the panel is open as it was left")
        await T.pause(0.3)
        T.screenshot(ctx, "overflow-restarted.png")
    }

    static func overflowShots(_ ctx: SelfTestRunner.Context) async {
        OverflowController.animations = false
        guard let ov = ctx.pane.overflow else { T.expect(false, "pane has an Overflow controller"); return }
        let mode = ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light"
        await T.pause(0.6)
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        ov.text = sample
        ctx.wc.window!.makeFirstResponder(ctx.c.textView)
        await T.pause(0.3)
        T.screenshot(ctx, "overflow-\(mode)-closed.png")
        ov.setOpen(true)
        await T.pause(0.4)
        T.screenshot(ctx, "overflow-\(mode)-open.png")
        // the empty panel, with its hint
        ov.text = ""
        await T.pause(0.3)
        T.screenshot(ctx, "overflow-\(mode)-empty.png")
        // narrow window: the panel covers the margin and the edge of the text
        var f = ctx.wc.window!.frame
        f.size.width = 760
        ctx.wc.window!.setFrame(f, display: true)
        ov.text = sample
        await T.pause(0.6)
        T.screenshot(ctx, "overflow-\(mode)-narrow.png")
    }

    static func rightClick(_ ctx: SelfTestRunner.Context, in view: NSView, at point: NSPoint? = nil) -> NSEvent {
        let p = view.convert(point ?? NSPoint(x: view.bounds.midX, y: min(view.bounds.midY, 400)), to: nil)
        return NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: ctx.wc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Select the panel's text and move it into the page the way a drop does.
    static func dragPanelToPage(_ ctx: SelfTestRunner.Context, _ ov: OverflowController) async {
        let tv = ov.panel.textView
        let page = ctx.c.textView
        let before = ctx.c.state.doc.string
        let word = "DRAGGED-BACK text"
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        // the drop target: start of the "## Why Not" heading line
        let at = (before as NSString).range(of: "A quick answer").location
        let ok = await FakeDrag.drop(text: word, from: tv, onto: page, atCharacter: at, ctx: ctx)
        T.expect(ok && ctx.c.state.doc.string == (before as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: word),
                 "dropping panel text on the page inserts it at the drop point (\(ok))")
        T.expect(ov.text.isEmpty, "the dragged text left the panel (move): \"\(ov.text)\"")
        T.undo(ctx)
    }
}

/// A drag without the mouse: the drop side of AppKit's text drag, driven with a fake dragging
/// info (real sessions need the window server's mouse events, which the VM test cannot send).
@MainActor
final class FakeDrag: NSObject, NSDraggingInfo {
    let pb: NSPasteboard
    let window: NSWindow
    let location: NSPoint
    weak var source: AnyObject?

    init(pb: NSPasteboard, window: NSWindow, location: NSPoint, source: AnyObject?) { self.pb = pb; self.window = window; self.location = location; self.source = source }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}

    static func drop(text: String, from source: NSTextView, onto target: NSTextView, atCharacter at: Int, ctx: SelfTestRunner.Context) async -> Bool {
        let pb = NSPasteboard(name: NSPasteboard.Name("flowriter-test-drag"))
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard let rect = ctx.c.rect(forPosition: at, in: target) else { return false }
        let inWindow = target.convert(NSPoint(x: rect.minX + 2, y: rect.midY), to: nil)
        let info = FakeDrag(pb: pb, window: ctx.wc.window!, location: inWindow, source: source)
        _ = target.draggingEntered(info)
        _ = target.draggingUpdated(info)
        let ok = target.performDragOperation(info)
        target.concludeDragOperation(info)
        // the source of a move removes what it dragged when the session ends
        source.delete(nil)
        return ok
    }
}

