import AppKit
import XCTest
@testable import FloCore
@testable import FloKit
@testable import FloStateNative

/// Flowriter outline popup: row hit testing, where a click puts the caret, and the open, close and
/// jump flow with the motion switched off (the motion itself is measured by the `outline` VM
/// scenario in OutlineSelfTest.swift).
@MainActor
final class OutlinePopupTests: XCTestCase {
    // MARK: row geometry

    func testRowBandsTouchAndCoverTheRows() {
        let n = 5
        XCTAssertNil(OutlineRows.index(atY: 0, count: n), "the air above the first row")
        XCTAssertNil(OutlineRows.index(atY: OutlineRows.rowTop(0) - 2.1, count: n))
        XCTAssertEqual(OutlineRows.index(atY: OutlineRows.rowTop(0) - 1.9, count: n), 0, "the band starts mid-gap above the row")
        for i in 0..<n {
            XCTAssertEqual(OutlineRows.index(atY: OutlineRows.rowTop(i) + OutlineRows.textHeight / 2, count: n), i)
            XCTAssertEqual(OutlineRows.index(atY: OutlineRows.rowTop(i) + 0.1, count: n), i)
            XCTAssertEqual(OutlineRows.index(atY: OutlineRows.rowTop(i) + OutlineRows.textHeight - 0.1, count: n), i)
            let b = OutlineRows.band(i, width: 260)
            XCTAssertEqual(b.height, OutlineRows.pitch)
            if i > 0 { XCTAssertEqual(b.minY, OutlineRows.band(i - 1, width: 260).maxY, accuracy: 0.001, "bands touch: no dead gap between rows") }
        }
        // the gap under a row belongs to the row nearer to it
        XCTAssertEqual(OutlineRows.index(atY: OutlineRows.rowTop(1) + OutlineRows.textHeight + 1, count: n), 1)
        XCTAssertEqual(OutlineRows.index(atY: OutlineRows.rowTop(2) - 1, count: n), 2)
        XCTAssertNil(OutlineRows.index(atY: OutlineRows.rowTop(n - 1) + OutlineRows.textHeight + 2.1, count: n), "below the last row")
        XCTAssertNil(OutlineRows.index(atY: 500, count: n))
        XCTAssertNil(OutlineRows.index(atY: 20, count: 0))
        XCTAssertNil(OutlineRows.index(atY: -5, count: n))
    }

    func testHighlightSitsInsideItsRowWithAirAtTheSides() {
        for i in 0..<4 {
            let h = OutlineRows.highlight(i, width: 260), b = OutlineRows.band(i, width: 260)
            XCTAssertTrue(b.contains(h))
            XCTAssertEqual(h.minX, 6); XCTAssertEqual(260 - h.maxX, 6)
            XCTAssertGreaterThan(h.height, OutlineRows.textHeight)
        }
    }

    func testContentHeightIsTheOldCardHeight() {
        // rows 19.5, gaps 4, 12 above and below: what layoutFor used before the rows had bands
        XCTAssertEqual(OutlineRows.contentHeight(count: 5), 5 * 19.5 + 4 * 4 + 24)
        XCTAssertEqual(OutlineRows.contentHeight(count: 1), 19.5 + 24)
        XCTAssertEqual(OutlineRows.contentHeight(count: 0), 24)
    }

    // MARK: jump target

    func head(_ text: String, _ line: Int) -> DocumentHeading {
        let hs = DocumentHeadings.parse(text, maxDepth: 6)
        return hs[line]
    }

    func testCaretLandsOnTheStartOfTheHeadingText() {
        let text = "# Title\n\nbody\n\n## Act 1: One\n\n###   Spaced  \n\n#### Tabbed\n"
        let hs = DocumentHeadings.parse(text, maxDepth: 6)
        XCTAssertEqual(hs.map(\.text), ["Title", "Act 1: One", "Spaced", "Tabbed"])
        let ns = text as NSString
        XCTAssertEqual(HeadingJump.caret(for: hs[0], in: ns), 2)
        XCTAssertEqual(HeadingJump.caret(for: hs[1], in: ns), ns.range(of: "Act 1").location)
        XCTAssertEqual(HeadingJump.caret(for: hs[2], in: ns), ns.range(of: "Spaced").location, "all the spaces after the marks")
        XCTAssertEqual(HeadingJump.caret(for: hs[3], in: ns), ns.range(of: "Tabbed").location)
    }

    func testCaretCountsUTF16Offsets() {
        let text = "😀 first line\n\n## Ünïcode 😀 head\n"
        let hs = DocumentHeadings.parse(text, maxDepth: 6)
        let ns = text as NSString
        XCTAssertEqual(hs[0].pos, ns.range(of: "## ").location)
        XCTAssertEqual(HeadingJump.caret(for: hs[0], in: ns), ns.range(of: "Ünï").location)
    }

