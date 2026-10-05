import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// The destination chooser of the new-note palette: which location is current, cycling, the folder
/// the note goes in, the heading, the menu and the chip. No views except the NSMenu test.
@MainActor
final class PaletteDestinationTests: XCTestCase {
    func dest(locations: [NoteLocation], defaultPath: String = "", fallback: String? = "/tmp/fallback-ws",
              chosen: String? = nil) -> PaletteDestination {
        PaletteDestination(locations: locations, defaultPath: defaultPath, fallback: fallback, chosen: chosen)
    }

    func folder(_ name: String) -> String { TFS.tempDir(name) }

    func testDefaultSetAndUsable() {
        let work = folder("work")
        let d = dest(locations: [NoteLocation(nickname: "Work", path: work)], defaultPath: work)
        let r = d.resolve()
        XCTAssertEqual(r.directory, work)
        XCTAssertTrue(r.confined)
        XCTAssertEqual(r.current?.nickname, "Work")
        XCTAssertNil(r.notice)
        XCTAssertEqual(r.chip, PaletteDestination.Chip(name: "Work", tooltip: NewNoteLocation.abbreviated(work), hasMenu: true))
        XCTAssertEqual(d.heading(r), "Create note in Work")
        XCTAssertEqual(d.createPath(r, rawName: "Idea"), work + "/Idea.md")
    }

    func testDefaultWithoutNicknameShowsTheFolderName() {
        let work = folder("work")
        let r = dest(locations: [NoteLocation(path: work)], defaultPath: work).resolve()
        XCTAssertEqual(r.chip?.name, (work as NSString).lastPathComponent)
    }

    func testDefaultMissingFallsBackAndKeepsTheNotice() {
        let gone = folder("base") + "/gone"
        let ws = folder("ws")
        let d = dest(locations: [NoteLocation(path: gone)], defaultPath: gone, fallback: ws)
        let r = d.resolve()
        XCTAssertEqual(r.directory, ws)
        XCTAssertFalse(r.confined)
        XCTAssertNil(r.current)
        XCTAssertEqual(r.notice, "The default folder \"gone\" is missing. Using \((ws as NSString).lastPathComponent).")
        XCTAssertEqual(d.heading(r), r.notice)
        XCTAssertEqual(r.chip?.name, (ws as NSString).lastPathComponent, "the chip tells where the note really goes")
        XCTAssertEqual(r.chip?.hasMenu, true)
        XCTAssertEqual(d.createPath(r, rawName: "Idea"), ws + "/Idea.md")
    }

    func testNoLocationsShowsTheFallbackFolderAsALabel() {
        let ws = folder("ws")
        let d = dest(locations: [], fallback: ws)
        let r = d.resolve()
        XCTAssertEqual(r.directory, ws)
        XCTAssertEqual(r.chip, PaletteDestination.Chip(name: (ws as NSString).lastPathComponent,
                                                       tooltip: NewNoteLocation.abbreviated(ws), hasMenu: false))
        XCTAssertEqual(d.heading(r), "Create note")
        XCTAssertTrue(d.menuEntries(r).isEmpty)
        XCTAssertNil(d.cycled(from: r, by: 1))
        XCTAssertNil(d.cycled(from: r, by: -1))
    }

    func testNoLocationsAndNoFolderHasNoChip() {
        let r = dest(locations: [], fallback: nil).resolve()
        XCTAssertNil(r.directory)
        XCTAssertNil(r.chip)
        XCTAssertNil(dest(locations: [], fallback: nil).createPath(r, rawName: "Idea"))
    }

    func testLocationsWithoutADefaultKeepTodaysFolder() {
        let a = folder("a"), ws = folder("ws")
        let r = dest(locations: [NoteLocation(path: a)], fallback: ws).resolve()
        XCTAssertEqual(r.directory, ws)
        XCTAssertFalse(r.confined)
        XCTAssertEqual(r.chip?.hasMenu, true)
    }

