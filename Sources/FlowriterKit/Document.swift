import AppKit
import UniformTypeIdentifiers

/// One note. With a file, NSDocument saves it in place, keeps versions and Open Recent, and this
/// class takes the changes other programs make to the file. Without a file yet, the note is a
/// draft: it is kept in `Drafts` as it is typed, comes back after a quit, and gets its file from
/// the name sheet. The editor's text storage always holds the live text.
public final class Document: NSDocument {
    public static let markdownType = "net.daringfireball.markdown"
    public static let lastDocumentKey = "FlowriterLastDocument"

    public enum ConflictChoice { case keepMine, useDisk }
    public enum CloseChoice { case save, delete, cancel }

    /// The file's text as last read or written by this document.
    public private(set) var diskText = ""
    /// The live text (the window's editor), nil before a window exists.
    public var liveText: (() -> String)?
    /// The text was read again from disk: the window shows it.
    public var onReload: ((String) -> Void)?
    /// Replace the whole text as one undoable edit: the window does it through the editor.
    public var onReplaceText: ((String) -> Void)?
    /// A save finished or a reload replaced the text: what the window shows as unsaved may have changed.
    public var onSaveStateChange: (() -> Void)?
    /// The file changed on disk while there are edits here. The default asks in a sheet.
    public var onConflict: ((Document, @escaping (ConflictChoice) -> Void) -> Void)?
    /// A note with no file is about to close. The default asks in a sheet.
    public var onCloseUnsaved: ((Document, @escaping (CloseChoice) -> Void) -> Void)?
    /// The name sheet is about to show (tests answer it here).
    public var onNamePanel: ((NamePanel) -> Void)?

    /// The draft this note is kept under while it has no file.
    public private(set) var draftID: String?
    private var draftDiscarded = false

    public private(set) var notes = ""
    private var notesDirty = false
    private var notesTimer: Timer?
    private var autosaveTimer: Timer?
    private var inConflict = false
    private var encoding = String.Encoding.utf8

