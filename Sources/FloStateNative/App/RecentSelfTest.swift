import AppKit
import FloCore
import FloKit

/// Flowriter: File > Open Recent and the quick recent picker (`--ui-selftest recent|recent-restart <post> <out>`,
/// VM only; scripts/recent-vm-test.sh on Tests/fixtures/recent).
///   recent          the writing space's document window on essays/garden.md, with essays/orchard.md,
///                   essays/harvest.md and drafts/garden.md beside it.
///                   File menu: Open Recent right under Open…; empty at first (Clear Menu off). Files
///                   opened in turn show newest first without the window's own file, names without ".md",
///                   the ~ path as the tooltip; picking one opens it in the same window (one tab, the
///                   name, the title and the text follow); two files named garden show "garden — drafts"
///                   with the folder muted; a file that is gone leaves the list; the Dock list
///                   (NSDocumentController) holds the same files. ⇧⌘O opens the palette in its recent
///                   intent (the window's file left out), typing filters, ↑↓ move, Return opens, Esc
///                   closes and gives the page its focus back. ⌘K shows "r recent" and r opens the same
///                   picker. Clear Menu empties the menu, the picker and the Dock list; the files are
///                   still known (the app reopens the last one). Nothing in the window moves at any
///                   step. Screenshots recent-menu-*, recent-picker-*, recent-picker-filter-*.
///   recent-restart  a new process on essays/orchard.md: the list and the cleared state held.
@MainActor
enum RecentScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static let tol: CGFloat = 0.5
    static let names = ["recent", "recent-restart"]
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        switch name {
        case "recent": await main(ctx)
        case "recent-restart": await restart(ctx)
        default: return false
        }
        return true
    }

    // MARK: helpers

    static func fresh(_ ctx: Ctx) -> Ctx {
        guard let pane = ctx.wc.root.area.activeFilePane, let c = pane.controller else { return ctx }
        return Ctx(wc: ctx.wc, model: ctx.model, pane: pane, c: c, file: ctx.model.editor.activeFilePath ?? ctx.file, out: ctx.out)
    }

    static func relayout(_ ctx: Ctx) async {
        ctx.wc.flush()
        ctx.wc.root.needsLayout = true
        ctx.wc.root.layoutSubtreeIfNeeded()
        ctx.wc.window!.displayIfNeeded()
        await T.pause(0.15)
    }

    static func heading(_ path: String) -> String { (FileNameScenarios.disk(path).components(separatedBy: "\n").first) ?? "" }

    /// The page shows `path`: it is the active file, one tab, and the text starts with its first line.
    static func shows(_ ctx: Ctx, _ path: String) async -> Bool {
        let want = heading(path)
        let ok: Bool? = await T.waitFor(3) {
            let f = fresh(ctx)
            return ctx.model.editor.activeFilePath == path && f.c.state.doc.string.hasPrefix(want) ? true : nil
        }
        await relayout(ctx)
        return ok == true && ctx.model.editor.tabs.count == 1
    }

    /// Open… (the Open panel's path): the file replaces the window's document.
    static func open(_ ctx: Ctx, _ path: String) async {
        ctx.model.flushDirtyFiles()
        await ctx.model.editor.openCompactFile(path)
        _ = await shows(ctx, path)
    }

    static func fileMenu() -> NSMenu { NSApp.mainMenu!.items.first { $0.title == "File" }!.submenu! }
    static func recentMenu() -> NSMenu { fileMenu().items.first { $0.title == OpenRecentMenu.title }!.submenu! }

    /// The submenu as it is after AppKit opens it (menuNeedsUpdate).
    static func menu() -> NSMenu {
        let m = recentMenu()
        m.delegate?.menuNeedsUpdate?(m)
        return m
    }

    static func titles(_ m: NSMenu) -> [String] { m.items.map { $0.isSeparatorItem ? "—" : $0.title } }

    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    static func pick(_ m: NSMenu, _ title: String) -> Bool {
        guard let i = m.items.firstIndex(where: { $0.title == title }) else { return false }
        m.performActionForItem(at: i)
        return true
    }

    static func install(_ ctx: Ctx, opened: @escaping (String) -> Void = { _ in }) {
        let router = MenuRouter()
        let model = ctx.model
        router.focusedModel = { model }
        T.keep.append(router)
        NSApp.mainMenu = MainMenu.build(target: router)
        FlowriterSpace.installMenus(in: NSApp.mainMenu!, focused: { model }, recents: model.recentFilesStore, openWithoutWindow: opened)
    }

    /// What must hold still between documents: the chrome and the first line of the page.
    struct Chrome {
        var count: CGRect, toggles: CGRect, markdown: CGRect, name: CGRect, first: PanelsScenario.Line?
    }

    static func chrome(_ ctx: Ctx) -> Chrome {
        let c = fresh(ctx), root = ctx.wc.root, md = root.flowriterToggles.markdown
        return Chrome(count: root.flowriterCount.frame, toggles: root.flowriterToggles.frame, markdown: md.convert(md.bounds, to: root),
                      name: root.flowriterName.frame, first: PanelsScenario.lines(c).first)
    }

    static func sameChrome(_ a: Chrome, _ b: Chrome) -> Bool {
        func near(_ x: CGRect, _ y: CGRect) -> Bool {
            abs(x.minX - y.minX) <= tol && abs(x.minY - y.minY) <= tol && abs(x.width - y.width) <= tol && abs(x.height - y.height) <= tol
        }
        guard let fa = a.first, let fb = b.first else { return false }
        return near(a.count, b.count) && near(a.toggles, b.toggles) && near(a.markdown, b.markdown)
            && abs(a.name.minX - b.name.minX) <= tol && abs(a.name.minY - b.name.minY) <= tol && abs(a.name.height - b.name.height) <= tol
            && abs(fa.x0 - fb.x0) <= tol && abs(fa.y - fb.y) <= tol && abs(fa.h - fb.h) <= tol
    }

    static func describe(_ c: Chrome) -> String {
        String(format: "count %.0f,%.0f M↓ %.0f name %.0f,%.0f first line %.1f,%.1f", c.count.minX, c.count.minY, c.markdown.minX, c.name.minX, c.name.minY,
               c.first?.x0 ?? -1, c.first?.y ?? -1)
    }

    static func paletteOpen(_ ctx: Ctx) -> Bool { ctx.wc.root.paletteOverlay != nil && ctx.model.palette?.intent == .recent }

    static func pageHasFocus(_ ctx: Ctx) -> Bool { ctx.wc.window?.firstResponder === fresh(ctx).c.textView }

    /// The menu popped up as a context menu, a screenshot while it shows, dismissed with Esc.
    static func menuShot(_ ctx: Ctx, _ name: String) {
        let w = ctx.wc.window!
        let pop = NSMenu(title: OpenRecentMenu.title)
        pop.autoenablesItems = false
        pop.delegate = OpenRecentMenu.shared
        let path = (ctx.out as NSString).appendingPathComponent(name)
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let f = w.frame
        let rect = CGRect(x: f.minX, y: screenH - f.maxY, width: f.width, height: min(f.height, 420))
        let wn = w.windowNumber
        let obs = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in
            DispatchQueue.global().async {
                usleep(450_000)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
                try? p.run(); p.waitUntilExit()
                let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: wn, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53)!
                NSApp.postEvent(esc, atStart: false)
            }
        }
        pop.popUp(positioning: nil, at: NSPoint(x: 140, y: 150), in: ctx.wc.root)   // returns once dismissed
        NotificationCenter.default.removeObserver(obs)
        T.log("screenshot \(name) \(FileManager.default.fileExists(atPath: path) ? "written" : "MISSING")")
    }

    static func shiftCmdO(_ ctx: Ctx) -> Bool { T.appKey(ctx, "o", code: 31, mods: [.command, .shift]) }
    static func esc(_ ctx: Ctx) { T.appKey(ctx, "\u{1b}", code: 53) }
    static let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)

    // MARK: recent

    static func main(_ ctx: Ctx) async {
        let model = ctx.model, w = ctx.wc.window!
        let essays = (ctx.file as NSString).deletingLastPathComponent
        let work = (essays as NSString).deletingLastPathComponent
        let garden = WorkspaceFS.canonicalize(ctx.file)
        let orchard = essays + "/orchard.md", harvest = essays + "/harvest.md", draft = work + "/drafts/garden.md", ephemeral = essays + "/ephemeral.md"
        var withoutWindow: [String] = []
        WritingTools.isOn = true
        install(ctx) { withoutWindow.append($0) }
        await relayout(ctx)
        await T.pause(0.3)

        // the menu: Open Recent right under Open…, empty at first
        let file = fileMenu(), ft = titles(file)
        T.log("File menu: \(ft)")
        if let i = ft.firstIndex(of: "Open…") { T.expect(ft[safe: i + 1] == OpenRecentMenu.title, "File > Open Recent sits right under Open…") }
        else { T.expect(false, "File > Open… found") }
        T.expect(recentMenu().supermenu === file && file.items.first { $0.title == OpenRecentMenu.title }?.hasSubmenu == true, "Open Recent is a submenu")
        var m = menu()
        T.expect(titles(m) == ["—", "Clear Menu"] && m.items.last?.isEnabled == false, "nothing else opened yet: only Clear Menu, off (\(titles(m)))")

        // files opened in turn
        await open(ctx, orchard)
        await open(ctx, harvest)
        m = menu()
        T.expect(titles(m) == ["orchard", "garden", "—", "Clear Menu"], "newest first, the window's file (harvest) left out, no .md: \(titles(m))")
        T.expect(m.items[0].toolTip == tilde(orchard) && m.items[1].toolTip == tilde(garden) && tilde(garden).hasPrefix("~/"),
                 "the tooltip is the ~ path (\(m.items[0].toolTip ?? "nil"))")
        T.expect(m.items.last?.isEnabled == true, "Clear Menu is on")
        T.expect(m.items.filter { $0.action != nil && !$0.isSeparatorItem }.count == 3 && m.items.prefix(2).allSatisfy { $0.isEnabled }, "the rows can be picked")
        // the Dock icon's list holds the same documents
        let dock = NSDocumentController.shared.recentDocumentURLs.map { $0.lastPathComponent }
        T.expect(["garden.md", "orchard.md", "harvest.md"].allSatisfy(dock.contains), "the Dock list (NSDocumentController) has the files: \(dock)")

        // picking opens it in this window
        let c0 = chrome(ctx)
        T.log("chrome: \(describe(c0))")
        T.expect(pick(m, "garden"), "pick garden")
        T.expect(await shows(ctx, garden), "picking garden shows it: one tab, the text starts \"\(heading(garden))\"")
        let v = ctx.wc.root.flowriterName
        T.expect(v.name == "garden" && w.title == "garden" && w.representedURL?.path == garden, "the name, the window title and URL follow (\(v.name))")
        let c1 = chrome(ctx)
        T.expect(sameChrome(c0, c1), "picking moved neither the chrome nor the page's first line (\(describe(c1)))")
        T.expect(titles(menu()) == ["harvest", "orchard", "—", "Clear Menu"], "garden left the list, the others follow: \(titles(menu()))")

        // two files named garden
        await open(ctx, draft)
        await open(ctx, orchard)
        m = menu()
        T.expect(titles(m) == ["garden — drafts", "garden — essays", "harvest", "—", "Clear Menu"], "a shared name gets its folder: \(titles(m))")
        if let a = m.items[0].attributedTitle {
            let dash = (a.string as NSString).range(of: "— ").location
            let first = a.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let tail = a.attribute(.foregroundColor, at: max(0, dash), effectiveRange: nil) as? NSColor
            T.expect(a.string == "garden — drafts" && first == nil && tail?.isEqual(NSColor.secondaryLabelColor) == true, "the folder is muted, the name is not")
        } else { T.expect(false, "the row has an attributed title") }
        T.expect(m.items[0].toolTip == tilde(WorkspaceFS.canonicalize(draft)) && m.items[1].toolTip == tilde(garden), "the tooltips tell the two apart (\(m.items[0].toolTip ?? "nil"))")
        let f0 = chrome(ctx)
        menuShot(ctx, "recent-menu-\(appearance).png")
        await T.pause(0.2)
        T.expect(sameChrome(f0, chrome(ctx)), "the menu opening and closing moved nothing")

        // ⇧⌘O: the quick picker
        T.expect(shiftCmdO(ctx), "⇧⌘O is taken by the app")
        await T.pause(0.3)
        T.expect(paletteOpen(ctx), "⇧⌘O opens the palette with the recent intent")
        var pv = model.paletteView()
        T.expect(pv?.items.map(\.title) == ["garden — drafts", "garden — essays", "harvest"], "the picker lists the same files, the window's file left out: \(pv?.items.map(\.title) ?? [])")
        T.expect(pv?.items.map { $0.subtitle ?? "" } == [tilde(work + "/drafts"), tilde(essays), tilde(essays)], "each row shows its folder (\(pv?.items.map { $0.subtitle ?? "" } ?? []))")
        T.expect(ctx.wc.window?.firstResponder === ctx.wc.root.paletteOverlay?.input.currentEditor(), "the picker's field has the focus")
        let rect = ctx.wc.root.paletteOverlay?.card.frame ?? .zero
        T.expect(rect.width > 100 && ctx.wc.root.bounds.contains(rect), "the card sits inside the window")
        T.expect(sameChrome(f0, chrome(ctx)), "the picker moved nothing behind it")
        T.screenshot(ctx, "recent-picker-\(appearance).png")
        T.type(ctx, "harv")
        await T.pause(0.2)
        pv = model.paletteView()
        T.expect(pv?.items.map(\.title) == ["harvest"], "typing filters: \(pv?.items.map(\.title) ?? [])")
        T.screenshot(ctx, "recent-picker-filter-\(appearance).png")
        esc(ctx)
        await T.pause(0.2)
        T.expect(model.palette == nil && ctx.wc.root.paletteOverlay == nil, "Esc closes the picker")
        T.expect(pageHasFocus(ctx), "the page has the focus again")
        T.expect(ctx.model.editor.activeFilePath == WorkspaceFS.canonicalize(orchard), "Esc opened nothing")
        T.expect(sameChrome(f0, chrome(ctx)), "closing the picker moved nothing")

        // ↑↓ and Return
        T.expect(shiftCmdO(ctx), "⇧⌘O again")
        await T.pause(0.3)
        T.type(ctx, "garden")
        await T.pause(0.2)
        T.expect(model.paletteView()?.items.map(\.title) == ["garden — drafts", "garden — essays"] && model.palette?.selected == 0, "\"garden\" finds both, the first is selected")
        T.appKey(ctx, down, code: 125)
        T.expect(model.palette?.selected == 1, "↓ selects the second row")
        T.appKey(ctx, up, code: 126)
        T.expect(model.palette?.selected == 0, "↑ goes back")
        T.appKey(ctx, down, code: 125)
        T.appKey(ctx, "\r", code: 36)
        T.expect(await shows(ctx, garden), "Return opens the selected row (essays/garden)")
        T.expect(model.palette == nil && ctx.wc.root.paletteOverlay == nil, "the picker closed")
        T.expect(ctx.wc.root.flowriterName.name == "garden" && ctx.wc.window?.title == "garden", "the name follows")
        T.expect(pageHasFocus(ctx), "the page has the focus")
        let c2 = chrome(ctx)
        T.expect(sameChrome(c0, c2), "opening from the picker moved neither the chrome nor the page's first line (\(describe(c2)))")

        // ⌘K r
        T.expect(T.appKey(ctx, "k", code: 40, mods: [.command]) && HintStrip.leader, "⌘K starts the leader")
        T.expect(HintStrip.shownItems.last == HintStrip.Item(keys: "r", label: "recent") && (fresh(ctx).pane.hints?.line.hasSuffix("r recent") == true),
                 "the leader line ends with \"r recent\" (\(fresh(ctx).pane.hints?.line ?? "nil"))")
        T.expect(T.appKey(ctx, "r", code: 15), "r is taken by the leader")
        await T.pause(0.3)
        T.expect(paletteOpen(ctx) && !WritingKeys.leaderActive && !HintStrip.leader, "⌘K r opens the same picker and ends the leader")
        T.expect(model.paletteView()?.items.map(\.title) == ["orchard", "garden", "harvest"], "the picker lists \(model.paletteView()?.items.map(\.title) ?? [])")
        esc(ctx)
        await T.pause(0.2)
        T.expect(model.palette == nil && pageHasFocus(ctx), "Esc closes it")

        // a file that is gone leaves the list
        try? FileManager.default.copyItem(atPath: harvest, toPath: ephemeral)
        await open(ctx, ephemeral)
        await open(ctx, garden)
        T.expect(titles(menu()).contains("ephemeral"), "the new file shows: \(titles(menu()))")
        try? FileManager.default.removeItem(atPath: ephemeral)
        T.expect(!titles(menu()).contains("ephemeral"), "gone: the file leaves the menu")
        T.expect(shiftCmdO(ctx), "⇧⌘O")
        await T.pause(0.2)
        T.expect(model.paletteView()?.items.map(\.title).contains("ephemeral") == false, "and the picker")
        esc(ctx)
        await T.pause(0.2)

        // Clear Menu
        m = menu()
        T.expect(pick(m, "Clear Menu"), "pick Clear Menu")
        m = menu()
        T.expect(titles(m) == ["—", "Clear Menu"] && m.items.last?.isEnabled == false, "Clear Menu empties the menu: \(titles(m))")
        T.expect(NSDocumentController.shared.recentDocumentURLs.isEmpty, "and the Dock list")
        T.expect(shiftCmdO(ctx), "⇧⌘O")
        await T.pause(0.2)
        pv = model.paletteView()
        T.expect(pv?.items.isEmpty == true && pv?.empty == "No recent files.", "the picker says so (\(pv?.empty ?? "nil"))")
        T.appKey(ctx, "\r", code: 36)
        T.expect(model.palette != nil, "Return on an empty picker does nothing")
        esc(ctx)
        await T.pause(0.2)
        T.expect(model.recentFilesStore.load().contains { $0.path == garden }, "the files are still known (the app reopens the last one)")
        T.expect(withoutWindow.isEmpty, "no pick went to the no-window path")

        // opened again: back on the list, the others stay cleared
        await open(ctx, harvest)
        await open(ctx, garden)
        await open(ctx, orchard)
        m = menu()
        T.expect(titles(m) == ["garden", "harvest", "—", "Clear Menu"], "opened again: back on the list, the cleared ones stay off: \(titles(m))")
        for p in [garden, orchard, harvest, draft] { T.expect(FileManager.default.fileExists(atPath: p), "fixture \((p as NSString).lastPathComponent) still there") }
        ctx.model.flushDirtyFiles()
    }

    // MARK: recent-restart

    static func restart(_ ctx: Ctx) async {
        var withoutWindow: [String] = []
        install(ctx) { withoutWindow.append($0) }
        await relayout(ctx)
        let essays = (ctx.file as NSString).deletingLastPathComponent
        let m = menu()
        T.expect(titles(m) == ["garden", "harvest", "—", "Clear Menu"], "after a relaunch the list and the cleared state held: \(titles(m))")
        T.expect(pick(m, "harvest"), "pick harvest")
        T.expect(await shows(ctx, WorkspaceFS.canonicalize(essays + "/harvest.md")), "it opens in the window")
        T.expect(titles(menu()) == ["orchard", "garden", "—", "Clear Menu"], "and the list follows: \(titles(menu()))")
        T.expect(withoutWindow.isEmpty, "no pick went to the no-window path")
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
