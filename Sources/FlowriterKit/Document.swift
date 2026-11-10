import AppKit
import UniformTypeIdentifiers

/// One Markdown file. NSDocument gives saving in place, versions, rename, Open Recent and the
/// title bar. The editor's text storage holds the live text; this class reads and writes it, and
/// takes changes other programs make to the file.
public final class Document: NSDocument {
    public static let markdownType = "net.daringfireball.markdown"
    public static let lastDocumentKey = "FlowriterLastDocument"

    public enum ConflictChoice { case keepMine, useDisk }

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

    deinit { NotificationCenter.default.removeObserver(self) }

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
        guard fileURL != nil, hasUnautosavedChanges, !inConflict else { return }
        autosave(withImplicitCancellability: false) { _ in }
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
                } else {
                    // an untitled document got its place: the notes typed so far go with it
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
        guard notesDirty, let url = fileURL else { return }
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

    /// The document to show at launch: the last one that still exists.
    public var lastDocumentURL: URL? {
        let candidates = [UserDefaults.standard.string(forKey: Document.lastDocumentKey).map { URL(fileURLWithPath: $0) }] + recentDocumentURLs.map { Optional($0) }
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
