import XCTest
@testable import FloCore
@testable import FloStateNative

/// Flowriter Overflow: the text logic and the sidecar round trip (the window is covered by the VM scenarios).
final class OverflowTests: XCTestCase {
    func testSplitAndJoinAreInverse() {
        let text = "one\nstill one\n\ntwo\n\n\n\nthree  \n"
        XCTAssertEqual(OverflowItems.split(text), ["one\nstill one", "two", "three"])
        XCTAssertEqual(OverflowItems.join(["a", "b c"]), "a\n\nb c")
        XCTAssertEqual(OverflowItems.split(OverflowItems.join(["a\nb", "c"])), ["a\nb", "c"])
        XCTAssertEqual(OverflowItems.split(" \n\t\n"), [])
        XCTAssertEqual(OverflowItems.split("- outline\n  - indented"), ["- outline\n  - indented"])
    }

    func testReconcileKeepsIdsForUnchangedAndEditedItems() {
        let a = OverflowItem(id: "a", text: "alpha", order: 0), b = OverflowItem(id: "b", text: "beta", order: 1)
        // unchanged text keeps its item even when it moves
        var out = OverflowItems.reconcile(existing: [a, b], blocks: ["beta", "alpha"])
        XCTAssertEqual(out.map(\.id), ["b", "a"]); XCTAssertEqual(out.map(\.order), [0, 1])
        // an edited block takes the place of the item that vanished
        out = OverflowItems.reconcile(existing: [a, b], blocks: ["alpha", "beta edited"])
        XCTAssertEqual(out.map(\.id), ["a", "b"]); XCTAssertEqual(out[1].text, "beta edited")
        // a new block gets a new item, a removed block removes its item
        out = OverflowItems.reconcile(existing: [a, b], blocks: ["alpha", "beta", "gamma"])
        XCTAssertEqual(out.count, 3); XCTAssertEqual(Set(out.prefix(2).map(\.id)), ["a", "b"]); XCTAssertEqual(out[2].text, "gamma")
        out = OverflowItems.reconcile(existing: [a, b], blocks: ["alpha"])
        XCTAssertEqual(out.map(\.id), ["a"])
    }

    func testStashPlan() {
        let doc = "First.\n\nSecond one.\n\nThird."
        let ns = doc as NSString
        // a whole paragraph takes its paragraph break with it: no hole
        var r = ns.range(of: "Second one.")
        var plan = OverflowStash.plan(doc: doc, from: r.location, to: NSMaxRange(r))!
        XCTAssertEqual(plan.stashed, "Second one.")
        XCTAssertEqual(ns.replacingCharacters(in: plan.remove, with: ""), "First.\n\nThird.")
        // part of a line leaves the rest of the line alone
        r = ns.range(of: "one")
        plan = OverflowStash.plan(doc: doc, from: r.location, to: NSMaxRange(r))!
        XCTAssertEqual(ns.replacingCharacters(in: plan.remove, with: ""), "First.\n\nSecond .\n\nThird.")
        // whitespace only, empty and out of range selections stash nothing
        XCTAssertNil(OverflowStash.plan(doc: doc, from: 6, to: 8))
        XCTAssertNil(OverflowStash.plan(doc: doc, from: 3, to: 3))
        XCTAssertNil(OverflowStash.plan(doc: doc, from: 0, to: 999))
        XCTAssertEqual(OverflowStash.append("two", to: "one\n\n"), "one\n\ntwo")
        XCTAssertEqual(OverflowStash.append("one", to: ""), "one")
    }

    @MainActor
    func testSidecarRoundTripKeepsOtherState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overflow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = dir.appendingPathComponent("post.md")
        let text = "Alpha beta gamma.\n\nDelta."
        try text.write(to: doc, atomically: true, encoding: .utf8)
        defer { SidecarSession.discard(documentPath: doc.path) }
        let store = OverflowSidecarStore(defaults: UserDefaults(suiteName: "overflow-test-\(UUID().uuidString)")!)
        // a ghost from another feature sits in the shared session
        let session = SidecarSession.shared(for: doc.path)
        session.loadIfNeeded(doc: text)
        session.update { _ = try? $0.addGhost(from: 6, to: 10) }

