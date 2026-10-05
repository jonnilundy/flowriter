import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// The native Settings window, offscreen (never ordered front).
@MainActor
final class SettingsWindowTests: XCTestCase {
    var data: String!
    var backend: SettingsBackend!
    var wc: SettingsWindowController!
    var changes = 0

    override func setUp() async throws {
        data = TFS.tempDir("settings")
        TFS.write(data + "/config", "editor.font-size = 18\n")
        backend = SettingsBackend(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        backend.onChange = { [unowned self] in self.changes += 1 }
        wc = SettingsWindowController(backend: backend)
        wc.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    }

    override func tearDown() async throws { wc.window?.close() }

    var config: String { TFS.read(data + "/config") ?? "" }

    func pane(_ id: String) -> SettingsPaneController {
        wc.select(id)
        let p = wc.selectedPane
        _ = p.view
        return p
    }

    func testWindowShapeToolbarAndTitles() {
        let w = wc.window!
        XCTAssertFalse(w.styleMask.contains(.resizable))
        XCTAssertTrue(w.styleMask.contains(.titled) && w.styleMask.contains(.closable))
        XCTAssertEqual(w.toolbarStyle, .preference)
        XCTAssertEqual(w.toolbar?.items.map { $0.label }, ["General", "Editor", "Theme", "Files"])
        XCTAssertEqual(SettingsPanes.all.map { $0.id }, ["general", "editor", "theme", "files"])
        XCTAssertNil(w.appearance, "follows the system light/dark")
        for p in SettingsPanes.all {
            wc.select(p.id)
            XCTAssertEqual(w.title, p.title)
        }
    }

    func testWindowFitsEachPane() {
        var heights: [CGFloat] = []
        for p in SettingsPanes.all {
            let vc = pane(p.id)
            wc.resizeToPane(animate: false)
            XCTAssertEqual(wc.window!.contentView!.frame.height, vc.preferredContentSize.height, accuracy: 1, p.id)
            heights.append(vc.preferredContentSize.height)
            XCTAssertLessThan(vc.preferredContentSize.height, 700, "\(p.id) fits a laptop screen")
        }
        XCTAssertGreaterThan(Set(heights).count, 2, "panes resize the window")
    }

    func testEverySettingHasANativeControl() {
        var seen: [String] = []
        for p in SettingsPanes.all {
            let vc = pane(p.id)
            for c in vc.controls {
                seen.append(c.def.key)
                switch c.def.type {
                case .boolean: XCTAssertNotNil(c.checkbox, c.def.key)
                case .enum, .font: XCTAssertNotNil(c.popup, c.def.key)
                case .number: XCTAssertNotNil(c.stepper, c.def.key); XCTAssertNotNil(c.field)
                case .color: XCTAssertNotNil(c.well, c.def.key)
                case .range: XCTAssertNotNil(c.slider, c.def.key)
                case .list: XCTAssertTrue(c.tokens != nil || c.locations != nil, c.def.key)
                case .string: XCTAssertTrue(c.field != nil || c.popup != nil, c.def.key)
                }
            }
        }
        XCTAssertEqual(Set(seen), Set(SettingsSchema.all.map { $0.key }).subtracting(SettingsPanes.hiddenKeys))
    }

    func testCheckboxWritesConfigAndBroadcasts() {
        let c = pane("editor").control("editor.show-outline")!
        XCTAssertEqual(c.checkbox?.state, .on)
        c.checkbox!.state = .off
        c.changed(c.checkbox)
        XCTAssertTrue(config.contains("editor.show-outline = false"))
        XCTAssertEqual(changes, 1)
    }

    /// Settings for workspace windows only, and the ones that did nothing, have no control.
    func testWorkspaceOnlyAndRemovedSettingsHaveNoControl() {
        for p in SettingsPanes.all { _ = pane(p.id) }
        let shown = Set(SettingsPanes.allKeys)
        for key in ["appearance.sidebar-file-label", "appearance.sidebar-show-search", "appearance.sidebar-show-recents",
                    "fonts.mono", "window.restore-workspace", "workspace.restore-open-files"] {
            XCTAssertNotNil(SettingsSchema.def(key), "\(key) is still a setting")
            XCTAssertTrue(SettingsPanes.hiddenKeys.contains(key), key)
            XCTAssertFalse(shown.contains(key), key)
        }
        XCTAssertTrue(pane("editor").controls.contains { $0.def.key == "fonts.editor" }, "the font moved to the Editor pane")
    }

    func testStepperAndFieldForNumbers() {
        let c = pane("editor").control("editor.font-size")!
        XCTAssertEqual(c.field?.doubleValue, 18, "reads the existing config")
        XCTAssertEqual(c.stepper?.maxValue, 32)
        c.stepper!.doubleValue = 19
        c.stepped(c.stepper!)
        XCTAssertEqual(c.field?.doubleValue, 19)
        XCTAssertTrue(config.contains("editor.font-size = 19"))
        c.field!.stringValue = "21"
        c.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.field))
        XCTAssertTrue(config.contains("editor.font-size = 21"))
    }

    func testPopupsColorWellsSlidersAndTokens() {
        let theme = pane("general").control("appearance.theme")!
        XCTAssertEqual(theme.popup?.itemTitles, ["Match System", "Light", "Dark"])
        theme.popup!.selectItem(at: 2)
        theme.changed(theme.popup)
        XCTAssertTrue(config.contains("appearance.theme = dark"))

        let t = pane("theme")
        XCTAssertNil(t.control("theme.light.accent"), "accent colour is the system's, not a setting")
        let bg = t.control("theme.light.background")!
        bg.well!.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        bg.changed(bg.well)
        XCTAssertTrue(config.contains("theme.light.background = #FF0000"))
        XCTAssertEqual(t.control("theme.light.preset")!.popup?.titleOfSelectedItem, "Custom", "no preset matches now")
        let slider = t.control("theme.dark.translucent")!
        slider.slider!.doubleValue = 42.4
        slider.changed(slider.slider)
        XCTAssertTrue(config.contains("theme.dark.translucent = 42"))
        XCTAssertEqual(slider.sliderValue?.stringValue, "42")

        let files = pane("files").control("files.associations")!
        files.tokens!.objectValue = ["*.md", "*.txt"]
        files.commitTokens()
        XCTAssertTrue(config.contains("files.associations = *.md\nfiles.associations = *.txt"))

        let font = pane("editor").control("fonts.editor")!
        font.popup!.selectItem(withTitle: "Menlo")
        font.changed(font.popup)
        XCTAssertTrue(config.contains("fonts.editor = Menlo, -apple-system-body"), config)
    }

    func testPresetAppliesPrimaries() {
        let t = pane("theme")
        let preset = t.control("theme.dark.preset")!
        guard let other = ThemePreset.all.first(where: { $0.name != "Writer" }) else { return }
        preset.popup!.selectItem(withTitle: other.name)
        preset.changed(preset.popup)
        XCTAssertEqual(backend.values.themeAccent(.dark), other.dark.accent)
        XCTAssertEqual(backend.values.themeContrast(.dark), other.dark.contrast)
        wc.syncAll()
        XCTAssertEqual(preset.popup?.titleOfSelectedItem, other.name)
    }

    func testRestoreDefaultsResetsOnlyThatPane() {
        let editor = pane("editor")
        let general = pane("general")
        general.control("editor.auto-insert-daily-heading")!.checkbox!.state = .off
        general.control("editor.auto-insert-daily-heading")!.changed(nil)
        editor.restoreDefaults()
        XCTAssertFalse(config.contains("editor.font-size"))
        XCTAssertTrue(config.contains("editor.auto-insert-daily-heading = false"))
        XCTAssertEqual(editor.control("editor.font-size")?.field?.doubleValue, 16)
    }

    func testExternalChangesSync() {
        let c = pane("editor").control("editor.show-outline")!
        XCTAssertEqual(c.checkbox?.state, .on)
        TFS.write(data + "/config", "editor.show-outline = false\n")
        backend.reloadFromDisk()
        wc.syncAll()
        XCTAssertEqual(c.checkbox?.state, .off)
    }
}

