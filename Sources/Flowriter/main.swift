import AppKit
import FlowriterKit

let arguments = CommandLine.arguments

func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

MainActor.assumeIsolated {
    if let file = option("--snapshot") {
        // --snapshot <file.md> --out <png> [--notes <file>] [--dark] [--focus] [--caret N] [--width W] [--height H]
        _ = NSApplication.shared
        var options = Snapshot.Options()
        options.dark = arguments.contains("--dark")
        options.focus = arguments.contains("--focus")
        options.notes = option("--notes").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        options.caret = option("--caret").flatMap { Int($0) }
        if let w = option("--width").flatMap(Double.init) { options.width = CGFloat(w) }
        if let h = option("--height").flatMap(Double.init) { options.height = CGFloat(h) }
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard let png = Snapshot.png(markdown: text, options: options), let out = option("--out") else { exit(1) }
        try? png.write(to: URL(fileURLWithPath: out))
        exit(0)
    }
    if let file = option("--perf") {
        // --perf <file.md>: time per typed letter in the middle of a document, layout and drawing included
        _ = NSApplication.shared
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        var start = Date()
        let controller = Snapshot.window(markdown: text, options: Snapshot.Options())
        let editor = controller.editor
        controller.window?.displayIfNeeded()
        print(String(format: "load %d units: %.1f ms", text.utf16.count, Date().timeIntervalSince(start) * 1000))
        let ns = text as NSString
        editor.setSelectedRange(NSRange(location: ns.lineRange(for: NSRange(location: ns.length / 2, length: 0)).location, length: 0))
        var times: [Double] = []
        for (i, ch) in String(repeating: "the quick brown fox jumps over the lazy dog ", count: 5).prefix(200).enumerated() {
            start = Date()
            if i % 50 == 49 { editor.insertNewline(nil) } else { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
            controller.window?.displayIfNeeded()
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let sorted = times.sorted()
        print(String(format: "keystroke: avg %.2f ms, p50 %.2f, p95 %.2f, max %.2f", times.reduce(0, +) / Double(times.count),
                     sorted[times.count / 2], sorted[times.count * 95 / 100], sorted.last ?? 0))
        exit(0)
    }
    // --offscreen: the normal app with every window parked off screen and no focus taken (scripted runs)
    AppDelegate.offScreen = arguments.contains("--offscreen")
    // --update-now: check for a newer release at launch and install it without asking (prints each step)
    UpdateWindowController.installRightAway = arguments.contains("--update-now")
    AppDelegate.run(smoke: arguments.contains("--smoke"))
}