    func testCaretOfAStaleHeadingIsClamped() {
        let ns = "## Gone" as NSString
        let stale = DocumentHeading(level: 2, text: "Later", line: 9, pos: 400, slug: "later")
        XCTAssertEqual(HeadingJump.caret(for: stale, in: ns), ns.length)
        let early = DocumentHeading(level: 2, text: "x", line: 0, pos: -3, slug: "x")
        XCTAssertEqual(HeadingJump.caret(for: early, in: ns), 3)
        XCTAssertEqual(HeadingJump.caret(for: stale, in: "" as NSString), 0)
        // only marks on the line
        let marks = "## " as NSString
        XCTAssertEqual(HeadingJump.caret(for: DocumentHeading(level: 2, text: "", line: 0, pos: 0, slug: ""), in: marks), 3)
    }

    // MARK: flow (motion off)

    var wc: ShellWindowController!
    var f: ShellFixture!

    override func tearDown() async throws {
        OutlineMotion.animations = true
        wc?.window?.close()
        wc = nil
    }

    func open(_ text: String) async throws -> (OutlineRailView, EditorPaneView) {
        OutlineMotion.animations = false
        f = ShellFixture(files: ["o.md": text], config: "editor.jump-to-bottom-after-minutes = 0\n")
        wc = ShellWindowController(model: f.model, frame: NSRect(x: -10000, y: -10000, width: 1400, height: 900), offscreen: true)
        wc.root.animationsEnabled = false
        await f.open()
        try await f.model.editor.openFileInTabOrFocus(f.p("o.md"))
        await f.settle()
        wc.flush()
        wc.root.layoutSubtreeIfNeeded()
        return (wc.root.area.rail, try XCTUnwrap(wc.root.area.activeFilePane))
    }

    func testClickOnARowJumpsAndClosesThePopup() async throws {
        let doc = (1...30).map { "## Section \($0)\n\n" + String(repeating: "para\n\n", count: 10) }.joined()
        let (rail, pane) = try await open("# Title\n\n" + doc)
        XCTAssertFalse(rail.isHidden)
        rail.openPopover()
        let pop = try XCTUnwrap(rail.popover)
        XCTAssertEqual(pop.phase, .shown, "no motion: in at once")
        XCTAssertTrue(rail.isOpen)
        // the popup scrolls (31 rows); a click on a visible row picks that row, whatever the scroll
        pop.scroll.contentView.scroll(to: CGPoint(x: 0, y: 200))
        let atRow = pop.list.convert(NSPoint(x: 100, y: OutlineRows.rowTop(12) + 5), to: pop)
        XCTAssertEqual(pop.rowIndex(at: atRow), 12)
        pop.drawer.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: pop.convert(atRow, to: nil), modifierFlags: [], timestamp: 0,
                                                    windowNumber: wc.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        let text = pane.controller!.text as NSString
        XCTAssertEqual(pane.controller!.state.selection.main.head, text.range(of: "Section 12").location, "caret at the heading's text")
        XCTAssertTrue(pane.controller!.state.selection.main.empty)
        XCTAssertNil(rail.popover, "the popup closed")
        XCTAssertFalse(rail.isOpen)
        XCTAssertEqual(rail.subviews.count, 1, "only the ticks are left")
        XCTAssertEqual(rail.activeIndex, 12, "the clicked heading is the current section")
        let top = try XCTUnwrap(pane.controller!.lineTop(forPosition: text.range(of: "## Section 12").location, in: pane))
        XCTAssertEqual(top, HeadingJump.landing, accuracy: 2)
    }

    func testEscapeAndReopenWithoutMotion() async throws {
        let (rail, _) = try await open("# One\n\ntext\n\n## Two\n\ntext\n")
        rail.openPopover()
        rail.openPopover()   // a second hover while open changes nothing
        XCTAssertEqual(rail.subviews.count, 2)
        rail.closePopover()
        XCTAssertNil(rail.popover)
        rail.closePopover()  // closing a closed popup is a no-op
        rail.openPopover()
        XCTAssertNotNil(rail.popover)
        rail.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: wc.window!.windowNumber,
                                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        XCTAssertNil(rail.popover, "Esc closes it")
    }

    func testHoverFollowsTheMoveAndHidesWhileLeaving() async throws {
        let (rail, _) = try await open("# One\n\ntext\n\n## Two\n\ntext\n\n## Three\n\ntext\n")
        rail.openPopover()
        let pop = try XCTUnwrap(rail.popover)
        func move(_ y: CGFloat) {
            let p = pop.drawer.convert(NSPoint(x: 120, y: y), to: nil)
            pop.drawer.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: wc.window!.windowNumber,
                                                           context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
        }
        XCTAssertNil(pop.hovered)
        move(OutlineRows.rowTop(1) + 8)
        XCTAssertEqual(pop.hovered, 1)
        XCTAssertNotNil(pop.hoverRect)
        move(OutlineRows.rowTop(2) + 8)
        XCTAssertEqual(pop.hovered, 2)
        move(2)
        XCTAssertNil(pop.hovered)
        XCTAssertNil(pop.hoverRect)
        XCTAssertEqual(pop.cursorRects.count, 3)
        XCTAssertTrue(pop.cursorRects.allSatisfy { $0.cursor === NSCursor.pointingHand })
    }
}
