import AppKit
import FloCore
import FloKit

/// Flowriter: the file name at the top left (`--ui-selftest file-name|file-name-full <post> <out>`,
/// VM only; scripts/file-name-vm-test.sh on Tests/fixtures/file-name/letter-to-a-friend.md).
///   file-name       the compact window: the name (no ".md") right of the traffic lights on their
///                   centre line, the tooltip path (~), the window title and representedURL, clear of
///                   the count; the menu (Show in Finder, Copy Path, Rename…); steady typing writes
///                   every key at once (the real save delay is logged) and shows no dot; a failed save
///                   shows the dot and a red name with the reason in the tooltip, and once the folder
///                   is writable the next key is written and the dot goes only after the file on disk
///                   has it; a long name truncates before the count (Rename and back); no view or text
///                   moves at any step. Screenshots file-name-*-<appearance>.png. The post ends
///                   as it was.
///   file-name-full  a workspace window with tabs: no name (the tab shows the title), representedURL set.
@MainActor
enum FileNameScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static let tol: CGFloat = 0.5
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }
    /// Run in the writing space's document window (SelfTestRunner.run); file-name-full is not.
    static let names = ["file-name"]

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        switch name {
        case "file-name": await compact(ctx)
        case "file-name-full": await full(ctx)
        default: return false
        }
        return true
    }

    // MARK: helpers

    static func view(_ ctx: Ctx) -> FileNameView { ctx.wc.root.flowriterName }

    static func relayout(_ ctx: Ctx) async {
        ctx.wc.root.needsLayout = true
        ctx.wc.root.layoutSubtreeIfNeeded()
        ctx.wc.window!.displayIfNeeded()
        await T.pause(0.1)
    }

    /// Everything that must hold still: the count, the toggle, the name's box, the page's lines.
    struct Frames: Equatable {
        var count: CGRect, countText: [CGFloat], toggles: CGRect, markdown: CGRect, name: CGRect, lines: [CGFloat]
    }

    static func frames(_ ctx: Ctx, lines n: Int = 6) -> Frames {
        let root = ctx.wc.root, md = root.flowriterToggles.markdown
        let lines = PanelsScenario.lines(ctx).prefix(n).flatMap { [$0.x0, $0.y, $0.h] }
        return Frames(count: root.flowriterCount.frame, countText: ViewTogglesScenarios.countEdges(ctx), toggles: root.flowriterToggles.frame,
                      markdown: md.convert(md.bounds, to: root), name: view(ctx).frame, lines: Array(lines))
    }

    static func same(_ a: Frames, _ b: Frames) -> Bool {
        func near(_ x: CGRect, _ y: CGRect) -> Bool {
            abs(x.minX - y.minX) <= tol && abs(x.minY - y.minY) <= tol && abs(x.width - y.width) <= tol && abs(x.height - y.height) <= tol
        }
        func nearAll(_ x: [CGFloat], _ y: [CGFloat]) -> Bool { x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= tol } }
        return near(a.count, b.count) && near(a.toggles, b.toggles) && near(a.markdown, b.markdown) && near(a.name, b.name)
            && nearAll(a.countText, b.countText) && nearAll(a.lines, b.lines)
    }

    static func describe(_ f: Frames) -> String {
        String(format: "count %.0f..%.0f, M↓ %.0f, name %.0f..%.0f", f.countText.first ?? -1, f.countText.last ?? -1, f.markdown.minX, f.name.minX, f.name.maxX)
    }

    /// The top left of the window, 560 by 56 pt (screen pixels), where the name sits.
    static func shootCorner(_ ctx: Ctx, _ name: String) {
        let w = ctx.wc.window!
        w.displayIfNeeded()
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let f = w.frame
        let path = (ctx.out as NSString).appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(f.minX)),\(Int(screenH - f.maxY)),\(Int(min(f.width, 760))),56", path]
        try? p.run(); p.waitUntilExit()
        T.log("screenshot \(name) exit=\(p.terminationStatus)")
    }

    static func disk(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func endCaret(_ ctx: Ctx) {
        ctx.c.textView.setSelectedRange(NSRange(location: ctx.c.state.doc.length, length: 0))
    }

    // MARK: file-name

    static func compact(_ ctx: Ctx) async {
        let root = ctx.wc.root, w = ctx.wc.window!, file = ctx.file
        guard let original = T.diskBytes(file) else { T.expect(false, "read the post"); return }
        WritingTools.isOn = true
        await relayout(ctx)
        await T.pause(0.4)
        let v = view(ctx)
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let short = (file as NSString).abbreviatingWithTildeInPath

        // the name, its tooltip and the window
        T.expect(ctx.model.isCompact && !v.isHidden, "compact window: the name shows")
        T.expect(v.name == stem && !v.name.hasSuffix(".md"), "the name is the file name without .md (\"\(v.name)\")")
        T.expect(v.toolTip == short && short.hasPrefix("~/"), "the tooltip is the full path with ~ (\"\(v.toolTip ?? "nil")\")")
        T.expect(w.title == stem, "the window title is the file name (\"\(w.title)\")")
        T.expect(w.representedURL?.path == file, "the window's representedURL is the file (\(w.representedURL?.path ?? "nil"))")
        T.expect(w.titleVisibility == .hidden, "the title bar text stays hidden")
        let s = v.style, count = root.flowriterCount
        T.expect(s.font == count.style.font && s.color.isEqual(count.style.color), "the name uses the count's font and muted colour")

        // where it sits: right of the traffic lights, on their centre line, clear of the count
        let f0 = frames(ctx)
        let textX = v.frame.minX + FileNameView.padX, textEnd = textX + v.shownWidth
        if let zoom = w.standardWindowButton(.zoomButton), let close = w.standardWindowButton(.closeButton) {
            let z = root.convert(zoom.convert(zoom.bounds, to: nil), from: nil)
            let c = root.convert(close.convert(close.bounds, to: nil), from: nil)
            T.log(String(format: "name: text %.1f..%.1f, box %@, lights %.1f..%.1f mid %.1f, %@", textX, textEnd,
                         NSStringFromRect(v.frame), c.minX, z.maxX, c.midY, describe(f0)))
            T.expect(v.frame.minX > z.maxX + 4, String(format: "the name starts after the traffic lights (box %.1f, zoom ends %.1f)", v.frame.minX, z.maxX))
            T.expect(abs(v.frame.midY - c.midY) <= 1, String(format: "the name sits on the traffic lights' centre line (%.1f vs %.1f)", v.frame.midY, c.midY))
        } else { T.expect(false, "traffic lights found") }
        T.expect(v.frame.maxX + 8 < f0.countText[0], String(format: "the name keeps clear of the count (name box ends %.1f, count starts %.1f)", v.frame.maxX, f0.countText[0]))
        T.expect(abs(v.shownWidth - v.style.width(v.name)) <= 0.5, "a short name is not truncated")

        // the menu
        let items = v.menu()?.items ?? []
        let titles = items.map { $0.isSeparatorItem ? "—" : $0.title }
        T.expect(titles == ["Show in Finder", "Copy Path", "—", "Rename…"], "menu: \(titles)")
        var revealed: String?
        let reveal = ctx.model.revealInFinder
        ctx.model.revealInFinder = { revealed = $0 }
        (items.first { $0.title == "Show in Finder" } as? ClosureMenuItem)?.handler?()
        ctx.model.revealInFinder = reveal
        T.expect(revealed == file, "Show in Finder reveals the file")
        (items.first { $0.title == "Copy Path" } as? ClosureMenuItem)?.handler?()
        T.expect(NSPasteboard.general.string(forType: .string) == file, "Copy Path copies the full path")
        T.expect(root.hitTest(root.convert(NSPoint(x: v.frame.midX, y: v.frame.midY), to: root.superview)) === v, "a click on the name reaches it")

        // screenshots, no dot; hover
        endCaret(ctx)
        await T.pause(0.3)
        T.expect(!v.dotShown && !v.dirty, "opened: no dot")
        T.screenshot(ctx, "file-name-window-\(appearance).png")
        shootCorner(ctx, "file-name-nodot-\(appearance).png")
        v.hovering = true
        v.display()
        shootCorner(ctx, "file-name-hover-\(appearance).png")
        v.hovering = false
        v.display()
        T.expect(same(f0, frames(ctx)), "hover moves nothing")

        // steady typing: every key is on disk before the next one (the real save delay), so no
        // dot ever shows, and nothing moves
        let words = " and one more thing"
        var delays: [Double] = [], dotSeen = 0, lastDisk = disk(file)
        for ch in words {
            let t = CACurrentMediaTime()
            T.type(ctx, String(ch))
            if let at = await T.waitFor(1.5, { disk(file) != lastDisk ? CACurrentMediaTime() : nil }) { delays.append((at - t) * 1000) }
            lastDisk = disk(file)
            for _ in 0..<6 {   // ~120 ms a key, like steady typing
                await T.pause(0.02)
                if v.dotShown || v.dot.opacity > 0 { dotSeen += 1 }
            }
        }
        let maxDelay = delays.max() ?? -1, mean = delays.isEmpty ? -1 : delays.reduce(0, +) / Double(delays.count)
        T.log(String(format: "save delay: %d keys, each on disk after %.1f ms on average, %.1f ms at most (polled every 20 ms)", delays.count, mean, maxDelay))
        T.expect(delays.count == words.count, "every key was written (\(delays.count) of \(words.count))")
        T.expect(maxDelay < 100, String(format: "each key reaches disk at once (%.1f ms at most)", maxDelay))
        let expected = ctx.model.editor.saveEngine.serializeForSave(frontmatter: ctx.model.editor.file(file)?.frontmatter, content: ctx.c.state.doc.string)
        T.expect(disk(file) == expected, "the file on disk holds the typed text")
        T.expect(dotSeen == 0, "steady typing shows no dot (the edits are on disk: \(dotSeen) samples with a dot)")
        let fTyped = frames(ctx)
        T.expect(same(f0, fTyped), "typing moved neither the name, the count, M↓ nor the page (\(describe(fTyped)))")

        // back to the original text (the typing was at the end)
        T.backspace(ctx, words.count)
        await T.pause(0.3)
        T.expect(T.diskBytes(file) == original && !v.dotShown, "the edits undone: the post is as it was, no dot")

        // a failed save: the dot, the name in red, the reason in the tooltip
        let dir = (file as NSString).deletingLastPathComponent
        chmod(dir, 0o555)
        endCaret(ctx)
        T.type(ctx, "x")
        let failed = await T.waitFor(2.5) { v.saveError != nil ? true : nil }
        T.expect(failed == true, "a save into a read-only folder fails")
        await T.pause(0.1)
        T.expect(v.dotShown && v.dot.opacity == 1, "unsaved edits: the dot shows")
        let d = v.dot.frame
        T.expect(abs(d.width - FileNameView.dotSize) < 0.01 && abs(d.height - FileNameView.dotSize) < 0.01, "the dot is 4 pt")
        T.expect(d.minX >= FileNameView.padX + v.shownWidth + 2 && d.maxX <= v.bounds.width && abs(d.midY - v.bounds.midY) <= 0.5,
                 String(format: "the dot sits right after the name, on its line (%.1f, text ends %.1f)", d.minX, FileNameView.padX + v.shownWidth))
        T.expect(v.style.color.isEqual(ctx.model.palette_.saveError), "save failed: the name turns red")
        T.expect(v.toolTip?.hasPrefix("Couldn’t save: ") == true && v.toolTip?.hasSuffix(short) == true, "save failed: the tooltip says why (\(v.toolTip?.replacingOccurrences(of: "\n", with: " | ") ?? "nil"))")
        let fErr = frames(ctx)
        T.expect(same(f0, fErr), "the dot and the red name moved nothing (\(describe(fErr)))")
        shootCorner(ctx, "file-name-error-\(appearance).png")
        // the dot alone (unsaved, no error yet): what a slow or pending write would show
        ctx.model.editor.setSaveError(file, nil)
        ctx.wc.flush()
        await T.pause(0.1)
        T.expect(v.dotShown && v.saveError == nil && v.style.color.isEqual(count.style.color), "unsaved, no error: the dot in the muted colour")
        T.screenshot(ctx, "file-name-dot-window-\(appearance).png")
        shootCorner(ctx, "file-name-dot-\(appearance).png")
        T.expect(same(f0, frames(ctx)), "the dot alone moved nothing")
        // the folder is writable again: the next key is written, then the dot fades
        chmod(dir, 0o755)
        let t1 = CACurrentMediaTime()
        T.backspace(ctx)
        var onDisk: CFTimeInterval?, gone: CFTimeInterval?
        while CACurrentMediaTime() - t1 < 2 {
            if onDisk == nil, T.diskBytes(file) == original { onDisk = CACurrentMediaTime() }
            if gone == nil, !v.dotShown { gone = CACurrentMediaTime() }
            if onDisk != nil && gone != nil { break }
            await T.pause(0.005)
        }
        if let a = onDisk, let b = gone {
            T.log(String(format: "save delay: after the failure, on disk after %.1f ms, the dot fades from %.1f ms (%.0f ms)", (a - t1) * 1000, (b - t1) * 1000, FileNameView.fade * 1000))
            T.expect(b >= a - 0.003, "the dot goes only once the save reached disk (the file was read)")
        } else { T.expect(false, "saved (\(onDisk != nil)) and the dot gone (\(gone != nil)) within 2 s") }
        await T.pause(0.3)
        T.expect(v.dot.presentation().map { $0.opacity < 0.01 } ?? (v.dot.opacity == 0), "the dot faded out")
        T.expect(v.saveError == nil && v.style.color.isEqual(count.style.color), "saved: the name is muted again")
        T.expect(same(f0, frames(ctx)), "the dot going moved nothing")

        // a long name truncates with … before the count (Rename, then back)
        let long = "a-very-long-file-name-for-a-letter-to-a-friend-about-the-garden-section-and-the-recipe-page-and-the-summary"
        guard let entry = WorkspaceFS.fileEntry(file, extensions: ctx.model.settings.supportedExtensions) else { T.expect(false, "file entry"); return }
        ctx.model.submitRename(entry, long)
        ctx.wc.flush()
        await relayout(ctx)
        let longPath = dir + "/" + long + ".md"
        T.expect(WorkspaceFS.isFile(longPath) && !WorkspaceFS.isFile(file), "Rename: the file moved")
        T.expect(v.name == long, "Rename: the name follows (\(v.name.prefix(20))…)")
        T.expect(w.title == long && w.representedURL?.path == longPath, "Rename: the window title and URL follow")
        let fLong = frames(ctx)
        T.expect(v.shownWidth + 1 < v.style.width(long), String(format: "a long name is truncated (%.0f of %.0f pt)", v.shownWidth, v.style.width(long)))
        T.expect(v.frame.maxX + 8 < fLong.countText[0], String(format: "the truncated name stops before the count (box ends %.1f, count starts %.1f)", v.frame.maxX, fLong.countText[0]))
        T.expect(fLong.count == f0.count && fLong.toggles == f0.toggles && abs(fLong.markdown.minX - f0.markdown.minX) <= tol && abs(fLong.name.minX - f0.name.minX) <= tol,
                 "a long name moves neither the count nor M↓ (\(describe(fLong)))")
        shootCorner(ctx, "file-name-long-\(appearance).png")
        if let back = WorkspaceFS.fileEntry(longPath, extensions: ctx.model.settings.supportedExtensions) { ctx.model.submitRename(back, stem) }
        ctx.wc.flush()
        await relayout(ctx)
        T.expect(WorkspaceFS.isFile(file) && v.name == stem, "renamed back")
        ctx.model.flushDirtyFiles()
        T.expect(T.diskBytes(file) == original, "the post ends as it was")
    }

    // MARK: file-name-full

    static func full(_ ctx: Ctx) async {
        let root = ctx.wc.root, w = ctx.wc.window!
        await relayout(ctx)
        await T.pause(0.4)
        T.expect(!ctx.model.isCompact && !root.tabs.isHidden, "workspace window: the tabs show")
        T.expect(root.flowriterName.isHidden, "workspace window: no name in the corner (the tab shows the title)")
        T.expect(w.representedURL?.path == ctx.file, "workspace window: representedURL is the file")
        T.screenshot(ctx, "file-name-full-\(appearance).png")
    }
}