/// App-level wiring: one reusable window; changes reach every workspace window.
@MainActor
final class SettingsBroadcastTests: XCTestCase {
    func testSettingsWindowChangesReachOpenWindows() async {
        let f = ShellFixture(files: ["a.md": ""])
        await f.open()
        let app = AppDelegate(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: f.data)), launchPaths: [])
        let backend = SettingsBackend(dataDir: f.model.dataDir)
        let wc = SettingsWindowController(backend: backend)
        backend.onChange = { app.settingsChanged(from: nil) }
        app.adopt(model: f.model)
        let c = wc.panes.first { $0.pane.id == "editor" }!
        _ = c.view
        c.control("editor.font-size")!.stepper!.doubleValue = 20
        c.control("editor.font-size")!.stepped(c.control("editor.font-size")!.stepper!)
        XCTAssertEqual(f.model.values.editorFontSize, 20, "open windows pick it up live")
        wc.window?.close()
    }
}

/// The Writing locations editor in the Files pane (it replaced the single default folder row).
@MainActor
final class DefaultLocationSettingTests: XCTestCase {
    var data: String!
    var backend: SettingsBackend!
    var wc: SettingsWindowController!

    override func setUp() async throws {
        data = TFS.tempDir("settings")
        backend = SettingsBackend(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        wc = SettingsWindowController(backend: backend)
        wc.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        wc.select("files")
    }

    override func tearDown() async throws { wc.window?.close() }

    var control: SettingControl { wc.selectedPane.control("files.note-locations")! }
    var editor: LocationsEditorView { control.locations! }
    var config: String { TFS.read(data + "/config") ?? "" }

    func testTheOldFolderRowIsGone() {
        XCTAssertNil(wc.selectedPane.control("files.default-note-location"), "the default is the marker on a row")
        XCTAssertTrue(SettingsPanes.hiddenKeys.contains("files.default-note-location"))
        XCTAssertEqual(wc.selectedPane.keys, ["files.note-locations", "files.associations"])
    }

    func testAddMarkDefaultAndRemove() {
        XCTAssertTrue(editor.rows.isEmpty)
        XCTAssertFalse(editor.emptyLabel.isHidden, "Not set")
        let folder = TFS.tempDir("notes")
        var asked: String?
        control.pickFolder = { asked = $0; return folder + "/" }
        editor.addButton.performClick(nil)
        XCTAssertEqual(asked, "")
        XCTAssertEqual(backend.values.noteLocations.map(\.path), [folder])
        XCTAssertEqual(editor.rows.count, 1)
        XCTAssertTrue(editor.emptyLabel.isHidden)
        XCTAssertEqual(editor.rows[0].pathLabel.stringValue, NewNoteLocation.abbreviated(folder))
        XCTAssertEqual(editor.rows[0].pathLabel.toolTip, NewNoteLocation.abbreviated(folder), "the full path")
        XCTAssertNil(backend.values.defaultNoteLocation, "adding a folder does not make it the default")

        control.pickFolder = { _ in folder }   // the same folder again: not added twice
        editor.addButton.performClick(nil)
        XCTAssertEqual(editor.rows.count, 1)
        control.pickFolder = { _ in nil }   // cancelled: nothing changes
        editor.addButton.performClick(nil)
        XCTAssertEqual(backend.values.noteLocations.count, 1)

        editor.rows[0].marker.performClick(nil)
        XCTAssertEqual(backend.values.filesDefaultNoteLocation, folder)
        XCTAssertTrue(editor.rows[0].marker.toolTip?.hasPrefix("Default location") == true)
        editor.rows[0].marker.performClick(nil)   // click the default again: no default
        XCTAssertEqual(backend.values.filesDefaultNoteLocation, "")
        XCTAssertFalse(config.contains("default-note-location"))

        editor.rows[0].marker.performClick(nil)
        editor.rows[0].removeButton.performClick(nil)
        XCTAssertTrue(editor.rows.isEmpty)
        XCTAssertEqual(backend.values.filesDefaultNoteLocation, "", "removing the default clears it")
        XCTAssertFalse(config.contains("note-locations"), "an empty list is reset, not stored")
        XCTAssertFalse(editor.emptyLabel.isHidden)
    }

    func testChangeKeepsNicknameAndDefault() {
        let a = TFS.tempDir("a"), b = TFS.tempDir("b")
        backend.setMany([("files.note-locations", .list(["Journal|\(a)"])), ("files.default-note-location", .string(a))])
        wc.syncAll()
        XCTAssertTrue(editor.rows[0].marker.toolTip?.hasPrefix("Default location") == true)
        control.pickFolder = { _ in b }
        editor.rows[0].changeButton.performClick(nil)
        XCTAssertEqual(backend.values.noteLocations.map(\.encoded), ["Journal|\(b)"])
        XCTAssertEqual(backend.values.filesDefaultNoteLocation, b, "the default follows its folder")
    }

    func testNicknameCommitsOnEndEditingOnly() {
        let a = TFS.tempDir("a")
        backend.setMany([("files.note-locations", .list(["|\(a)"]))])
        wc.syncAll()
        let row = editor.rows[0]
        XCTAssertEqual(row.nickname.placeholderString, (a as NSString).lastPathComponent)
        row.nickname.stringValue = "Journal | daily "
        XCTAssertEqual(backend.values.noteLocations[0].nickname, "", "typing alone stores nothing")
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: row.nickname))
        XCTAssertEqual(backend.values.noteLocations[0].nickname, "Journal / daily")
        XCTAssertTrue(editor.rows[0] === row, "the row (and its focus) stays")
        XCTAssertEqual(row.nickname.stringValue, "Journal / daily")
    }

    func testDefaultSetBeforeTheListIsEditedIntoTheList() {
        let a = TFS.tempDir("a")
        backend.setMany([("files.default-note-location", .string(a))])   // the old single-folder setting
        wc.syncAll()
        XCTAssertEqual(editor.rows.count, 1, "shown as a location named after its folder")
        XCTAssertFalse(config.contains("note-locations"))
        let row = editor.rows[0]
        row.nickname.stringValue = "Drafts"
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: row.nickname))
        XCTAssertEqual(backend.values.filesNoteLocationLines, ["Drafts|\(a)"])
        XCTAssertEqual(backend.values.filesDefaultNoteLocation, a)
    }

    func testMissingFolderShowsWhy() {
        let gone = TFS.tempDir("a") + "/gone"
        backend.setMany([("files.note-locations", .list(["Ghost|\(gone)"]))])
        wc.syncAll()
        let row = editor.rows[0]
        XCTAssertEqual(row.pathLabel.textColor, .systemOrange)
        XCTAssertEqual(row.pathLabel.toolTip, "The folder \"\(NewNoteLocation.abbreviated(gone))\" is missing.")
        XCTAssertEqual(row.nickname.toolTip, row.pathLabel.toolTip)
    }

    func testRestoreDefaultsClearsLocationsAndDefault() {
        let a = TFS.tempDir("a")
        backend.setMany([("files.note-locations", .list(["Journal|\(a)"])), ("files.default-note-location", .string(a))])
        wc.syncAll()
        wc.selectedPane.restoreDefaults()
        XCTAssertTrue(backend.values.noteLocations.isEmpty)
        XCTAssertEqual(backend.values.filesDefaultNoteLocation, "")
        XCTAssertTrue(editor.rows.isEmpty)
    }
}


