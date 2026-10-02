import AppKit
import FloCore
import FloKit

/// Flowriter: the README hero shots and demo video. VM only, like every window test:
/// scripts/readme-media-vm.sh runs it on Tests/fixtures/readme-media/first-draft.md once per
/// appearance (FLO_TEST_APPEARANCE). Not part of all-vm-suites.sh: it checks nothing about
/// behaviour beyond the steps it needs, it only makes pictures.
///   readme-shots   the window at 1320 x 860 pt plays a short writing flow with real key events
///                  (the self test path: the window's key monitor, then the window): type a line,
///                  select it (⇧⌘←) and ghost it (⌥G), select a word and add two versions with ⌥A,
///                  step through them with Up, click back into the page, open Overflow (⌥O), stash
///                  a sentence (⌘K s). Window stills (screencapture -o -l): readme-hero-<appearance>.png
///                  (ghost + Alternatives panel) and readme-hero-all-<appearance>.png (Overflow too).
///                  With FLO_README_VIDEO=1 the window is recorded the whole time as frames the app
///                  renders itself (cacheDisplay, 15 fps) into readme-frames/ with their times in
///                  readme-frames/times.txt. No screen recording: it would put the system's recording
///                  badge on the window and link ScreenCaptureKit into the shipped app.
@MainActor
enum ReadmeMediaScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context

    static let names: Set<String> = ["readme-shots"]
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }
    static let typed = "Most days they need a second try."
    static let word = "easily"
    static let versions = ["quickly", "without a fight"]
    static let stash = "Most of them do not, and that is fine."

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        guard names.contains(name) else { return false }
        // never the installed app's identity, defaults domain or data folder
        guard Bundle.main.bundleIdentifier != ForkIdentity.bundleID else {
            T.expect(false, "readme-shots refuses to run as the installed app (\(ForkIdentity.bundleID))"); return true
        }
        guard !ctx.model.dataDir.baseURL.path.hasPrefix(AppDataDirectory.defaultBaseURL.path) else {
            T.expect(false, "readme-shots refuses the real data folder"); return true
        }
        SelfTestScenarios.installTestMenu()
        AlternativesScenarios.installTestMenu()
        await shots(ctx)
        ctx.model.flushDirtyFiles()
        return true
    }

    static func text(_ ctx: Ctx) -> NSString { ctx.c.state.doc.string as NSString }

    static func settle(_ ctx: Ctx, _ s: Double) async {
        await T.pause(s)
        ctx.wc.root.needsLayout = true
        ctx.wc.root.layoutSubtreeIfNeeded()
        ctx.c.textView.display()
        ctx.wc.window!.displayIfNeeded()
    }

    static func arrowChar(_ code: UInt16) -> String {
        let f: Int = code == 123 ? NSLeftArrowFunctionKey : code == 124 ? NSRightArrowFunctionKey : code == 125 ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
        return String(UnicodeScalar(f)!)
    }

    static func arrow(_ ctx: Ctx, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        T.key(ctx, arrowChar(code), code: code, mods: mods.union([.function, .numericPad]))
    }

    /// Typing at a believable pace (60 to 100 ms a key).
    static func typeSlowly(_ ctx: Ctx, _ s: String) async {
        for ch in s {
            T.key(ctx, String(ch), code: ch == " " ? 49 : 0)
            ctx.wc.window!.displayIfNeeded()
            await T.pause(Double.random(in: 0.06...0.10))
        }
    }

    static func select(_ ctx: Ctx, _ s: String) {
        let r = text(ctx).range(of: s)
        T.expect(r.location != NSNotFound, "found \"\(s)\"")
        ctx.c.textView.setSelectedRange(r)
    }

    /// Stills show an active window (colored traffic lights), whatever the VM session did meanwhile.
    static func frontmost(_ ctx: Ctx, _ w: NSWindow) async {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        await settle(ctx, 0.3)
    }

    static func shots(_ ctx: Ctx) async {
        guard let w = ctx.wc.window, let ov = ctx.pane.overflow else { T.expect(false, "window and Overflow controller"); return }
        UserDefaults.standard.removeObject(forKey: OverflowSidecarStore.openKey(ctx.file))
        ov.setOpen(false, animated: false)
        // 1320 x 860 pt, top left of the visible screen (the stills and the frames are window only)
        let vis = (w.screen ?? NSScreen.main)!.visibleFrame
        let size = NSSize(width: min(1320, vis.width - 40), height: min(860, vis.height - 20))
        w.setFrame(NSRect(x: vis.minX + 20, y: vis.maxY - size.height - 10, width: size.width, height: size.height), display: true)
        T.log("screen \(Int(vis.width))x\(Int(vis.height)) visible, window \(Int(w.frame.width))x\(Int(w.frame.height)) pt, scale \(w.backingScaleFactor)")
        w.makeFirstResponder(ctx.c.textView)
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await settle(ctx, 1.0)

        await frontmost(ctx, w)   // the first frame already shows an active window
        let rec = ProcessInfo.processInfo.environment["FLO_README_VIDEO"] == "1" ? WindowRecorder(window: w, out: ctx.out) : nil
        await rec?.start()
        await settle(ctx, 1.4)

        // 1. type a line at the end
        arrow(ctx, 125, [.command])   // ⌘↓: the end of the document
        await T.pause(0.5)
        T.key(ctx, "\r", code: 36); await T.pause(0.12)
        T.key(ctx, "\r", code: 36); await T.pause(0.3)
        await typeSlowly(ctx, typed)
        T.expect(text(ctx).hasSuffix(typed) || text(ctx).contains(typed), "typed the new line")
        await T.pause(0.8)

        // 2. select it and ghost it
        arrow(ctx, 123, [.command, .shift])   // ⇧⌘←: to the start of the line
        await settle(ctx, 0.8)
        T.expect(ctx.c.textView.selectedRange().length == (typed as NSString).length, "⇧⌘← selected the typed line (\(ctx.c.textView.selectedRange()))")
        T.appKey(ctx, "g", code: 5, mods: [.option])
        await settle(ctx, 0.3)
        arrow(ctx, 124)   // → collapses the selection
        await settle(ctx, 1.4)

        // 3. Alternatives on a word: two versions, then step through them
        select(ctx, word)
        await settle(ctx, 0.7)
        AltPanelScenarios.optionA(ctx)
        let panel = AlternativesScenarios.panel(ctx)
        T.expect(panel.isOpen && panel.inputHasFocus, "⌥A opened the Alternatives panel with the add line focused")
        await settle(ctx, 0.8)
        for v in versions {
            await typeSlowly(ctx, v)
            await T.pause(0.35)
            AlternativesScenarios.returnKey(ctx)
            await settle(ctx, 0.6)
        }
        for _ in 0..<versions.count + 1 {
            AlternativesScenarios.arrow(ctx, down: false)
            await settle(ctx, 0.9)
        }
        // end on the last version in the page
        for _ in 0..<2 where !text(ctx).contains("come \(versions.last!)") {
            AlternativesScenarios.arrow(ctx, down: true)
            await settle(ctx, 0.9)
        }
        T.expect(text(ctx).contains("come \(versions.last!)"), "the page shows \"\(versions.last!)\"")
        AltPanelScenarios.clickText(ctx, versions.last!, offset: 10)   // inside the alternative, so the panel keeps its versions
        await settle(ctx, 0.9)
        if w.firstResponder !== ctx.c.textView {
            // The click itself is covered by the alt-panel suite; here the demo only needs the caret back in the page.
            T.log("click left focus on \(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"), panel open \(panel.isOpen); focusing the page")
            w.makeFirstResponder(ctx.c.textView)
            let at = text(ctx).range(of: versions.last!).location
            if at != NSNotFound { ctx.c.textView.setSelectedRange(NSRange(location: at + 10, length: 0)) }
            await settle(ctx, 0.5)
        }
        T.expect(panel.isOpen && w.firstResponder === ctx.c.textView, "back in the page: focus in the page, the panel stays open")
        await frontmost(ctx, w)
        T.screenshot(ctx, "readme-hero-\(appearance).png")
        await settle(ctx, 0.4)

        // 4. Overflow: open it, stash a sentence into it
        T.appKey(ctx, "o", code: 31, mods: [.option])
        await settle(ctx, 1.2)
        T.expect(ov.isOpen, "⌥O opened Overflow")
        select(ctx, stash)
        await settle(ctx, 0.9)
        T.appKey(ctx, "k", code: 40, mods: [.command])
        await settle(ctx, 0.7)
        T.appKey(ctx, "s", code: 1)
        await settle(ctx, 1.0)
        T.expect(ov.text.contains(stash), "⌘K s stashed the sentence in Overflow")
        await settle(ctx, 1.6)
        await frontmost(ctx, w)
        T.screenshot(ctx, "readme-hero-all-\(appearance).png")
        await settle(ctx, 0.6)
        await rec?.stop()
    }
}

