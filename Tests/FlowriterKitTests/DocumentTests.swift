import XCTest
import AppKit
@testable import FlowriterKit

@MainActor
final class DocumentTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        Drafts.directory = FileManager.default.temporaryDirectory.appendingPathComponent("flowriter-test-drafts-\(ProcessInfo.processInfo.processIdentifier)")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("flowriter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func open(_ url: URL) throws -> (Document, DocumentWindowController) {
        let doc = try Document(contentsOf: url, ofType: Document.markdownType)
        doc.makeWindowControllers()
        let controller = doc.windowControllers.first as! DocumentWindowController
        controller.keptDocument = doc
        controller.window?.setFrame(NSRect(x: -20000, y: -20000, width: 900, height: 700), display: false)
        return (doc, controller)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

    private func save(_ doc: Document) {
        let done = expectation(description: "saved")
        doc.save(to: doc.fileURL!, ofType: Document.markdownType, for: .saveOperation) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testOpenEditSaveRoundTrip() throws {
        let url = try file("a.md", "# Title\n\nBody.\n")
        let (doc, c) = try open(url)
        XCTAssertEqual(c.editor.string, "# Title\n\nBody.\n")
        c.editor.setSelectedRange(NSRange(location: (c.editor.string as NSString).length, length: 0))
        c.editor.insertText("More.", replacementRange: c.editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // the undo group of the event closes
        XCTAssertTrue(doc.isDocumentEdited, "typing marks the document edited")
        save(doc)
        XCTAssertEqual(read(url), "# Title\n\nBody.\nMore.\n", "the file holds the text, ending in one newline")
        XCTAssertEqual(c.editor.string, "# Title\n\nBody.\nMore.", "saving never changes the text on screen")
        doc.close()
    }

    func testAChangeOnDiskIsTakenWhenThereAreNoEditsHere() throws {
        let url = try file("b.md", "one\n")
        let (doc, c) = try open(url)
        c.editor.setSelectedRange(NSRange(location: 2, length: 0))
        try Data("one\ntwo from another program\n".utf8).write(to: url)
        doc.checkDisk()
        XCTAssertEqual(c.editor.string, "one\ntwo from another program\n")
        XCTAssertEqual(c.editor.selectedRange().location, 2, "the caret stays where it was")
        XCTAssertFalse(doc.isDocumentEdited)
        doc.close()
    }

    func testAChangeOnDiskNeverOverwritesEditsHereOrThere() throws {
        let url = try file("c.md", "one\n")
        let (doc, c) = try open(url)
        c.editor.insertText("mine ", replacementRange: NSRange(location: 0, length: 0))
        try Data("theirs\n".utf8).write(to: url)

        var asked = 0
        var resolve: ((Document.ConflictChoice) -> Void)?
        doc.onConflict = { _, r in asked += 1; resolve = r }
        doc.checkDisk()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(c.editor.string, "mine one\n", "the edits here are kept")
        XCTAssertEqual(read(url), "theirs\n", "the file is not overwritten")
        doc.checkDisk()
        XCTAssertEqual(asked, 1, "one question per conflict")

        resolve?(.useDisk)
        XCTAssertEqual(c.editor.string, "theirs\n")
        doc.close()
    }

    func testKeepMineWritesMyVersion() throws {
        let url = try file("d.md", "one\n")
        let (doc, c) = try open(url)
        c.editor.insertText("mine ", replacementRange: NSRange(location: 0, length: 0))
        try Data("theirs\n".utf8).write(to: url)
        var resolve: ((Document.ConflictChoice) -> Void)?
        doc.onConflict = { _, r in resolve = r }
        doc.checkDisk()
        resolve?(.keepMine)
        XCTAssertEqual(c.editor.string, "mine one\n")
        XCTAssertEqual(read(url), "theirs\n", "nothing is written before the usual save")
        save(doc)
        XCTAssertEqual(read(url), "mine one\n")
        c.editor.undoManager?.undo()
        XCTAssertEqual(c.editor.string, "theirs\n", "one undo shows the other program's version")
        doc.close()
    }

    func testTheFileIsSavedSoonAfterTyping() throws {
        let url = try file("auto.md", "one\n")
        let (doc, c) = try open(url)
        c.editor.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
        let waited = expectation(description: "autosave")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { waited.fulfill() }
        wait(for: [waited], timeout: 6)
        XCTAssertEqual(read(url), "typed one\n")
        XCTAssertFalse(doc.isDocumentEdited)
        doc.close()
    }

    /// No call from the test: the system tells the document that its file changed.
    func testTheSystemReportsAChangeOnDisk() throws {
        let url = try file("watched.md", "one\n")
        let (doc, c) = try open(url)
        NSDocumentController.shared.addDocument(doc)
        defer { doc.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try Data("changed by another program\n".utf8).write(to: url, options: .atomic)
        let deadline = Date().addingTimeInterval(6)
        while c.editor.string == "one\n", Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(c.editor.string, "changed by another program\n")
    }

    // MARK: notes

    func testNotesAreAPlainFileNextToTheDocument() throws {
        let url = try file("e.md", "text\n")
        let (doc, c) = try open(url)
        c.setNotesOpen(true)
        let typed = "idea one\n\n\n  indented, three blank lines above kept\n"
        c.drawer.textView.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
        doc.flushNotes()
        XCTAssertEqual(read(NotesStore.notesURL(for: url)), typed, "the notes file holds exactly what was typed")
        doc.close()

        let (again, c2) = try open(url)
        XCTAssertEqual(c2.drawer.textView.string, typed)
        XCTAssertTrue(c2.notesOpen, "the drawer comes back open")
        c2.drawer.textView.setSelectedRange(NSRange(location: 0, length: (typed as NSString).length))
        c2.drawer.textView.insertText("", replacementRange: c2.drawer.textView.selectedRange())
        again.flushNotes()
        XCTAssertFalse(FileManager.default.fileExists(atPath: NotesStore.notesURL(for: url).path), "empty notes leave no file")
        c2.setNotesOpen(false)
        again.close()
    }

    func testNotesOfTheOldSidecarAreRead() throws {
        let url = try file("f.md", "text\n")
        let legacy = #"{"schemaVersion":1,"alternatives":[],"ghosts":[],"overflow":[{"id":"b","text":"second","order":1},{"id":"a","text":"first\nline","order":0}]}"#
        try Data(legacy.utf8).write(to: NotesStore.legacyURL(for: url))
        let (doc, c) = try open(url)
        XCTAssertEqual(c.drawer.textView.string, "first\nline\n\nsecond")
        doc.close()
        XCTAssertEqual(read(NotesStore.legacyURL(for: url)), legacy, "the old sidecar is left as it is")
    }

    func testNotesFollowARename() throws {
        let url = try file("g.md", "text\n")
        try NotesStore.save("my notes", for: url)
        let (doc, _) = try open(url)
        let renamed = dir.appendingPathComponent("h.md")
        try FileManager.default.moveItem(at: url, to: renamed)
        doc.fileURL = renamed
        XCTAssertEqual(read(NotesStore.notesURL(for: renamed)), "my notes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: NotesStore.notesURL(for: url).path))
        doc.close()
    }
}