/// The Files pane layout: nothing clipped at the window's width, one left edge, aligned baselines,
/// even rows. Offscreen: the window is never ordered front.
@MainActor
final class SettingsLayoutTests: XCTestCase {
    var data: String!
    var backend: SettingsBackend!
    var wc: SettingsWindowController!

    override func setUp() async throws {
        data = TFS.tempDir("settings")
        backend = SettingsBackend(dataDir: AppDataDirectory(baseURL: URL(fileURLWithPath: data)))
        wc = SettingsWindowController(backend: backend)
        wc.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        wc.select("files")
    }

    override func tearDown() async throws { wc.window?.close() }

    var pane: SettingsPaneController { wc.selectedPane }
    var content: NSView { wc.window!.contentView! }
    var control: SettingControl { pane.control("files.note-locations")! }
    var editor: LocationsEditorView { control.locations! }
    var tokens: NSView { pane.control("files.associations")!.view }
    var help: NSView { pane.control("files.associations")!.help! }

    func set(_ lines: [String], default d: String = "") {
        backend.setMany([("files.note-locations", .list(lines)), ("files.default-note-location", .string(d))])
        content.layoutSubtreeIfNeeded()
    }

    func longFolder() -> String {
        let p = TFS.tempDir("long") + "/some-long-folder-name/writing/drafts"
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }

    /// Every visible control of the pane that leaves the window's content view (or sits partly outside it).
    func clipped() -> [String] {
        let box = content.bounds
        return views(pane.view).compactMap { v in
            guard v is NSControl, !v.isHiddenOrHasHiddenAncestor else { return nil }
            let r = v.convert(v.bounds, to: content)
            return box.insetBy(dx: -0.5, dy: -0.5).contains(r) ? nil : "\(type(of: v)) \(r)"
        }
    }

    /// The left edge of a view's alignment rect, in the pane's coordinates.
    func left(_ v: NSView) -> CGFloat {
        guard let s = v.superview else { return v.frame.minX }
        return s.convert(v.alignmentRect(forFrame: v.frame), to: pane.view).minX
    }

    func right(_ v: NSView) -> CGFloat {
        guard let s = v.superview else { return v.frame.maxX }
        return s.convert(v.alignmentRect(forFrame: v.frame), to: pane.view).maxX
    }

    /// The first baseline's height from the top of the pane (the pane's view is not flipped).
    func baseline(_ v: NSView) -> CGFloat {
        pane.view.bounds.height - (v.convert(v.bounds, to: pane.view).maxY - v.firstBaselineOffsetFromTop)
    }

    func assertFits(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(clipped(), [], what, file: file, line: line)
        XCTAssertEqual(content.frame.width, pane.preferredContentSize.width, accuracy: 1, "\(what): the window is as wide as the pane", file: file, line: line)
        XCTAssertEqual(content.frame.height, pane.preferredContentSize.height, accuracy: 1, "\(what): the window is as tall as the pane", file: file, line: line)
    }