    public override class var autosavesInPlace: Bool { true }

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(flushNotes), name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(flushNotes), name: NSApplication.didResignActiveNotification, object: nil)
    }

    /// A draft brought back after a quit: its text, its notes, still without a file.
    public convenience init(draft: Draft) {
        self.init()
        draftID = draft.id
        diskText = draft.text
        notes = draft.notes
        updateChangeCount(.changeDone)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// A note with no file is named after its first line. One with a file shows the file's whole
    /// name, extension included, whatever the Finder is set to hide.
    public override var displayName: String! {
        get { fileURL?.lastPathComponent ?? NoteName.derive(from: currentText) }
        set { super.displayName = newValue }
    }

    public var currentText: String { liveText?() ?? diskText }

    // MARK: reading and writing

    public override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    public override func read(from data: Data, ofType typeName: String) throws {
        let text: String
        if let s = String(data: data, encoding: .utf8) {
            text = s; encoding = .utf8
        } else if let s = String(data: data, encoding: .utf16) {
            text = s; encoding = .utf16
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""; encoding = .isoLatin1
        }
        diskText = text
        inConflict = false
        onReload?(text)
        onSaveStateChange?()
    }

    /// What goes to disk: the editor's text, ending in a newline.
    public func serialized() -> String {
        let text = currentText
        return text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
    }

    public override func data(ofType typeName: String) throws -> Data {
        let text = serialized()
        guard let data = text.data(using: encoding) ?? text.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        diskText = text
        return data
    }

    public override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                              completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            completionHandler(error)
            self?.onSaveStateChange?()
        }
    }

    public override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [Document.markdownType] }
    public override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { "md" }
    public override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        return true
    }

    // MARK: saving soon after typing

    /// The editor's text changed.
    public func textDidChange() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in self?.autosaveNow() }
    }

    private func autosaveNow() {
        autosaveTimer = nil
        guard fileURL != nil else { saveDraft(); onSaveStateChange?(); return }
        guard hasUnautosavedChanges, !inConflict else { return }
        autosave(withImplicitCancellability: false) { _ in }
    }

    /// A note with no file is never autosaved by the system (it would keep its own hidden copy
    /// and bring it back beside ours): its draft is written instead.
    public override func autosave(withImplicitCancellability implicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        guard fileURL == nil else { super.autosave(withImplicitCancellability: implicitlyCancellable, completionHandler: completionHandler); return }
        saveDraft()
        updateChangeCount(.changeAutosaved)
        completionHandler(nil)
    }

    // MARK: a note with no file yet

    /// Write the draft now (typing does it after a pause; quitting does it at once).
    public func saveDraft() {
        guard fileURL == nil, !draftDiscarded else { return }
        let id = draftID ?? UUID().uuidString
        draftID = id
        Drafts.write(Draft(id: id, text: currentText, notes: notes))
    }

    private func discardDraft() {
        draftDiscarded = true
        autosaveTimer?.invalidate()
        if let id = draftID { Drafts.remove(id) }
        draftID = nil
    }

    /// Command-S on a note with no file opens the name sheet; with a file it saves a version.
    @objc public override func save(_ sender: Any?) {
        if fileURL == nil { presentNamePanel() } else { super.save(sender) }
    }

    /// The sheet behind the name in the top bar: save a note that has no file, rename or move one
    /// that has. `completion` gets true when the note ends up in the file asked for.
    public func presentNamePanel(completion: @escaping (Bool) -> Void = { _ in }) {
        let current = fileURL
        let name = current?.deletingPathExtension().lastPathComponent ?? NoteName.derive(from: currentText)
        let panel = NamePanel(heading: current == nil ? "Save note" : "Rename note", action: current == nil ? "Save" : "Rename",
                              name: name, folder: current?.deletingLastPathComponent().path, locations: .load())
        panel.validate = { [weak self] name, folder in self?.problem(name: name, folder: folder) }
        let host = windowControllers.first?.window
        panel.onDone = { [weak self, weak panel] result in
            if let panel { if let host, panel.sheetParent === host { host.endSheet(panel) } else { NSApp.stopModal(); panel.orderOut(nil) } }
            guard let self, let (name, folder) = result else { completion(false); return }
            self.setName(name, folder: folder, completion: completion)
        }
        if let onNamePanel { onNamePanel(panel); return }
        if let host { host.beginSheet(panel) } else { NSApp.runModal(for: panel) }
    }

    /// Why the note cannot take this name in this folder, nil when it can.
    public func problem(name: String, folder: String) -> String? {
        guard let path = Locations.notePath(in: folder, name: name) else { return "A name cannot hold \"..\"." }
        if path == fileURL?.path { return nil }
        return FileManager.default.fileExists(atPath: path) ? "“\((path as NSString).lastPathComponent)” is already in that folder." : nil
    }

    /// Put the note in `<folder>/<name>.md`: the first save of a note with no file, or a rename
    /// or move of one that has. A file that is already there is never replaced.
    public func setName(_ name: String, folder: String, completion: @escaping (Bool) -> Void = { _ in }) {
        guard problem(name: name, folder: folder) == nil, let path = Locations.notePath(in: folder, name: name) else { completion(false); return }
        let url = URL(fileURLWithPath: path)
        guard url != fileURL else { completion(true); return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            presentError(error); completion(false); return
        }
        // the first folder ever used becomes the first saved location, and the default
        var locations = Locations.load()
        if locations.folders.isEmpty { locations.add(folder); locations.save() }
        let finish: (Error?) -> Void = { [weak self] error in
            if let error { self?.presentError(error) }
            self?.onSaveStateChange?()
            completion(error == nil)
        }
        if fileURL == nil {
            save(to: url, ofType: Document.markdownType, for: .saveAsOperation, completionHandler: finish)
        } else {
            flushNotes()
            move(to: url, completionHandler: finish)
        }
    }

    /// Closing a note with no file: an empty one just goes; one with text asks first.
    public override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard fileURL == nil else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let reply: (Bool) -> Void = { [weak self] close in
            guard let self, let selector = shouldCloseSelector, let target = delegate as AnyObject?, let method = target.method(for: selector) else { return }
            typealias ShouldClose = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(method, to: ShouldClose.self)(target, selector, self, close, contextInfo)
        }
        if currentText.isEmpty && notes.isEmpty { discardDraft(); updateChangeCount(.changeCleared); reply(true); return }
        let decide: (CloseChoice) -> Void = { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .cancel: reply(false)
            case .delete: self.discardDraft(); self.updateChangeCount(.changeCleared); reply(true)
            case .save: self.presentNamePanel { saved in reply(saved) }
            }
        }
        if let onCloseUnsaved { onCloseUnsaved(self, decide); return }
        let alert = NSAlert()
        alert.messageText = "Save “\(displayName ?? NoteName.fallback)”?"
        alert.informativeText = "This note is not in a file yet."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { response in
            decide(response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .delete : .cancel)
        }
        if let window = windowControllers.first?.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    // MARK: changes made by other programs

    public override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.checkDisk() }
    }

    @objc private func appDidBecomeActive() { checkDisk() }

    /// Take the file's text when it changed on disk. With edits here that are not on disk yet,
    /// nothing is overwritten on either side until the writer chooses.
    public func checkDisk() {
        guard !inConflict, let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let onDisk = String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
        guard onDisk != diskText else { return }   // our own save, or nothing new
        if serialized() == diskText || currentText == diskText {
            reload(from: url)
            return
        }
        inConflict = true
        let resolve: (ConflictChoice) -> Void = { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .useDisk:
                self.reload(from: url)
            case .keepMine:
                // Take the disk version, then put my text back as one edit: the document saves it the
                // usual way, and one undo shows the other program's version again.
                let mine = self.currentText
                self.reload(from: url)
                self.onReplaceText?(mine)
            }
        }
        if let onConflict { onConflict(self, resolve) } else { askAboutConflict(resolve) }
    }

    private func reload(from url: URL) {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        do {
            try revert(toContentsOf: url, ofType: fileType ?? Document.markdownType)
        } catch {
            inConflict = false
        }
    }

    private func askAboutConflict(_ resolve: @escaping (ConflictChoice) -> Void) {
        let alert = NSAlert()
        alert.messageText = "“\(displayName ?? "This document")” changed on disk."
        alert.informativeText = "Another program saved this file while you have edits here that are not saved yet."
        alert.addButton(withTitle: "Keep My Version")
        alert.addButton(withTitle: "Use Disk Version")
        let done: (NSApplication.ModalResponse) -> Void = { resolve($0 == .alertFirstButtonReturn ? .keepMine : .useDisk) }
        if let window = windowControllers.first?.window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }

    // MARK: notes

    public override var fileURL: URL? {
        didSet {
            guard fileURL != oldValue else { return }
            if let new = fileURL {
                UserDefaults.standard.set(new.path, forKey: Document.lastDocumentKey)
                if let old = oldValue {
                    // a rename or a move takes the notes file along; Save As writes a copy
                    if !FileManager.default.fileExists(atPath: old.path) { NotesStore.move(from: old, to: new) }
                    notesDirty = !notes.isEmpty
                    flushNotes()
                } else if notes.isEmpty {
                    notes = NotesStore.load(for: new)
                    discardDraft()
                } else {
                    // a note got its file: the notes typed so far go with it, and the draft is done
                    discardDraft()
                    notesDirty = true
                    flushNotes()
                }
            }
        }
    }

    public func setNotes(_ text: String) {
        guard text != notes else { return }
        notes = text
        notesDirty = true
        notesTimer?.invalidate()
        notesTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.flushNotes() }
    }

    @objc public func flushNotes() {
        notesTimer?.invalidate()
        notesTimer = nil
        guard notesDirty else { return }
        guard let url = fileURL else { saveDraft(); return }
        notesDirty = false
        try? NotesStore.save(notes, for: url)
    }

    public override func close() {
        flushNotes()
        autosaveTimer?.invalidate()
        super.close()
    }
}

