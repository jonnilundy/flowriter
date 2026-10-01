import AppKit
import XCTest
@testable import FloCore
@testable import FloStateNative

/// Flowriter Alternatives panel: the decisions behind closing it, a click in its empty space and the
/// title band beside it (the window flows are covered by the VM scenarios in AltPanelSelfTest.swift).
@MainActor
final class AlternativesPanelTests: XCTestCase {
    func testOptionAClosesFromThePanelOrOnTheShownText() {
        let word = NSRange(location: 10, length: 6)
        // inside the panel ⌥A always closes, whatever the page holds
        XCTAssertTrue(AlternativesPanelView.addShortcutCloses(panelHasFocus: true, target: word, current: word))
        XCTAssertTrue(AlternativesPanelView.addShortcutCloses(panelHasFocus: true, target: NSRange(location: 40, length: 5), current: word))
        // from the page: the text the panel shows closes it, nothing to open on closes it
        XCTAssertTrue(AlternativesPanelView.addShortcutCloses(panelHasFocus: false, target: word, current: word))
        XCTAssertTrue(AlternativesPanelView.addShortcutCloses(panelHasFocus: false, target: NSRange(location: 3, length: 0), current: word))
        // other text moves the panel there (it stays open)
        XCTAssertFalse(AlternativesPanelView.addShortcutCloses(panelHasFocus: false, target: NSRange(location: 40, length: 5), current: word))
        XCTAssertFalse(AlternativesPanelView.addShortcutCloses(panelHasFocus: false, target: word, current: nil))
        XCTAssertFalse(AlternativesPanelView.addShortcutCloses(panelHasFocus: false, target: NSRange(location: 10, length: 4), current: word))
    }

    func testClickBelowTheListGoesToTheAddLine() {
        let tabs: [(AlternativeLevel, NSRect)] = [(.word, NSRect(x: 12, y: 80, width: 40, height: 28)),
                                                  (.sentence, NSRect(x: 60, y: 80, width: 70, height: 28))]
        let rows = [NSRect(x: 0, y: 118, width: 220, height: 23), NSRect(x: 0, y: 141, width: 220, height: 23)]
        let bottom = rows.last!.maxY
        func hit(_ x: CGFloat, _ y: CGFloat) -> AlternativesPanelView.ClickTarget {
            AlternativesPanelView.clickTarget(at: NSPoint(x: x, y: y), tabs: tabs, rows: rows, listBottom: bottom)
        }
        XCTAssertEqual(hit(30, 90), .tab(.word))
        XCTAssertEqual(hit(100, 90), .tab(.sentence))
        XCTAssertEqual(hit(50, 125), .row(0))
        XCTAssertEqual(hit(200, 150), .row(1), "a row's hit area is the panel's full width")
        XCTAssertEqual(hit(50, bottom), .addLine, "the add line itself")
        XCTAssertEqual(hit(110, 400), .addLine, "the empty space below the list")
        XCTAssertEqual(hit(10, 880), .addLine, "down to the panel's bottom")
        XCTAssertEqual(hit(180, 90), .panel, "beside the tabs: the list gets focus, as before")
        XCTAssertEqual(hit(50, 112), .panel, "between the tabs and the first version")
        // no versions yet: everything below where the list starts
        XCTAssertEqual(AlternativesPanelView.clickTarget(at: NSPoint(x: 50, y: 130), tabs: tabs, rows: [], listBottom: 118), .addLine)
    }

    func testTitleBandBackingStopsAtBothPanels() {
        let h = Metrics.tabBackingHeight
        XCTAssertEqual(ShellRootView.tabBackingFrame(areaX: 0, width: 1090, left: 0, right: 0), CGRect(x: 0, y: 0, width: 1090, height: h))
        XCTAssertEqual(ShellRootView.tabBackingFrame(areaX: 0, width: 1090, left: 220, right: 0), CGRect(x: 220, y: 0, width: 870, height: h))
        XCTAssertEqual(ShellRootView.tabBackingFrame(areaX: 0, width: 1090, left: 0, right: 280), CGRect(x: 0, y: 0, width: 810, height: h))
        XCTAssertEqual(ShellRootView.tabBackingFrame(areaX: 0, width: 1090, left: 220, right: 280), CGRect(x: 220, y: 0, width: 590, height: h))
        // the sidebar: the area starts further right, the panel sits at the area's left edge
        XCTAssertEqual(ShellRootView.tabBackingFrame(areaX: 240, width: 1090, left: 220, right: 0), CGRect(x: 460, y: 0, width: 630, height: h))
        // never a negative width
        XCTAssertEqual(ShellRootView.tabBackingFrame(areaX: 0, width: 400, left: 220, right: 280).width, 0)
    }

    func testThePanelHasAToggleMirroringOverflows() {
        let fx = ShellFixture()
        let p = AlternativesPanelView(model: fx.model)
        XCTAssertTrue(p.toggleButton.superview === p, "the toggle lives in the panel: it shows and hides with it")
        XCTAssertEqual(p.toggleButton.accessibilityLabel(), "Hide Alternatives")
        XCTAssertEqual(p.toggleButton.toolTip, "Hide Alternatives (\u{2325}A)")
        XCTAssertEqual(OverflowToggleButton().accessibilityLabel(), "Toggle Overflow", "Overflow's own button is unchanged")
        XCTAssertFalse(p.isOpen)
        p.dismiss()   // closed: nothing happens
        XCTAssertFalse(p.isOpen)
    }
}
