import AppKit
import FloCore

/// Flowriter: the default location for new notes (`--ui-selftest default-location|default-location-full <post> <out>`,
/// VM only; scripts/default-location-vm-test.sh).
///   default-location       the compact document window: with the setting on a temp folder, New Note shows
///                          "Create note in <folder>", the typed note lands in that folder (not next to the
///                          post) and opens; a name with a subfolder stays inside the folder; a missing
///                          folder falls back next to the post and says why, keeping the typed name; the
///                          Settings row (Files pane) is shot in the appearance under test.
///   default-location-full  the same in a workspace window (the folder lies outside the workspace).
/// Screenshots default-location-*-<appearance>.png. The post ends as it was.
@MainActor
enum DefaultLocationScenarios {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }
    /// Run in the writing space's document window (SelfTestRunner.run).
    static let names = ["default-location"]

    static func run(_ name: String, _ ctx: Ctx) async -> Bool {
        switch name {
        case "default-location": await scenario(ctx, compact: true)
        case "default-location-full": await scenario(ctx, compact: false)
        default: return false
        }
        return true
    }

    static func item(_ ctx: Ctx) -> ShellModel.PaletteView? { ctx.model.paletteView() }

    static func createViaPalette(_ ctx: Ctx, _ typed: String) -> ShellModel.PaletteView? {
        ctx.model.perform(.newNote)
        ctx.model.setPaletteQuery(typed)
        return item(ctx)
    }

    static func scenario(_ ctx: Ctx, compact: Bool) async {
        let kind = compact ? "compact" : "full"
        let m = ctx.model
        let original = T.diskBytes(ctx.file)
        let postDir = (ctx.file as NSString).deletingLastPathComponent
        let dest = (postDir as NSString).deletingLastPathComponent + "/default-location-notes"
        try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        T.expect(m.isCompact == compact, "\(kind) window")
        m.setSetting("files.default-note-location", .string(dest))

        // 1. the palette says where, the note lands there and opens
        var v = createViaPalette(ctx, "Default idea")
        T.expect(m.palette?.intent == .createFile, "\(kind): New Note opens the create palette")
        T.expect(v?.heading == "Create note in default-location-notes", "\(kind): heading names the folder (\(v?.heading ?? "nil"))")
        T.screenshot(ctx, "default-location-palette-\(kind)-\(appearance).png")
        if let first = v?.items.first { m.runPaletteItem(first) }
        let made = dest + "/Default idea.md"
        let landed = await T.waitFor(5) { WorkspaceFS.isFile(made) ? true : nil }
        T.expect(landed == true, "\(kind): the note landed in the default folder")
        T.expect(!WorkspaceFS.isFile(postDir + "/Default idea.md"), "\(kind): nothing next to the post")
        let opened = await T.waitFor(5) { m.editor.activeFilePath == made ? true : nil }
        T.expect(opened == true, "\(kind): the new note is open")

        // 2. a name with a subfolder stays inside the folder; ".." has no path
        v = createViaPalette(ctx, "drafts/second")
        if let first = v?.items.first { m.runPaletteItem(first) }
        let nested = await T.waitFor(5) { WorkspaceFS.isFile(dest + "/drafts/second.md") ? true : nil }
        T.expect(nested == true, "\(kind): drafts/second stays inside the default folder")
        v = createViaPalette(ctx, "../escape")
        T.expect(v?.items.isEmpty == true, "\(kind): a name with .. offers nothing")
        m.palette = nil

        // 3. a missing folder falls back and says why; the typed name stays
        let gone = dest + "-gone"
        m.setSetting("files.default-note-location", .string(gone))
        v = createViaPalette(ctx, "Fallback idea")
        let fallbackDir = compact ? (m.editor.activeFilePath.map(LinkPaths.getParentDir) ?? "") : (m.root ?? "")
        T.expect(v?.heading?.contains("is missing") == true, "\(kind): the reason shows (\(v?.heading ?? "nil"))")
        T.expect(v?.items.first?.kind == .create(fallbackDir + "/Fallback idea.md"), "\(kind): the typed name goes to today's folder")
        T.screenshot(ctx, "default-location-missing-\(kind)-\(appearance).png")
        m.palette = nil

        // 4. the Settings row
        if compact {
            m.setSetting("files.default-note-location", .string(dest))
            let backend = SettingsBackend(dataDir: m.dataDir)
            let wc = SettingsWindowController(backend: backend)
            let w = wc.window!
            w.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            wc.select("files")
            await T.pause(0.4)
            w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            let frameView = w.contentView!.superview!
            frameView.layoutSubtreeIfNeeded()
            frameView.display()
            let row = wc.selectedPane.control("files.note-locations")?.locations?.rows.first
            T.expect(row?.pathLabel.stringValue == NewNoteLocation.abbreviated(dest), "Settings row shows the path (\(row?.pathLabel.stringValue ?? "nil"))")
            T.expect(row?.marker.toolTip?.hasPrefix(L("Default location for new notes")) == true, "the row is marked as the default")
            let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let png = (ctx.out as NSString).appendingPathComponent("default-location-settings-\(appearance).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: png))
            T.expect(FileManager.default.fileExists(atPath: png), "Settings screenshot written")
            w.close()
        }
        m.flushDirtyFiles()
        T.expect(T.diskBytes(ctx.file) == original, "the post ends as it was")
    }
}
