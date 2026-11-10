import XCTest
import AppKit
@testable import FlowriterKit

@MainActor
final class DraftsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("flowriter-drafts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Drafts.directory = dir.appendingPathComponent("Drafts")
        UserDefaults.standard.removeObject(forKey: Locations.listKey)
        UserDefaults.standard.removeObject(forKey: Locations.defaultKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removeObject(forKey: Locations.listKey)
        UserDefaults.standard.removeObject(forKey: Locations.defaultKey)
    }

    private func newNote(_ text: String = "") -> (Document, DocumentWindowController) {
        let c = Snapshot.window(markdown: "", options: Snapshot.Options())
        if !text.isEmpty { c.editor.insertText(text, replacementRange: NSRange(location: 0, length: 0)) }
        return (c.document as! Document, c)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

    // MARK: names

    func testNamesComeFromTheFirstLine() {
        XCTAssertEqual(NoteName.derive(from: "# Happy days!\n\nBody"), "happy-days")
        XCTAssertEqual(NoteName.derive(from: "\n\n  ## What I keep coming back to\n"), "what-i-keep-coming-back-to")
        XCTAssertEqual(NoteName.derive(from: "- [ ] Send the outline to Zeno"), "send-the-outline-to-zeno")
        XCTAssertEqual(NoteName.derive(from: "1. First, name the constraint"), "first-name-the-constraint")
        XCTAssertEqual(NoteName.derive(from: "Café déjà vu: 2026 plan"), "café-déjà-vu-2026-plan")
        XCTAssertEqual(NoteName.derive(from: "---\ntitle: Real Title\n---\n"), "title-real-title")
        XCTAssertEqual(NoteName.derive(from: ""), "untitled")
        XCTAssertEqual(NoteName.derive(from: "***\n```\n"), "untitled")
        let long = NoteName.derive(from: "# " + String(repeating: "word ", count: 40))
        XCTAssertLessThanOrEqual(long.count, 60)
        XCTAssertFalse(long.hasSuffix("-"))
        XCTAssertTrue(long.hasSuffix("word"), "a long name is cut at a whole word")
    }

    // MARK: the drafts folder

    func testDraftsRoundTrip() {
        XCTAssertEqual(Drafts.all(), [])
        Drafts.write(Draft(id: "a", text: "one", notes: "side"))
        Drafts.write(Draft(id: "b", text: "two"))
        XCTAssertEqual(Set(Drafts.all()), [Draft(id: "a", text: "one", notes: "side"), Draft(id: "b", text: "two")])
        Drafts.write(Draft(id: "a", text: "", notes: ""))
        XCTAssertEqual(Drafts.all(), [Draft(id: "b", text: "two")], "a draft with nothing in it leaves no file")
        Drafts.remove("b")
        XCTAssertEqual(Drafts.all(), [])
    }

    // MARK: a note with no file

    func testANewNoteIsNamedAfterItsFirstLineAndKeptAsADraft() {
        let (doc, c) = newNote("# Happy days\n\nText.")
        XCTAssertNil(doc.fileURL)
        XCTAssertEqual(doc.displayName, "happy-days")
        XCTAssertEqual(c.titleText, "happy-days")
        doc.setNotes("a side note")
        doc.saveDraft()
        XCTAssertEqual(Drafts.all().map(\.text), ["# Happy days\n\nText."])
        XCTAssertEqual(Drafts.all().map(\.notes), ["a side note"])
        doc.close()
    }

    func testADraftComesBackAsAnUnsavedNote() {
        Drafts.write(Draft(id: "x1", text: "# Came back\n", notes: "still here"))
        let doc = Document(draft: Drafts.all()[0])
        doc.makeWindowControllers()
        let c = doc.windowControllers.first as! DocumentWindowController
        c.keptDocument = doc
        XCTAssertEqual(c.editor.string, "# Came back\n")
        XCTAssertEqual(c.drawer.textView.string, "still here")
        XCTAssertNil(doc.fileURL)
        XCTAssertEqual(doc.draftID, "x1")
        XCTAssertTrue(doc.isDocumentEdited, "it still counts as unsaved")
        doc.close()
    }

    func testSavingPutsTheNoteInTheFolderAndEndsTheDraft() {
        let (doc, _) = newNote("# Happy days\n")
        doc.setNotes("side")
        doc.saveDraft()
        XCTAssertEqual(Drafts.all().count, 1)
        let folder = dir.appendingPathComponent("notes").path
        let saved = expectation(description: "saved")
        doc.setName(doc.displayName, folder: folder) { ok in XCTAssertTrue(ok); saved.fulfill() }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(doc.fileURL?.path, folder + "/happy-days.md")
        XCTAssertEqual(read(URL(fileURLWithPath: folder + "/happy-days.md")), "# Happy days\n")
        XCTAssertEqual(read(NotesStore.notesURL(for: doc.fileURL!)), "side", "the notes go with the note")
        XCTAssertEqual(Drafts.all(), [], "the draft is done")
        XCTAssertEqual(Locations.load().defaultFolder, folder, "the first folder used becomes the default location")
        XCTAssertEqual(doc.displayName, "happy-days.md")
        doc.close()
    }

    func testRenamingMovesTheFileAndItsNotesAndNeverReplacesAFile() throws {
        let folder = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("taken".utf8).write(to: folder.appendingPathComponent("taken.md"))
        let (doc, _) = newNote("# One\n")
        doc.setNotes("side")
        let saved = expectation(description: "saved")
        doc.setName("one", folder: folder.path) { _ in saved.fulfill() }
        wait(for: [saved], timeout: 5)

        XCTAssertNotNil(doc.problem(name: "taken", folder: folder.path))
        let refused = expectation(description: "refused")
        doc.setName("taken", folder: folder.path) { ok in XCTAssertFalse(ok); refused.fulfill() }
        wait(for: [refused], timeout: 5)
        XCTAssertEqual(read(folder.appendingPathComponent("taken.md")), "taken")

        let moved = expectation(description: "moved")
        doc.setName("archive/two", folder: folder.path) { ok in XCTAssertTrue(ok); moved.fulfill() }
        wait(for: [moved], timeout: 5)
        XCTAssertEqual(doc.fileURL?.path, folder.path + "/archive/two.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path + "/one.md"))
        XCTAssertEqual(read(URL(fileURLWithPath: folder.path + "/archive/two.md")), "# One\n")
        XCTAssertEqual(read(NotesStore.notesURL(for: doc.fileURL!)), "side")
        XCTAssertFalse(FileManager.default.fileExists(atPath: NotesStore.notesURL(for: folder.appendingPathComponent("one.md")).path))
        doc.close()
    }

    // MARK: closing

    private final class CloseSpy: NSObject {
        var answer: Bool?
        @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { answer = shouldClose }
    }

    func testClosingAnUnsavedNoteAsksAndDeleteRemovesTheDraft() {
        let (doc, _) = newNote("# Keep or not\n")
        doc.saveDraft()
        var asked = 0
        doc.onCloseUnsaved = { _, decide in asked += 1; decide(asked == 1 ? .cancel : .delete) }
        let spy = CloseSpy()
        doc.canClose(withDelegate: spy, shouldClose: #selector(CloseSpy.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        XCTAssertEqual(spy.answer, false, "Cancel keeps the window")
        XCTAssertEqual(Drafts.all().count, 1)
        doc.canClose(withDelegate: spy, shouldClose: #selector(CloseSpy.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        XCTAssertEqual(spy.answer, true)
        XCTAssertEqual(Drafts.all(), [], "Delete removes the draft")
        doc.close()
    }

    func testClosingAnEmptyNewNoteDoesNotAsk() {
        let (doc, _) = newNote()
        doc.onCloseUnsaved = { _, _ in XCTFail("an empty note is not worth a question") }
        let spy = CloseSpy()
        doc.canClose(withDelegate: spy, shouldClose: #selector(CloseSpy.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        XCTAssertEqual(spy.answer, true)
        doc.close()
    }

    func testClosingWithSaveGoesThroughTheNameSheet() {
        let (doc, _) = newNote("# From the sheet\n")
        let folder = dir.appendingPathComponent("picked").path
        doc.onCloseUnsaved = { _, decide in decide(.save) }
        doc.onNamePanel = { panel in
            XCTAssertEqual(panel.nameField.stringValue, "from-the-sheet", "the sheet offers the derived name")
            panel.onDone((name: panel.nameField.stringValue, folder: folder))
        }
        let spy = CloseSpy()
        doc.canClose(withDelegate: spy, shouldClose: #selector(CloseSpy.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        let deadline = Date().addingTimeInterval(5)
        while spy.answer == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(spy.answer, true)
        XCTAssertEqual(read(URL(fileURLWithPath: folder + "/from-the-sheet.md")), "# From the sheet\n")
        doc.close()
    }
}