    func testNothingClipsInAnyCaseLightOrDark() {
        let nick = "A very very long nickname that goes on and on"
        let long = longFolder()
        let cases: [(String, [String], String)] = [
            ("empty", [], ""),
            ("long path", ["drafts|\(long)"], long),
            ("three", ["Drafts|\(TFS.tempDir("a"))", "Journal|\(TFS.tempDir("b"))", "Work|\(TFS.tempDir("c"))"], ""),
            ("long nickname", ["\(nick)|\(long)"], ""),
            ("empty again", [], ""),
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            wc.window!.appearance = NSAppearance(named: name)
            for (what, lines, d) in cases {
                set(lines, default: d)
                assertFits("\(what) (\(name.rawValue))")
                XCTAssertFalse(clipped().contains { $0.hasPrefix("NSButton") }, "Change… and the remove button are whole: \(what)")
            }
        }
        XCTAssertGreaterThan(pane.restoreButton.frame.width, 0)
        XCTAssertTrue(content.bounds.contains(pane.restoreButton.convert(pane.restoreButton.bounds, to: content)), "Restore Defaults is whole")
    }

    func testTheWindowGrowsWhenALocationIsAddedOnTheFilesPane() {
        let emptyWidth = content.frame.width
        let emptyHeight = content.frame.height
        set(["drafts|\(longFolder())"])
        XCTAssertGreaterThan(content.frame.height, emptyHeight - 1)
        assertFits("one location added")
        set(["a|\(TFS.tempDir("a"))", "b|\(TFS.tempDir("b"))", "c|\(TFS.tempDir("c"))"])
        assertFits("three")
        XCTAssertEqual(content.frame.width, emptyWidth, accuracy: 1, "the editor keeps one width: rows do not change the window width")
        set([])
        assertFits("back to none")
    }

    func testThePathIsTheFlexiblePart() {
        let short = TFS.tempDir("s")
        set(["a|\(short)"])
        let row = editor.rows[0]
        let widthsShort = (row.nickname.frame.width, row.changeButton.frame.width, row.removeButton.frame.width, content.frame.width)
        XCTAssertLessThan(row.pathLabel.contentCompressionResistancePriority(for: .horizontal).rawValue, 50, "gives way before anything else, even when fitting")
        XCTAssertEqual(row.pathLabel.lineBreakMode, .byTruncatingMiddle)

        let long = longFolder()
        set(["a|\(long)"])
        let r = editor.rows[0]
        XCTAssertEqual(r.pathLabel.stringValue, NewNoteLocation.abbreviated(long))
        XCTAssertEqual(r.pathLabel.toolTip, NewNoteLocation.abbreviated(long), "the tooltip keeps the full path")
        XCTAssertEqual(r.nickname.frame.width, widthsShort.0, accuracy: 0.5, "the nickname field keeps its width")
        XCTAssertEqual(r.changeButton.frame.width, widthsShort.1, accuracy: 0.5, "Change… keeps its width")
        XCTAssertEqual(r.removeButton.frame.width, widthsShort.2, accuracy: 0.5, "remove keeps its width")
        XCTAssertEqual(content.frame.width, widthsShort.3, accuracy: 1, "a long path does not widen the pane")
        XCTAssertGreaterThanOrEqual(r.pathLabel.frame.width, LocationRowView.pathMinWidth)
        XCTAssertGreaterThan((r.pathLabel.stringValue as NSString).size(withAttributes: [.font: r.pathLabel.font!]).width, r.pathLabel.frame.width, "the long path is cut, not shown whole")
    }