    func testCycleWrapsBothWaysAndSkipsLocationsWithProblems() {
        let a = folder("a"), b = folder("b"), c = folder("c")
        let gone = folder("base") + "/gone"
        let locs = [NoteLocation(nickname: "A", path: a), NoteLocation(nickname: "Gone", path: gone),
                    NoteLocation(nickname: "B", path: b), NoteLocation(nickname: "C", path: c)]
        func current(_ chosen: String?) -> (PaletteDestination, PaletteDestination.Resolved) {
            let d = dest(locations: locs, defaultPath: a, chosen: chosen); return (d, d.resolve())
        }
        var (d, r) = current(nil)
        XCTAssertEqual(r.current?.nickname, "A")
        XCTAssertEqual(d.cycled(from: r, by: 1)?.nickname, "B", "the missing one is skipped")
        XCTAssertEqual(d.cycled(from: r, by: -1)?.nickname, "C", "back from the first wraps to the last")
        (d, r) = current(c)
        XCTAssertEqual(r.current?.nickname, "C")
        XCTAssertEqual(d.cycled(from: r, by: 1)?.nickname, "A", "forward from the last wraps to the first")
        XCTAssertEqual(d.cycled(from: r, by: -1)?.nickname, "B")
    }

    func testCycleFromTodaysFolder() {
        let a = folder("a"), b = folder("b"), ws = folder("ws")
        let d = dest(locations: [NoteLocation(nickname: "A", path: a), NoteLocation(nickname: "B", path: b)], fallback: ws)
        let r = d.resolve()
        XCTAssertNil(r.current)
        XCTAssertEqual(d.cycled(from: r, by: 1)?.nickname, "A")
        XCTAssertEqual(d.cycled(from: r, by: -1)?.nickname, "B")
    }

    func testOneLocationDoesNothingSpecial() {
        let a = folder("a")
        let d = dest(locations: [NoteLocation(path: a)], defaultPath: a)
        XCTAssertNil(d.cycled(from: d.resolve(), by: 1))
        XCTAssertNil(d.cycled(from: d.resolve(), by: -1))
    }

    func testAChosenLocationChangesTheCreatePathAndHeading() {
        let home = folder("home"), work = folder("work")
        let locs = [NoteLocation(nickname: "Home", path: home), NoteLocation(nickname: "Work", path: work)]
        let base = dest(locations: locs, defaultPath: home)
        XCTAssertEqual(base.createPath(base.resolve(), rawName: "Idea"), home + "/Idea.md")
        let d = dest(locations: locs, defaultPath: home, chosen: work)
        let r = d.resolve()
        XCTAssertEqual(r.directory, work)
        XCTAssertEqual(r.current?.nickname, "Work")
        XCTAssertEqual(r.chip?.name, "Work")
        XCTAssertEqual(d.heading(r), "Create note in Work")
        XCTAssertEqual(d.createPath(r, rawName: "drafts/Idea"), work + "/drafts/Idea.md")
    }

    func testAChosenLocationThatIsGoneOrUnknownIsIgnored() {
        let home = folder("home")
        let gone = folder("base") + "/gone"
        let locs = [NoteLocation(path: home), NoteLocation(path: gone)]
        XCTAssertEqual(dest(locations: locs, defaultPath: home, chosen: gone).resolve().directory, home)
        XCTAssertEqual(dest(locations: locs, defaultPath: home, chosen: "/not/listed").resolve().directory, home)
    }

    func testANameWithDotDotCannotLeaveTheFolder() {
        let home = folder("home"), work = folder("work")
        let locs = [NoteLocation(path: home), NoteLocation(path: work)]
        for chosen in [nil, work] as [String?] {
            let d = dest(locations: locs, defaultPath: home, chosen: chosen)
            let r = d.resolve()
            XCTAssertNil(d.createPath(r, rawName: "../escape"))
            XCTAssertNil(d.createPath(r, rawName: "a/../../escape"))
            XCTAssertNotNil(d.createPath(r, rawName: "a/b"))
        }
        // today's folder keeps its own (unconfined) rule from before locations existed
        let ws = folder("ws")
        let d = dest(locations: [], fallback: ws)
        XCTAssertEqual(d.createPath(d.resolve(), rawName: "a/b"), ws + "/a/b.md")
    }

