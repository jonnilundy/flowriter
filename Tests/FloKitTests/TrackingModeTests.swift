import XCTest
import AppKit
@testable import FloKit
import FloCore

/// Tracking mode keeps the caret line on the vertical centre of the view.
@MainActor
final class TrackingModeTests: XCTestCase {
    override func tearDown() { FloTextView.trackingMode = false }

    /// Plain headings and paragraphs, some wrapping to several lines (no tall widgets).
    private func document() -> String {
        (1...120).map { i in
            "# Heading \(i)\n\nLine \(i) of the journal. " + String(repeating: "Words go on and on and on. ", count: i % 7 == 0 ? 14 : 3) + "\n\n"
        }.joined()
    }

    /// Distance of the caret line's centre from the centre of the view.
    private func offCentre(_ r: KeyReplayer) -> CGFloat {
        let tv = r.controller.textView
        let clip = r.controller.scrollView.contentView
        let rect = tv.rectForScroll(NSRange(location: r.controller.state.selection.main.head, length: 0))!
        return rect.midY - clip.bounds.minY - clip.bounds.height / 2
    }

    func testCaretLineStaysCentred() throws {
        let r = KeyReplayer()
        r.load(document(), selection: .cursor(0))
        FloTextView.trackingMode = true
        r.controller.trackingChanged()
        r.window.displayIfNeeded()
        XCTAssertEqual(offCentre(r), 0, accuracy: 20, "first line, after switching on")
        let tv = r.controller.textView
        // a caret placed in the middle of the document, then moved down line by line
        let mid = (tv.string as NSString).length / 2
        r.controller.run { t in t.dispatch(TransactionSpec(selection: .cursor(mid))); return true }
        tv.scrollRangeToVisible(NSRange(location: mid, length: 0))
        XCTAssertEqual(offCentre(r), 0, accuracy: 2, "middle of the document")
        for i in 0..<8 {
            r.press("Down"); r.window.displayIfNeeded()
            XCTAssertEqual(offCentre(r), 0, accuracy: 2, "after Down #\(i + 1)")
        }
        // the last line reaches the centre too
        let end = (tv.string as NSString).length
        r.controller.run { t in t.dispatch(TransactionSpec(selection: .cursor(end))); return true }
        tv.scrollRangeToVisible(NSRange(location: end, length: 0))
        XCTAssertEqual(offCentre(r), 0, accuracy: 2, "last line")
    }

    func testOffKeepsMinimalFollow() throws {
        let r = KeyReplayer()
        r.load(document(), selection: .cursor(0))
        FloTextView.trackingMode = false
        let tv = r.controller.textView
        let y0 = r.controller.scrollView.contentView.bounds.minY
        tv.scrollRangeToVisible(NSRange(location: 0, length: 0))   // already visible: the page stays
        XCTAssertEqual(r.controller.scrollView.contentView.bounds.minY, y0, accuracy: 0.5)
    }
}