    /// The window is not user-resizable, but its frame can still be set (a restored frame, a later change).
    /// The pane's constraints give the window a floor: it never gets narrower than the pane needs, so
    /// no control is ever cut off, and a wider window keeps the pane at its width.
    func testSettingTheWindowSizeByHandNeverClips() {
        set(["drafts|\(longFolder())"])
        let fitted = pane.preferredContentSize
        let w = wc.window!
        for target in [fitted.width - 100, fitted.width + 200, fitted.width] {
            w.setContentSize(NSSize(width: target, height: fitted.height))
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(clipped(), [], "nothing clipped after asking for \(target) pt")
            XCTAssertGreaterThanOrEqual(content.frame.width, fitted.width - 0.5, "never narrower than the pane needs (asked \(target))")
            let r = editor.rows[0]
            XCTAssertEqual(r.nickname.frame.width, LocationRowView.nicknameWidth, accuracy: 0.5, "fixed width at \(target)")
            XCTAssertGreaterThanOrEqual(r.pathLabel.frame.width, LocationRowView.pathMinWidth - 0.5, "at \(target)")
        }
        wc.resizeToPane(animate: false)
        assertFits("fitted again")
    }

    func testOneLeftEdgeEvenRowsAndAlignedBaselines() {
        let a = TFS.tempDir("a"), b = TFS.tempDir("b"), c = TFS.tempDir("c")
        for lines in [[], ["Drafts|\(a)", "Journal|\(b)", "Work|\(c)"]] {
            set(lines, default: b)
            let rows = editor.rows
            let edge = left(editor.addButton)
            XCTAssertEqual(left(tokens), edge, accuracy: 0.5, "the File associations box starts at the Add Location… edge (\(lines.count) rows)")
            XCTAssertEqual(left(editor), edge, accuracy: 0.5)
            XCTAssertEqual(left(help) + 2, edge, accuracy: 2.5, "the help text starts at that edge too (a label's text has 2 pt of inset)")
            for r in rows { XCTAssertEqual(left(r.marker), edge, accuracy: 0.5, "the marker column starts there") }
            // the right edges: the last control of a row and the File associations box
            for r in rows { XCTAssertEqual(right(r.removeButton), right(tokens), accuracy: 0.5, "rows end where the box ends") }
            XCTAssertEqual(right(editor), right(tokens), accuracy: 0.5)
            // labels: one column, right-aligned
            XCTAssertEqual(right(control.label), right(pane.control("files.associations")!.label), accuracy: 0.5, "the label column is right-aligned")
            // the first row's baseline is the label's baseline
            let first: NSView = rows.first?.nickname ?? editor.emptyLabel
            XCTAssertEqual(baseline(control.label), baseline(first), accuracy: 0.5, "label baseline = first row baseline (\(lines.count) rows)")
            // rows: one height, one gap, the same gap above Add Location…
            if rows.count > 1 {
                XCTAssertEqual(Set(rows.map { $0.frame.height.rounded() }).count, 1, "one row height")
                let gaps = zip(rows, rows.dropFirst()).map { $0.frame.minY - $1.frame.maxY }   // not flipped: the next row is lower
                XCTAssertEqual(Set(gaps.map { $0.rounded() }).count, 1, "one gap between rows \(gaps)")
                XCTAssertEqual(rows.last!.frame.minY - editor.addButton.frame.maxY, gaps[0], accuracy: 0.5, "Add Location… sits one gap below the last row")
                XCTAssertEqual(gaps[0], LocationsEditorView.rowGap, accuracy: 0.5)
            }
        }
    }

    func testTheWindowGrowsAroundItsCentreAndKeepsItsTop() {
        wc.select("general")
        let w = wc.window!
        let before = w.frame
        wc.select("files")
        let after = w.frame
        XCTAssertNotEqual(before.width, after.width)
        XCTAssertEqual(after.midX, before.midX, accuracy: 1, "grows around the centre line")
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 1, "the top edge stays")
    }

    func testEveryPaneKeepsTheSameGridMargins() {
        // every pane lays out one NSGridView: at least 30 pt from the sides (centred when the pane is wider), 22 pt from the top
        for p in SettingsPanes.all {
            wc.select(p.id)
            let v = wc.selectedPane.view
            let grid = views(v).compactMap { $0 as? NSGridView }.first!
            XCTAssertGreaterThanOrEqual(grid.frame.minX, 29.5, "\(p.id): left margin")
            XCTAssertGreaterThanOrEqual(v.bounds.width - grid.frame.maxX, 29.5, "\(p.id): right margin")
            XCTAssertEqual(v.bounds.height - grid.frame.maxY, 22, accuracy: 0.5, "\(p.id): top margin")
            XCTAssertEqual(grid.rowSpacing, 8, "\(p.id)")
            XCTAssertEqual(grid.columnSpacing, 10, "\(p.id)")
        }
    }
}
