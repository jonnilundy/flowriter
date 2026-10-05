import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// The pointer over chrome that sits on the page. The page's NSTextView registers an I-beam rect over
/// its whole frame, so each button above it must register its own. Real hover (the window server
/// moving the pointer over the view) is not exercised here: these tests assert what each view
/// registers, and that `resetCursorRects` hands those rects to AppKit through PointerCursor.reset.
@MainActor
final class PointerCursorTests: XCTestCase {
    /// What the view's `resetCursorRects` adds (the sink replaces addCursorRect).
    func registered(_ v: some PointerCursorProviding) -> [(CGRect, NSCursor)] {
        var out: [(CGRect, NSCursor)] = []
        PointerCursor.reset(v) { out.append(($0, $1)) }
        return out
    }

    func assertHand(_ v: some PointerCursorProviding, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = registered(v)
        XCTAssertEqual(r.count, 1, what, file: file, line: line)
        XCTAssertTrue(r.first?.1 === NSCursor.pointingHand, "\(what): pointing hand", file: file, line: line)
        XCTAssertEqual(r.first?.0 ?? .zero, v.bounds, "\(what): over the whole view", file: file, line: line)
        XCTAssertFalse(v.bounds.isEmpty, "\(what): has a size", file: file, line: line)
    }

    func testTheHelperSkipsEmptyRectsAndForwardsTheRest() {
        let v = OverflowToggleButton()
        v.frame = .zero
        XCTAssertTrue(registered(v).isEmpty, "no size, no rect")
        XCTAssertEqual(PointerCursor.hand(CGRect(x: 0, y: 0, width: 4, height: 5)).first?.cursor, NSCursor.pointingHand)
        XCTAssertEqual(PointerCursor.arrow(CGRect(x: 0, y: 0, width: 4, height: 5)).first?.cursor, NSCursor.arrow)
    }

    func testTheOverflowToggleButtonShowsThePointingHand() {
        assertHand(OverflowToggleButton(), "Overflow toggle")
        assertHand(OverflowToggleButton(symbol: "sidebar.left", label: "Hide Alternatives", toolTip: "Hide Alternatives"), "Alternatives toggle (the same class)")
    }

    func testTheMarkdownToggleShowsThePointingHand() {
        let b = ViewToggleButton(icon: ViewToggleButton.markdownMark, ink: 20.5)
        b.frame = CGRect(x: 0, y: 0, width: ViewTogglesView.buttonSize, height: ViewTogglesView.buttonSize)
        assertHand(b, "M↓ toggle")
    }

    func testTheRectFollowsTheViewWhenItResizes() {
        let b = OverflowToggleButton()
        XCTAssertEqual(registered(b).first?.0, CGRect(x: 0, y: 0, width: 28, height: 28))
        b.frame = CGRect(x: 40, y: 40, width: 36, height: 30)
        XCTAssertEqual(registered(b).first?.0, CGRect(x: 0, y: 0, width: 36, height: 30), "bounds, in the view's own coordinates")
    }

    func testTheFileNameShowsThePointingHandOnlyWhileItHasAName() async {
        let f = ShellFixture(files: ["a.md": "x"])
        await f.open(file: "a.md")
        let v = FileNameView(model: f.model)
        v.frame = CGRect(x: 0, y: 0, width: 120, height: FileNameView.boxHeight)
        XCTAssertTrue(registered(v).isEmpty, "no name yet: no menu, no hand")
        v.refresh()
        XCTAssertEqual(v.name, "a")
        assertHand(v, "file name")
    }

    func testThePaletteChipIsAHandWhileItIsAMenuAndAnArrowWhenItIsALabel() async {
        let f = ShellFixture(files: ["a.md": "x"])
        let home = TFS.tempDir("home"), work = TFS.tempDir("work")
        f.model.setSetting("files.note-locations", .list(["Home|\(home)", "Work|\(work)"]))
        f.model.setSetting("files.default-note-location", .string(home))
        await f.open()
        let overlay = PaletteOverlayView(model: f.model)
        overlay.frame = NSRect(x: 0, y: 0, width: 760, height: 330)
        f.model.palette = PaletteState(intent: .createFile, query: "Idea")
        overlay.reload(resetField: true); overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.chip.chip?.hasMenu, true)
        assertHand(overlay.chip, "destination chip with locations to pick")

        // no locations: the chip names the folder and is only a label
        f.model.setSetting("files.note-locations", .list([]))
        f.model.setSetting("files.default-note-location", .string(""))
        f.model.palette = PaletteState(intent: .createFile, query: "Idea")
        overlay.reload(resetField: true); overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.chip.chip?.hasMenu, false)
        let r = registered(overlay.chip)
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r.first?.1 === NSCursor.arrow, "a label shows the arrow, not the page's I-beam")
        XCTAssertEqual(r.first?.0 ?? .zero, overlay.chip.bounds)
    }

    func testViewsInAWindowInvalidateTheirRectsWhenTheyMoveOrHide() {
        // not hover: only that the hooks run without a window and with one
        let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        w.contentView = host
        let b = OverflowToggleButton()
        host.addSubview(b)
        b.frame = CGRect(x: 10, y: 10, width: 28, height: 28)
        b.isHidden = true
        b.isHidden = false
        b.removeFromSuperview()
        XCTAssertNil(b.window)
        PointerCursor.invalidate(b)   // no window: nothing happens
        w.close()
    }
}