        store.save(OverflowData(text: "spare one\n\nspare two", open: true), documentPath: doc.path, documentText: text)
        let back = store.load(documentPath: doc.path, documentText: text)
        XCTAssertEqual(back.text, "spare one\n\nspare two")
        XCTAssertTrue(back.open)
        let disk = SidecarStore.load(for: doc, documentText: text).sidecar
        XCTAssertEqual(disk.ghosts.count, 1, "the ghost is in the same file")
        XCTAssertEqual(disk.sortedOverflow.map(\.text), ["spare one", "spare two"])
        XCTAssertEqual(try String(contentsOf: doc, encoding: .utf8), text, "the .md is never written")

        // a stash removed 6 units before the ghost: the sidecar follows (the editor's SidecarEditHook
        // does this in the app), the next save writes the new place
        session.follow([Change(from: 0, to: 6)], old: Array(text.utf16), new: Array(text.utf16.dropFirst(6)))
        let edited = String(text.dropFirst(6))
        store.save(OverflowData(text: "spare one\n\nspare two\n\nthree", open: false), documentPath: doc.path, documentText: edited)
        XCTAssertFalse(store.load(documentPath: doc.path, documentText: edited).open)
        let disk2 = SidecarStore.load(for: doc, documentText: edited).sidecar
        XCTAssertEqual(disk2.sortedOverflow.count, 3)
        XCTAssertEqual(disk2.ghosts.first?.anchor.from, 0)

        // empty panel and no other state: no file
        session.update { $0.ghosts = [] }
        store.save(OverflowData(text: "", open: false), documentPath: doc.path, documentText: edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SidecarStore.url(for: doc).path))
    }

    func testRemoveIsTheReverseOfAppend() {
        XCTAssertEqual(OverflowStash.remove("b", from: OverflowStash.append("b", to: "a")), "a")
        XCTAssertEqual(OverflowStash.remove("b", from: OverflowStash.append("b", to: "")), "")
        XCTAssertEqual(OverflowStash.remove("a", from: "a\n\nb"), "b", "a first chunk takes the blank line after it")
        XCTAssertEqual(OverflowStash.remove("x", from: "a\n\nb"), "a\n\nb", "not there: unchanged")
        XCTAssertEqual(OverflowStash.remove("b", from: "b\n\na\n\nb"), "b\n\na", "the last occurrence goes")
    }

    /// The toggle's tooltip names the key the Overflow menu item really has (Option-O), and the hint strip agrees.
    @MainActor
    func testToggleTooltipMatchesTheRealKeyBinding() throws {
        let main = NSMenu(title: "Main")
        OverflowMenu.installMenu(in: main)
        let overflow = try XCTUnwrap(main.items.first { $0.submenu?.title == "Overflow" }?.submenu)
        let item = try XCTUnwrap(overflow.items.first { $0.title == OverflowMenu.toggleTitles.0 })
        let mods = item.keyEquivalentModifierMask
        var glyphs = ""
        if mods.contains(.control) { glyphs += "\u{2303}" }
        if mods.contains(.option) { glyphs += "\u{2325}" }
        if mods.contains(.shift) { glyphs += "\u{21E7}" }
        if mods.contains(.command) { glyphs += "\u{2318}" }
        glyphs += item.keyEquivalent.uppercased()
        XCTAssertEqual(glyphs, "\u{2325}O", "the real binding is Option-O")
        XCTAssertEqual(OverflowToggleButton().toolTip, "Overflow (\(glyphs))")
        XCTAssertEqual(HintStrip.builtIn.first { $0.label == "overflow" }?.keys, glyphs)
    }
}