/// Maps every file this app opens to `Document`, with or without an Info.plist (a build run from
/// the command line has none).
public final class DocumentController: NSDocumentController {
    public override var documentClassNames: [String] { [NSStringFromClass(Document.self)] }
    public override var defaultType: String? { Document.markdownType }
    public override func documentClass(forType typeName: String) -> AnyClass? { Document.self }
    public override func typeForContents(of url: URL) throws -> String { Document.markdownType }
    public override func displayName(forType typeName: String) -> String? { "Markdown" }

    public override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        openPanel.allowedContentTypes = [.plainText] + ["md", "markdown", "mdx", "txt"].compactMap { UTType(filenameExtension: $0) }
        return openPanel.runModal().rawValue
    }

    /// Quitting never asks. Notes with no file are kept as drafts and come back at the next
    /// launch; files with changes are saved first; the list of open files is remembered. `done`
    /// runs when everything is on disk.
    public func prepareToQuit(done: @escaping () -> Void) {
        let all = documents.compactMap { $0 as? Document }
        // the frontmost file is listed last, so it is opened last and ends up in front again
        let front = (NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.windowController?.document is Document })?.windowController?.document as? Document
        let files = all.filter { $0.fileURL != nil }.sorted { a, _ in a !== front }
        UserDefaults.standard.set(files.compactMap { $0.fileURL?.path }, forKey: AppDelegate.openDocumentsKey)
        for document in all where document.fileURL == nil { document.saveDraft() }   // gives each draft its id
        let frontName = front.flatMap { $0.fileURL?.path ?? $0.draftID.map { "draft:" + $0 } }
        UserDefaults.standard.set(frontName, forKey: AppDelegate.frontDocumentKey)
        var pending = 1   // this pass itself, so `done` cannot run before the loop ends
        let finish = {
            pending -= 1
            if pending == 0 { done() }
        }
        for document in all {
            document.flushNotes()
            if document.fileURL == nil {
                document.saveDraft()
                document.updateChangeCount(.changeCleared)
            } else if document.hasUnautosavedChanges {
                pending += 1
                document.autosave(withImplicitCancellability: false) { _ in finish() }
            }
        }
        finish()
    }

    /// Set when the review below has already run `prepareToQuit` for the quit in progress: AppKit
    /// closes the documents after it, so a second pass would remember an empty list of open files.
    var preparedThisQuit = false

    /// AppKit asks this at Quit, before the app delegate, and would put up "review unsaved
    /// changes" for every note with no file. Nothing is unsaved after `prepareToQuit`.
    public override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                                didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        preparedThisQuit = true
        prepareToQuit { [weak self] in
            guard let self, let selector = didReviewAllSelector, let target = delegate as AnyObject?, let method = target.method(for: selector) else { return }
            typealias DidReview = @convention(c) (AnyObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(method, to: DidReview.self)(target, selector, self, true, contextInfo)
        }
    }

    /// The file to show at the first launch after an update that has no list of open files yet:
    /// the last one used, when it still exists.
    public var lastDocumentURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Document.lastDocumentKey), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