/// The demo window on video, window only: frames the app renders itself (cacheDisplay of the window
/// frame view), so no screen recording permission and no recording badge.
@MainActor
final class WindowRecorder {
    let window: NSWindow
    let out: String
    private var timer: Timer?
    private var frameIndex = 0
    private var times: [String] = []
    private var t0 = Date()
    private let inFlight = DispatchSemaphore(value: 6)

    init(window: NSWindow, out: String) { self.window = window; self.out = out }

    func start() async {
        let dir = (out as NSString).appendingPathComponent("readme-frames")
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        SelfTestRunner.log("video: rendering frames into \(dir)")
        t0 = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame(dir) }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func frame(_ dir: String) {
        guard inFlight.wait(timeout: .now()) == .success, let fv = window.contentView?.superview,
              let rep = fv.bitmapImageRepForCachingDisplay(in: fv.bounds) else { return }
        fv.cacheDisplay(in: fv.bounds, to: rep)
        frameIndex += 1
        let name = String(format: "f%05d.png", frameIndex)
        times.append(String(format: "%@ %.4f", name, Date().timeIntervalSince(t0)))
        let box = RepBox(rep), path = (dir as NSString).appendingPathComponent(name), sem = inFlight
        DispatchQueue.global(qos: .userInitiated).async {
            try? box.rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            sem.signal()
        }
    }

    func stop() async {
        timer?.invalidate()
        for _ in 0..<6 { while inFlight.wait(timeout: .now()) != .success { await SelfTestRunner.pause(0.02) } }   // every frame written
        for _ in 0..<6 { inFlight.signal() }   // a semaphore freed below its start value traps
        let dir = (out as NSString).appendingPathComponent("readme-frames")
        times.append(String(format: "end %.4f", Date().timeIntervalSince(t0)))
        try? times.joined(separator: "\n").appending("\n").write(toFile: (dir as NSString).appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
        SelfTestRunner.log("video: \(frameIndex) frames in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    }
}

private final class RepBox: @unchecked Sendable {
    let rep: NSBitmapImageRep
    init(_ rep: NSBitmapImageRep) { self.rep = rep }
}