    func testMenuEntries() {
        let home = folder("home"), work = folder("work"), ro = folder("ro")
        let gone = folder("base") + "/gone"
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro) }
        let locs = [NoteLocation(nickname: "Home", path: home), NoteLocation(nickname: "Work", path: work),
                    NoteLocation(nickname: "Gone", path: gone), NoteLocation(nickname: "Archive", path: ro)]
        let d = dest(locations: locs, defaultPath: home, chosen: work)
        let e = d.menuEntries(d.resolve())
        XCTAssertEqual(e.map(\.title), ["Home (Default)", "Work", "Gone (Folder missing)", "Archive (Read-only)"])
        XCTAssertEqual(e.map(\.checked), [false, true, false, false])
        XCTAssertEqual(e.map(\.isDefault), [true, false, false, false])
        XCTAssertEqual(e.map(\.enabled), [true, true, false, false])
        XCTAssertEqual(e.map(\.tooltip), locs.map(\.fullPath))
        XCTAssertEqual(e.map(\.path), locs.map(\.normalizedPath))
    }

    func testTheNSMenuHasTitlesTooltipsCheckAndDisabledRows() {
        let home = folder("home"), work = folder("work")
        let gone = folder("base") + "/gone"
        let locs = [NoteLocation(nickname: "Home", path: home), NoteLocation(nickname: "Work", path: work),
                    NoteLocation(nickname: "Gone", path: gone)]
        let d = dest(locations: locs, defaultPath: home, chosen: work)
        let target = NSObject()
        let menu = PaletteDestinationChip.makeMenu(d.menuEntries(d.resolve()), target: target, action: #selector(NSObject.description))
        XCTAssertEqual(menu.items.map(\.title), ["Home (Default)", "Work", "Gone (Folder missing)"])
        XCTAssertEqual(menu.items.map(\.toolTip), locs.map(\.fullPath))
        XCTAssertEqual(menu.items.map { $0.state == .on }, [false, true, false])
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, true, false])
        XCTAssertEqual(menu.items.map { $0.representedObject as? String }, locs.map(\.normalizedPath))
        XCTAssertTrue(menu.items.allSatisfy { $0.target === target })
    }

    // MARK: the model

    func twoLocations(_ f: ShellFixture) -> (home: String, work: String) {
        let home = folder("home"), work = folder("work")
        f.model.setSetting("files.note-locations", .list(["Home|\(home)", "Work|\(work)"]))
        f.model.setSetting("files.default-note-location", .string(home))
        return (home, work)
    }

    func testTabCyclesTheDestinationForThisPaletteOnly() async {
        let f = ShellFixture(files: ["a.md": "x"])
        let (home, work) = twoLocations(f)
        await f.open()
        f.model.palette = PaletteState(intent: .createFile, query: "Idea")
        XCTAssertEqual(f.model.paletteView()?.destination?.name, "Home")
        XCTAssertTrue(f.model.cyclePaletteDestination(1))
        var v = f.model.paletteView()!
        XCTAssertEqual(v.destination?.name, "Work")
        XCTAssertEqual(v.heading, "Create note in Work")
        XCTAssertEqual(v.items.first?.kind, .create(work + "/Idea.md"))
        XCTAssertTrue(f.model.cyclePaletteDestination(1))
        XCTAssertEqual(f.model.paletteView()?.destination?.name, "Home", "wraps")
        XCTAssertTrue(f.model.cyclePaletteDestination(-1))
        XCTAssertEqual(f.model.paletteView()?.destination?.name, "Work", "Shift-Tab goes back")
        XCTAssertEqual(f.model.values.filesDefaultNoteLocation, home, "the default setting is not touched")
        // typing keeps the choice; closing and reopening resets it
        f.model.setPaletteQuery("Other")
        v = f.model.paletteView()!
        XCTAssertEqual(v.items.first?.kind, .create(work + "/Other.md"))
        f.model.palette = nil
        f.model.perform(.newNote)
        XCTAssertEqual(f.model.paletteView()?.destination?.name, "Home")
    }

    func testChoosingFromTheMenuAndCreating() async {
        let f = ShellFixture(files: ["a.md": "x"])
        let (home, work) = twoLocations(f)
        await f.open()
        f.model.palette = PaletteState(intent: .createFile, query: "Idea")
        f.model.chooseDestination(NoteLocation(path: work).normalizedPath)
        f.model.runPaletteItem(f.model.paletteView()!.items[0])
        for _ in 0..<100 where !TFS.exists(work + "/Idea.md") { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(TFS.exists(work + "/Idea.md"))
        XCTAssertFalse(TFS.exists(home + "/Idea.md"))
        XCTAssertNil(f.model.palette, "the palette closed")
    }

    func testTabWithOneOrNoLocationDoesNothing() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open()
        f.model.palette = PaletteState(intent: .createFile, query: "Idea")
        XCTAssertFalse(f.model.cyclePaletteDestination(1), "no locations")
        XCTAssertEqual(f.model.paletteView()?.destination?.name, (f.root as NSString).lastPathComponent)
        XCTAssertEqual(f.model.paletteView()?.destination?.hasMenu, false)
        let only = folder("only")
        f.model.setSetting("files.default-note-location", .string(only))
        XCTAssertFalse(f.model.cyclePaletteDestination(-1), "one location")
        XCTAssertNil(f.model.palette?.destination)
    }

    func testOtherPalettesHaveNoChipAndNoTab() async {
        let f = ShellFixture(files: ["a.md": "x"])
        _ = twoLocations(f)
        await f.open()
        for intent in [PaletteState.Intent.search, .recent, .fullText] {
            f.model.palette = PaletteState(intent: intent)
            XCTAssertNil(f.model.paletteView()?.destination, "\(intent)")
            XCTAssertFalse(f.model.cyclePaletteDestination(1), "\(intent)")
            f.model.chooseDestination("/x")
            XCTAssertNil(f.model.palette?.destination, "\(intent)")
        }
    }

    func testTheChipSitsInTheNewNoteInputOnlyAndShrinksTheField() async {
        let f = ShellFixture(files: ["a.md": "x"])
        let (home, _) = twoLocations(f)
        await f.open()
        let overlay = PaletteOverlayView(model: f.model)
        overlay.frame = NSRect(x: 0, y: 0, width: 760, height: 330)
        f.model.palette = PaletteState(intent: .recent)
        overlay.reload(resetField: true); overlay.layoutSubtreeIfNeeded()
        let fullWidth = overlay.input.frame.width
        XCTAssertTrue(overlay.chip.isHidden)
        XCTAssertNil(overlay.dump()?["destination"] as? [String: Any])
        f.model.palette = PaletteState(intent: .createFile, query: "Idea")
        overlay.reload(resetField: true); overlay.layoutSubtreeIfNeeded()
        XCTAssertFalse(overlay.chip.isHidden)
        XCTAssertEqual(overlay.chip.toolTip, NewNoteLocation.abbreviated(home), "hover shows the full path")
        XCTAssertTrue(overlay.input.frame.width < fullWidth)
        XCTAssertTrue(overlay.input.frame.maxX <= overlay.chip.frame.minX, "the field ends before the chip")
        let d = overlay.dump()?["destination"] as? [String: Any]
        XCTAssertEqual(d?["name"] as? String, "Home")
        XCTAssertEqual(d?["menu"] as? Bool, true)
        let menu = overlay.destinationMenu()
        XCTAssertEqual(menu?.items.map(\.title), ["Home (Default)", "Work"])
        XCTAssertEqual(menu?.items.map { $0.state == .on }, [true, false])
    }

    func testMissingDefaultStillShowsTheNoticeAndTheFallbackChip() async {
        let f = ShellFixture(files: ["a.md": "x"])
        let gone = folder("base") + "/gone"
        f.model.setSetting("files.default-note-location", .string(gone))
        await f.open()
        f.model.palette = PaletteState(intent: .createFile)
        let v = f.model.paletteView()!
        XCTAssertEqual(v.empty, "The default folder \"gone\" is missing. Using \((f.root as NSString).lastPathComponent).")
        XCTAssertEqual(v.destination?.name, (f.root as NSString).lastPathComponent)
    }
}
