import XCTest
import AppKit
@testable import FlowriterKit

/// The editor in a window that is never shown: real NSTextView input, layout and undo.
@MainActor
final class EditorViewTests: XCTestCase {
    private var controller: DocumentWindowController!
    private var editor: EditorTextView { controller.editor }

    override func setUp() async throws {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: DocumentWindowController.focusKey)
    }

    override func tearDown() async throws {
        (controller?.document as? Document)?.close()
        controller = nil
    }

    private func open(_ text: String, notes: String? = nil, focus: Bool = false) {
        var options = Snapshot.Options()
        options.notes = notes
        options.focus = focus
        controller = Snapshot.window(markdown: text, options: options)
        controller.window?.makeFirstResponder(editor)
    }

    private func type(_ s: String) {
        for ch in s {
            if ch == "\n" { editor.insertNewline(nil) } else { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
        }
    }

    private func caret(_ location: Int) { editor.setSelectedRange(NSRange(location: location, length: 0)) }

    /// Top of every line fragment, by the character that starts it.
    private func lineTops() -> [Int: CGFloat] {
        let lm = editor.layoutManager!
        lm.ensureLayout(for: editor.textContainer!)
        var tops: [Int: CGFloat] = [:]
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            tops[lm.characterIndexForGlyph(at: glyphs.location)] = rect.minY
        }
        return tops
    }

    private func flag(_ key: NSAttributedString.Key, at i: Int) -> Bool { editor.textStorage!.attribute(key, at: i, effectiveRange: nil) != nil }
    private func font(at i: Int) -> NSFont? { editor.textStorage!.attribute(.font, at: i, effectiveRange: nil) as? NSFont }

    // MARK: the line grid

    func testEveryStyleHasTheSameAdvance() {
        let t = Theme()
        for f in [t.regular, t.bold, t.italic, t.boldItalic] {
            XCTAssertEqual(("mmmmmmmmmm" as NSString).size(withAttributes: [.font: f]).width, 10 * t.charWidth, accuracy: 0.01, f.fontName)
        }
    }

    func testEveryLineIsOneLineHeightTall() {
        open("# Heading\n\nText with emoji 😀 and 漢字 here.\n\n- item\n\n```\ncode\n```\n")
        let lm = editor.layoutManager!
        var heights = Set<CGFloat>()
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { rect, _, _, _, _ in heights.insert(rect.height) }
        heights.insert(lm.extraLineFragmentRect.height)
        XCTAssertEqual(heights, [editor.theme.lineHeight])
    }

    /// The reported glitch: text below must not move while a line becomes a heading or a list item.
    func testTypingMarkersMovesNothingElse() {
        let body = "First paragraph that is long enough to wrap onto a second line in the column, so wrapping is in play here.\n\n\n\nLast paragraph, also long enough to wrap onto a second line of the column when it is laid out.\n"
        open(body)
        let target = (body as NSString).range(of: "\n\n\n\n").location + 2   // the empty line in the middle
        let lastStart = (body as NSString).range(of: "Last").location
        let height = editor.frame.height
        for typed in ["# Heading", "## Two", "- item", "1. item", "- [ ] task", "> quote", "**bold** and *it* and `code`", "😀 emoji 漢字", "```"] {
            caret(target)
            let before = lineTops()
            var moved: [String] = []
            var typedUnits = 0
            for (i, ch) in typed.enumerated() {
                editor.insertText(String(ch), replacementRange: editor.selectedRange())
                typedUnits += String(ch).utf16.count
                let after = lineTops()
                if after[0] != before[0] || after[target] != before[target] || after[lastStart + typedUnits] != before[lastStart] {
                    moved.append(String(typed.prefix(i + 1)))
                }
                XCTAssertEqual(editor.frame.height, height, "the page changed height after typing \(typed.prefix(i + 1))")
            }
            XCTAssertEqual(moved, [], "lines moved while typing \(typed)")
            XCTAssertEqual(editor.selectedRange().location, target + typedUnits, "the caret follows the typing")
            // take it out again
            editor.insertText("", replacementRange: NSRange(location: target, length: typedUnits))
            XCTAssertEqual(editor.string, body)
            XCTAssertEqual(lineTops()[lastStart], before[lastStart])
        }
    }

    func testAHeadingIsBoldAndPlainTextIsNot() {
        open("")
        type("# Title")
        XCTAssertEqual(font(at: 3), editor.theme.bold)
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        editor.insertText("", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "Title")
        XCTAssertEqual(font(at: 1), editor.theme.regular, "a line that stops being a heading must not stay bold")
    }

    // MARK: lists, through the text view

    func testReturnTabAndBackspaceInAList() {
        open("")
        type("- one\ntwo")
        XCTAssertEqual(editor.string, "- one\n- two")
        editor.insertTab(nil)
        XCTAssertEqual(editor.string, "- one\n  - two")
        type("\n")
        XCTAssertEqual(editor.string, "- one\n  - two\n  - ")
        type("\n")
        XCTAssertEqual(editor.string, "- one\n  - two\n- ", "Return on an empty nested item goes one level out")
        type("\n")
        XCTAssertEqual(editor.string, "- one\n  - two\n", "Return on an empty top item leaves the list")
        type("after")
        XCTAssertEqual(editor.string, "- one\n  - two\nafter")
        XCTAssertEqual(editor.selectedRange().location, (editor.string as NSString).length)
    }

    func testBackspaceAfterAMarkerLeavesTheList() {
        open("- one")
        caret(2)
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "one")
        XCTAssertEqual(font(at: 0), editor.theme.regular)
    }

    func testUndoIsTheSystemsAndCoversListEdits() {
        open("")
        let undo = editor.undoManager!
        XCTAssertTrue(undo === (controller.document as? Document)?.undoManager, "the page edits the document's undo stack")
        // one undo group per step, as one per key event in the app
        undo.groupsByEvent = false
        undo.beginUndoGrouping(); type("- one"); undo.endUndoGrouping()
        undo.beginUndoGrouping(); editor.insertNewline(nil); undo.endUndoGrouping()
        XCTAssertEqual(editor.string, "- one\n- ")
        undo.undo()
        XCTAssertEqual(editor.string, "- one")
        undo.redo()
        XCTAssertEqual(editor.string, "- one\n- ")
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(editor.string, "")
    }

    func testRealKeyEventsReachTheListRules() {
        open("- one")
        caret(5)
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: controller.window!.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            editor.keyDown(with: e)
        }
        key(36, "\r")
        key(7, "x")
        XCTAssertEqual(editor.string, "- one\n- x")
        key(48, "\t")
        XCTAssertEqual(editor.string, "- one\n  - x")
        key(48, "\u{19}", .shift)
        XCTAssertEqual(editor.string, "- one\n- x")
    }

    // MARK: marked text (input methods, dead keys)

    func testComposingTextStaysOneTruth() {
        open("Hello world")
        caret(5)
        editor.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "Hello´ world")
        XCTAssertEqual((controller.document as? Document)?.currentText, "Hello´ world", "the document reads the same text the view shows")
        editor.insertText("é", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(editor.string.hasPrefix("Helloé"))
    }

    // MARK: code fences

    func testAFenceColoursTheLinesBelowAndClosingItRestoresThem() {
        open("intro\n\nalpha **b**\nbeta\n")
        let alpha = (editor.string as NSString).range(of: "alpha").location
        XCTAssertFalse(flag(.fwCodeBlock, at: alpha))
        caret(6)
        type("```")
        let a2 = (editor.string as NSString).range(of: "alpha").location, beta = (editor.string as NSString).range(of: "beta").location
        XCTAssertTrue(flag(.fwCodeBlock, at: a2) && flag(.fwCodeBlock, at: beta), "an open fence makes everything below it code")
        XCTAssertEqual(font(at: a2 + 8), editor.theme.regular, "no bold inside code")
        editor.setSelectedRange(NSRange(location: 6, length: 3))
        editor.insertText("", replacementRange: editor.selectedRange())
        let a3 = (editor.string as NSString).range(of: "alpha").location
        XCTAssertFalse(flag(.fwCodeBlock, at: a3))
        XCTAssertEqual(font(at: a3 + 8), editor.theme.bold)
    }

    func testOneKeystrokeStylesOneLine() {
        var doc = ""
        for i in 0..<300 { doc += "Paragraph \(i) with some words in it.\n\n" }
        open(doc)
        caret(400)
        type("x")
        XCTAssertEqual(editor.highlighter.lastStyledLines, 1)
    }

    // MARK: column and drawer

    func testTheColumnStaysPutWhenTheDrawerFitsBesideIt() {
        var options = Snapshot.Options()
        options.width = 1500
        controller = Snapshot.window(markdown: "text", options: options)
        let before = editor.textContainerOrigin.x
        XCTAssertEqual(editor.textContainer!.size.width, editor.theme.columnWidth)
        controller.setNotesOpen(true)
        XCTAssertEqual(editor.textContainerOrigin.x, before, "a wide window: opening the notes moves no text")
        XCTAssertEqual(editor.textContainer!.size.width, editor.theme.columnWidth)
        XCTAssertFalse(controller.drawer.isHidden)
    }

    func testANarrowWindowMovesTheColumnClearOfTheDrawer() {
        var options = Snapshot.Options()
        options.width = 900
        controller = Snapshot.window(markdown: "text", options: options)
        controller.setNotesOpen(true)
        let right = editor.textContainerOrigin.x + editor.textContainer!.size.width
        XCTAssertLessThanOrEqual(right, controller.drawer.frame.minX - editor.theme.margin + 0.5)
        XCTAssertGreaterThanOrEqual(editor.textContainerOrigin.x, editor.theme.margin)
    }

    /// Bigger text must keep its margins: the column narrows, the room on each side stays.
    func testBigTextKeepsTheSameRoomOnBothSides() {
        var options = Snapshot.Options()
        options.width = 820
        controller = Snapshot.window(markdown: "Some text that is long enough to wrap in a narrow column of big letters.", options: options)
        defer { DocumentWindowController.setFontSize(Theme.defaultFontSize) }
        for size in [CGFloat(15), 22, 30] {
            DocumentWindowController.setFontSize(size)
            for open in [false, true] {
                controller.setNotesOpen(open)
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                let margin = editor.theme.margin
                let left = editor.textContainerOrigin.x
                let right = (open ? controller.drawer.frame.minX : controller.root.bounds.width) - (left + editor.textContainer!.size.width)
                XCTAssertGreaterThanOrEqual(left, margin, "size \(size) notes \(open)")
                XCTAssertGreaterThanOrEqual(right, margin - 0.5, "size \(size) notes \(open)")
                XCTAssertGreaterThanOrEqual(margin, 3 * editor.theme.charWidth - 1)
                if editor.textContainer!.size.width < editor.theme.columnWidth {
                    XCTAssertEqual(left, right, accuracy: 1.5, "a narrowed column has the same room on both sides (size \(size), notes \(open))")
                }
            }
        }
    }

    func testColumnLayoutIsContinuous() {
        var last = ColumnLayout.place(viewWidth: 1400, column: 600, reservedRight: 0, margin: 32).left
        for reserved in stride(from: CGFloat(0), through: 900, by: 1) {
            let p = ColumnLayout.place(viewWidth: 1400, column: 600, reservedRight: reserved, margin: 32)
            XCTAssertLessThanOrEqual(abs(p.left - last), reserved == 0 ? 400 : 1.01, "the column jumped at \(reserved)")
            XCTAssertGreaterThanOrEqual(p.width, 120)
            last = p.left
        }
    }

    // MARK: focus mode

    func testFocusModeKeepsTheCaretLineOnTheCentre() {
        var doc = ""
        for i in 0..<120 { doc += "Line \(i)\n" }
        open(doc, focus: true)
        let clip = controller.editorScroll.contentView
        for location in [0, 300, (doc as NSString).length] {
            caret(location)
            editor.scrollRangeToVisible(editor.selectedRange())
            let rect = editor.caretLineRect()!
            XCTAssertEqual(rect.midY - clip.bounds.minY, clip.bounds.height / 2, accuracy: 1.5, "caret at \(location)")
        }
        caret(300)
        editor.scrollRangeToVisible(editor.selectedRange())
        let y = clip.bounds.minY
        type("some words typed on the same line")
        XCTAssertEqual(clip.bounds.minY, y, "typing on one line must not scroll")
    }

    // MARK: notes

    func testTheNotesStepBackWhileThePageHasTheKeys() {
        open("page text", notes: "a note")
        let notes = controller.drawer.textView
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        controller.window?.makeFirstResponder(editor)
        settle()
        XCTAssertTrue(controller.drawer.dimmed)
        XCTAssertEqual(controller.drawer.scroll.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertEqual(editorAlpha, 1, "the page is never dimmed")
        XCTAssertLessThan(notes.theme.fontSize, editor.theme.fontSize, "notes are set a step smaller than the page")
        DocumentWindowController.setFontSize(22)
        XCTAssertEqual(notes.theme.fontSize, Theme(fontSize: 22).notes.fontSize, "and follow the page when the text size changes")
        DocumentWindowController.setFontSize(Theme.defaultFontSize)
        controller.window?.makeFirstResponder(notes)
        settle()
        XCTAssertFalse(controller.drawer.dimmed)
        XCTAssertEqual(controller.drawer.scroll.alphaValue, 1, accuracy: 0.01)
    }

    private var editorAlpha: CGFloat { controller.editorScroll.alphaValue }

    func testMoveSelectionToNotesAndBack() {
        open("keep\ncut this\nkeep too", notes: "first note")
        let range = (editor.string as NSString).range(of: "cut this\n")
        editor.setSelectedRange(range)
        controller.window?.makeFirstResponder(editor)
        controller.moveSelectionAcross(nil)
        XCTAssertEqual(editor.string, "keep\nkeep too")
        XCTAssertEqual(controller.drawer.textView.string, "first note\n\ncut this")
        XCTAssertEqual((controller.document as? Document)?.notes, "first note\n\ncut this")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "keep\ncut this\nkeep too", "the page undoes its own half")
    }
}
