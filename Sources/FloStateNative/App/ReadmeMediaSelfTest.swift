import AppKit
import AVFoundation
import CoreMedia
import FloCore
import FloKit
import ScreenCaptureKit

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
///                  With FLO_README_VIDEO=1 the window is recorded the whole time: a ScreenCaptureKit
///                  stream of this one window into readme-demo.mov, or, when the stream is refused,
///                  frames the app renders itself (cacheDisplay, 15 fps) into readme-frames/ with
///                  their times in readme-frames/times.txt.
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

    static func shots(_ ctx: Ctx) async {
        guard let w = ctx.wc.window, let ov = ctx.pane.overflow else { T.expect(false, "window and Overflow controller"); return }
        UserDefaults.standard.removeObject(forKey: OverflowSidecarStore.openKey(ctx.file))
        ov.setOpen(false, animated: false)
        // 1320 x 860 pt, top left of the visible screen (the window stills and the stream are window only)
        let vis = (w.screen ?? NSScreen.main)!.visibleFrame
        let size = NSSize(width: min(1320, vis.width - 40), height: min(860, vis.height - 20))
        w.setFrame(NSRect(x: vis.minX + 20, y: vis.maxY - size.height - 10, width: size.width, height: size.height), display: true)
        T.log("screen \(Int(vis.width))x\(Int(vis.height)) visible, window \(Int(w.frame.width))x\(Int(w.frame.height)) pt, scale \(w.backingScaleFactor)")
        w.makeFirstResponder(ctx.c.textView)
        ctx.c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await settle(ctx, 1.0)

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
        AltPanelScenarios.clickText(ctx, "Some days", offset: 2)
        await settle(ctx, 0.9)
        T.expect(panel.isOpen && w.firstResponder === ctx.c.textView, "a click in the page: focus in the page, the panel stays open")
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
        T.screenshot(ctx, "readme-hero-all-\(appearance).png")
        await settle(ctx, 0.6)
        await rec?.stop()
    }
}

/// The demo window on video, window only. A ScreenCaptureKit stream of this window when the system
/// allows it; otherwise frames the app renders itself (cacheDisplay of the window frame view).
@MainActor
final class WindowRecorder {
    let window: NSWindow
    let out: String
    private var stream: StreamWriter?
    private var timer: Timer?
    private var frameIndex = 0
    private var times: [String] = []
    private var t0 = Date()
    private let inFlight = DispatchSemaphore(value: 6)

    init(window: NSWindow, out: String) { self.window = window; self.out = out }

    func start() async {
        let sw = StreamWriter()
        if await sw.start(windowNumber: CGWindowID(window.windowNumber), url: URL(fileURLWithPath: (out as NSString).appendingPathComponent("readme-demo.mov"))) {
            stream = sw
            SelfTestRunner.log("video: ScreenCaptureKit stream of window \(window.windowNumber)")
            return
        }
        let dir = (out as NSString).appendingPathComponent("readme-frames")
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        SelfTestRunner.log("video: stream refused, rendering frames into \(dir)")
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
        if let s = stream { await s.stop(); return }
        timer?.invalidate()
        for _ in 0..<6 { while inFlight.wait(timeout: .now()) != .success { await SelfTestRunner.pause(0.02) } }   // every frame written
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

/// ScreenCaptureKit stream of one window into an H.264 .mov (30 fps at the backing scale, no cursor,
/// no audio, no shadow).
private func streamLog(_ s: String) { FileHandle.standardOutput.write("selftest: \(s)\n".data(using: .utf8)!) }

private final class StreamWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private var frames = 0
    private let queue = DispatchQueue(label: "flowriter.readme.frames")

    func start(windowNumber: CGWindowID, url: URL) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let w = content.windows.first(where: { $0.windowID == windowNumber }) else {
                streamLog("video: ScreenCaptureKit does not list window \(windowNumber)"); return false
            }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(w.frame.width * scale) & ~1
            config.height = Int(w.frame.height * scale) & ~1
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = false
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.ignoreShadowsSingleWindow = true
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: config.width, AVVideoHeightKey: config.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000],
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else { streamLog("video: writer failed \(String(describing: writer.error))"); return false }
            self.writer = writer
            self.input = input
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            streamLog("video: \(config.width)x\(config.height) px")
            return true
        } catch {
            streamLog("video: ScreenCaptureKit refused: \(error.localizedDescription)")
            return false
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = att.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let writer = writer, let input = input else { return }
        if !started { writer.startSession(atSourceTime: sb.presentationTimeStamp); started = true }
        if input.isReadyForMoreMediaData, input.append(sb) { frames += 1 }
    }

    func stop() async {
        try? await stream?.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.input?.markAsFinished()
                if let w = self.writer { w.finishWriting { c.resume() } } else { c.resume() }
            }
        }
        streamLog("video: stopped, \(frames) frames, writer status \(writer?.status.rawValue ?? -1)")
    }
}
