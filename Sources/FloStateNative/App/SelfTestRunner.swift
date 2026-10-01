import AppKit
import FloCore
import FloKit

/// Flowriter: scripted end-to-end runs inside the real app process (real window, real run
/// loop, real autosave). They open a window, so they only run in the test VM: the process refuses to
/// start unless `FLO_SELFTEST_VM=1` is set (the scripts/*-vm-test.sh runners set it).
///
///   FloStateNative --ui-selftest <scenario> <file.md> <outDir>
///
/// Scenarios: `roundtrip` (open, edit, undo the edit, autosave: bytes on disk must match), and
/// the feature scenarios in the other *SelfTest.swift files. Each prints `selftest: …` lines and
/// exits 0 on success, 1 on a failed expectation.
@MainActor
enum SelfTestRunner {
    static var keep: [AnyObject] = []
    static var failures: [String] = []

    static func log(_ s: String) { FileHandle.standardOutput.write("selftest: \(s)\n".data(using: .utf8)!) }

    static func expect(_ ok: Bool, _ what: String) {
        log("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures.append(what) }
    }

    static func finish() -> Never {
        if let name = ProcessInfo.processInfo.environment["FLO_FULLSCREEN_SHOT"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-t", "jpg", NSHomeDirectory() + "/flo-out/" + name]
            try? p.run(); p.waitUntilExit()
        }
        log(failures.isEmpty ? "ALL PASS" : "FAILED: \(failures.joined(separator: "; "))")
        exit(failures.isEmpty ? 0 : 1)
    }

    static func run(_ args: [String]) {
        guard ProcessInfo.processInfo.environment["FLO_SELFTEST_VM"] == "1" else {
            print("--ui-selftest opens a window: run it in the test VM (FLO_SELFTEST_VM=1)"); exit(64)
        }
        guard let i = args.firstIndex(of: "--ui-selftest"), args.count > i + 3 else { print("usage: --ui-selftest <scenario> <file> <outDir>"); exit(64) }
        let scenario = args[i + 1], file = args[i + 2], out = args[i + 3]
        let root = (file as NSString).deletingLastPathComponent
        let data = NSTemporaryDirectory() + "flo-selftest-data" + (ProcessInfo.processInfo.environment["FLO_SELFTEST_DATA_SUFFIX"] ?? "")
        if scenario != "restart" && scenario != "recent-restart" { try? FileManager.default.removeItem(atPath: data) }
        SelectionBar.selfTestOff = !scenario.hasPrefix("selection-bar")   // Flowriter: the bar only in its own scenarios
        WritingToolsSwitch.prepareForSelfTest(scenario)   // Flowriter: tools off on first launch
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] == "dark" { app.appearance = NSAppearance(named: .darkAqua) }
        if ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] == "light" { app.appearance = NSAppearance(named: .aqua) }
        let model = ShellModel(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        let wc = ShellWindowController(model: model, frame: NSRect(x: 30, y: 60, width: 1090, height: 900))  // clear of a system prompt the VM shows at x ≥ 1150
        keep = [wc, model]
        wc.window!.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let timeout = Double(ProcessInfo.processInfo.environment["FLO_SELFTEST_TIMEOUT"] ?? "") ?? 60
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { log("timeout"); failures.append("timeout"); finish() }
        // a main thread stuck in a modal loop (a context menu tracking) never runs the timeout above
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 15) {
            FileHandle.standardOutput.write("selftest: FAIL timeout (main thread stuck)\n".data(using: .utf8)!)
            exit(3)
        }
        Task { @MainActor in
            // Flowriter: the integrity and space scenarios run in the writing space's document window
            if FlowriterSpace.enabled && (["integrity", "space", "quiet", "combined", "restart-combined", "panels", "writing-menu", "hints", "hints-restart", "overflow-typing", "restart-overflow-typing"] + ViewTogglesScenarios.names + FileNameScenarios.names + RecentScenarios.names + SelectionBarScenarios.names + ToolsScenarios.names).contains(scenario) { await model.editor.openCompactFile(file) }
            else { await model.openWorkspace(root, openFile: file, keepSession: false) }
            wc.flush()
            guard let pane = await waitFor(5, { wc.root.area.activeFilePane?.controller != nil ? wc.root.area.activeFilePane : nil }),
                  let c = pane.controller else { log("no editor"); exit(2) }
            wc.window!.makeFirstResponder(c.textView)
            let ctx = Context(wc: wc, model: model, pane: pane, c: c, file: file, out: out)
            await SelfTestScenarios.run(scenario, ctx)
            finish()
        }
        app.run()
    }

    struct Context {
        let wc: ShellWindowController
        let model: ShellModel
        let pane: EditorPaneView
        let c: EditorController
        let file: String
        let out: String
    }

    // MARK: helpers

    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Poll every 20 ms until `f` returns a value or `seconds` pass.
    static func waitFor<T>(_ seconds: Double, _ f: () -> T?) async -> T? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let v = f() { return v }
            await pause(0.02)
        }
        return f()
    }

    /// A real key event through the window (as typing does).
    static func key(_ ctx: Context, _ chars: String, code: UInt16 = 0, mods: NSEvent.ModifierFlags = []) {
        let w = ctx.wc.window!
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        w.sendEvent(e)
    }

    /// A key the way the app gets it: the window's key monitor first (ShellWindowController.handleKey:
    /// the ⌥ shortcuts and the ⌘K leader, WritingKeys.swift), and when the monitor lets the event go,
    /// the window as `key` does. True when the monitor took the key (nothing reached the page).
    @discardableResult
    static func appKey(_ ctx: Context, _ chars: String, code: UInt16 = 0, mods: NSEvent.ModifierFlags = []) -> Bool {
        let w = ctx.wc.window!
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        guard let rest = ctx.wc.handleKey(e) else { return true }
        w.sendEvent(rest)
        return false
    }

    /// The key codes of the leader letters and the ones the tests type after ⌘K.
    static let letterCodes: [String: UInt16] = ["a": 0, "s": 1, "g": 5, "x": 7, "v": 9, "o": 31, "l": 37, "k": 40, "r": 15]

    /// ⌘K, then `letter`. True when both keys were taken by the leader.
    @discardableResult
    static func leader(_ ctx: Context, _ letter: String) -> Bool {
        let started = appKey(ctx, "k", code: 40, mods: [.command])
        return appKey(ctx, letter, code: letterCodes[letter] ?? 0) && started
    }

    static func type(_ ctx: Context, _ text: String) {
        for ch in text { key(ctx, String(ch), code: ch == " " ? 49 : 0) }
    }

    static func backspace(_ ctx: Context, _ n: Int = 1) { for _ in 0..<n { key(ctx, "\u{7f}", code: 51) } }

    static func undo(_ ctx: Context) { key(ctx, "z", code: 6, mods: [.command]) }

    /// Window screenshot (window only, no shadow) into the out dir.
    static func screenshot(_ ctx: Context, _ name: String) {
        ctx.wc.window!.displayIfNeeded()
        let path = (ctx.out as NSString).appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(ctx.wc.window!.windowNumber)", path]
        try? p.run()
        p.waitUntilExit()
        log("screenshot \(name) exit=\(p.terminationStatus)")
    }

    /// Screen region of the window (catches popovers, which are their own windows).
    static func screenshotWithPopovers(_ ctx: Context, _ name: String) {
        let w = ctx.wc.window!
        w.displayIfNeeded()
        let screenH = NSScreen.screens.first?.frame.height ?? w.screen?.frame.height ?? 0
        let f = w.frame
        let path = (ctx.out as NSString).appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(f.minX)),\(Int(screenH - f.maxY)),\(Int(f.width)),\(Int(f.height))", path]
        try? p.run()
        p.waitUntilExit()
        log("screenshot \(name) exit=\(p.terminationStatus)")
    }

    /// A real click (down + up) at a point in `view`'s coordinates.
    static func click(_ ctx: Context, at point: NSPoint, in view: NSView) {
        let w = ctx.wc.window!
        let p = view.convert(point, to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(ev(.leftMouseUp), atStart: false)
        w.sendEvent(ev(.leftMouseDown))
    }

    static func diskBytes(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
}

@MainActor
enum SelfTestScenarios {
    typealias T = SelfTestRunner

    static func run(_ name: String, _ ctx: SelfTestRunner.Context) async {
        switch name {
        case "roundtrip": await roundtrip(ctx)
        case "integrity": await Integrity.run(ctx)  // IntegritySelfTest.swift
        case "space": await Integrity.spaceShots(ctx)
        case "quiet": await QuietSelfTest.run(ctx)   // QuietSelfTest.swift
        case "panels": await PanelsScenario.run(ctx)   // PanelsSelfTest.swift
        default:
            if await runGhostScenario(name, ctx) { return }   // Flowriter: Ghost (GhostSelfTest.swift)
            if await AlternativesScenarios.run(name, ctx) { return }   // Flowriter: alternatives
            if await ViewTogglesScenarios.run(name, ctx) { return }   // Flowriter: view toggles (ViewTogglesSelfTest.swift)
            if await RecentScenarios.run(name, ctx) { return }   // Flowriter: File > Open Recent and the quick picker (RecentSelfTest.swift)
            if await FileNameScenarios.run(name, ctx) { return }   // Flowriter: the file name and save dot (FileNameSelfTest.swift)
            if await CombinedScenarios.run(name, ctx) { return }
            if await WritingMenuScenarios.run(name, ctx) { return }   // Flowriter: the right-click menu (WritingMenuSelfTest.swift)
            if await ReviveClickScenarios.run(name, ctx) { return }   // Flowriter: Revive by right click and shortcut (ReviveClickSelfTest.swift)
            if await HintsScenarios.run(name, ctx) { return }   // Flowriter: the shortcut line (HintsSelfTest.swift)   // Flowriter: ghost + alternatives + overflow on one post
            if await ToolsScenarios.run(name, ctx) { return }
            if await SelectionBarScenarios.run(name, ctx) { return }   // Flowriter: the selection bar (SelectionBarSelfTest.swift)   // Flowriter: the count is the tools switch (ToolsSwitchSelfTest.swift)
            if await runOverflowScenario(name, ctx) { return }   // Flowriter: Overflow
            T.log("unknown scenario \(name)"); T.failures.append("unknown scenario")
        }
    }

    static func text(_ ctx: SelfTestRunner.Context) -> NSString { ctx.c.state.doc.string as NSString }

    /// Open, type a character at the end, wait for the autosave, delete it, wait for the autosave:
    /// the file must end up byte for byte as it was.
    static func roundtrip(_ ctx: SelfTestRunner.Context) async {
        guard let original = T.diskBytes(ctx.file) else { T.expect(false, "read original"); return }
        T.log("opened \(ctx.file) (\(original.count) bytes), editor has \(ctx.c.state.doc.length) UTF-16 units")
        await T.pause(0.5)
        T.screenshot(ctx, "step2-opened.png")
        let end = ctx.c.state.doc.length
        ctx.c.textView.setSelectedRange(NSRange(location: end, length: 0))
        T.type(ctx, "Z")
        let edited = await T.waitFor(5) { () -> Data? in
            let d = T.diskBytes(ctx.file); return d != original ? d : nil
        }
        T.expect(edited != nil && edited!.count == original.count + 1, "autosave wrote the edit (\(edited?.count ?? -1) bytes)")
        T.backspace(ctx)
        let back = await T.waitFor(5) { () -> Data? in
            let d = T.diskBytes(ctx.file); return d == original ? d : nil
        }
        T.expect(back != nil, "autosave after deleting the edit restored the exact bytes")
        ctx.model.flushDirtyFiles()
        T.expect(T.diskBytes(ctx.file) == original, "bytes on disk equal the original after a final flush")
    }
}
