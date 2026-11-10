import AppKit

/// The folders new notes go in, and which one is the default. With a default set, Command-N asks
/// for a name only: the note is created there and opened.
public struct Locations: Equatable {
    public static let listKey = "FlowriterLocations"
    public static let defaultKey = "FlowriterDefaultLocation"

    /// Absolute folder paths, in the order they were added.
    public private(set) var folders: [String]
    public private(set) var defaultFolder: String?

    public init(folders: [String] = [], defaultFolder: String? = nil) {
        var seen = Set<String>()
        self.folders = folders.map(Self.normalized).filter { !$0.isEmpty && seen.insert($0).inserted }
        let d = defaultFolder.map(Self.normalized)
        self.defaultFolder = d.flatMap { self.folders.contains($0) ? $0 : nil } ?? self.folders.first
    }

    public static func load(_ defaults: UserDefaults = .standard) -> Locations {
        Locations(folders: defaults.stringArray(forKey: listKey) ?? [], defaultFolder: defaults.string(forKey: defaultKey))
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(folders, forKey: Self.listKey)
        if let d = defaultFolder { defaults.set(d, forKey: Self.defaultKey) } else { defaults.removeObject(forKey: Self.defaultKey) }
    }

    /// Add a folder. The first folder added is the default.
    public mutating func add(_ path: String) {
        let p = Self.normalized(path)
        guard !p.isEmpty, !folders.contains(p) else { return }
        folders.append(p)
        if defaultFolder == nil { defaultFolder = p }
    }

    /// Remove a folder from the list (the folder on disk is not touched). When it was the default,
    /// the first folder left is the default.
    public mutating func remove(_ path: String) {
        let p = Self.normalized(path)
        folders.removeAll { $0 == p }
        if defaultFolder == p { defaultFolder = folders.first }
    }

    public mutating func setDefault(_ path: String) {
        let p = Self.normalized(path)
        if folders.contains(p) { defaultFolder = p }
    }

    /// Absolute, "~" expanded, no trailing slash.
    public static func normalized(_ path: String) -> String {
        var p = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// "/Users/me/Notes" as "~/Notes".
    public static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// What a folder is called in menus: its own name, or its path when two folders share a name.
    public func title(for folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        let twins = folders.filter { ($0 as NSString).lastPathComponent == name }.count
        return twins > 1 || name.isEmpty ? Self.abbreviated(folder) : name
    }

    /// The file a typed name stands for in a folder: "idea" is "<folder>/idea.md", "drafts/idea" goes
    /// in a subfolder, an empty name is "Untitled". Nil for a name with a ".." part: a note never
    /// leaves its folder.
    public static func notePath(in folder: String, name: String) -> String? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains("..") else { return nil }
        var file = parts.isEmpty ? "Untitled" : parts.joined(separator: "/")
        let lower = file.lowercased()
        if !(lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".txt")) { file += ".md" }
        return normalized(folder) + "/" + file
    }

    /// What a new note holds: the start of a title, the caret after it.
    public static let newNoteText = "# "

    /// Create the note's file if there is none yet (an existing file is opened as it is).
    @discardableResult
    public static func createNote(in folder: String, name: String) throws -> URL {
        guard let path = notePath(in: folder, name: name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { try Data(newNoteText.utf8).write(to: url, options: .withoutOverwriting) }
        return url
    }
}

/// The New Note sheet: a name, and the folder it goes in. Return creates the note in the default
/// location; the pop-up picks another saved location or any other folder.
@MainActor
final class NewNotePanel: NSPanel, NSTextFieldDelegate {
    let nameField = NSTextField()
    let folderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var locations: Locations
    /// A folder picked with "Other Folder…" for this note only.
    private var otherFolder: String?
    private var lastSelection = 0
    /// Picks a folder for "Other Folder…"; nil when the writer cancels. Tests replace it.
    var chooseFolder: () -> String? = {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    var onDone: ((name: String, folder: String)?) -> Void = { _ in }

    init(locations: Locations) {
        self.locations = locations
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 138), styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 138))
        let title = NSTextField(labelWithString: "New note")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: 102, width: 400, height: 18)
        nameField.placeholderString = "Name"
        nameField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        nameField.frame = NSRect(x: 20, y: 66, width: 400, height: 24)
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(create)   // Return in the field creates the note
        nameField.setAccessibilityLabel("Name")
        folderPopUp.frame = NSRect(x: 18, y: 16, width: 200, height: 26)
        folderPopUp.target = self
        folderPopUp.action = #selector(folderPicked)
        folderPopUp.setAccessibilityLabel("Location")
        createButton.frame = NSRect(x: 336, y: 14, width: 88, height: 30)
        createButton.keyEquivalent = "\r"
        createButton.target = self
        createButton.action = #selector(create)
        cancelButton.frame = NSRect(x: 248, y: 14, width: 88, height: 30)
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        for v in [title, nameField, folderPopUp, cancelButton, createButton] { content.addSubview(v) }
        contentView = content
        initialFirstResponder = nameField
        rebuildPopUp(select: locations.defaultFolder)
    }

    /// The folder the note will go in, nil when none is chosen yet.
    var selectedFolder: String? { folderPopUp.selectedItem?.representedObject as? String }

    private func rebuildPopUp(select: String?) {
        folderPopUp.removeAllItems()
        var folders = locations.folders
        if let other = otherFolder, !folders.contains(other) { folders.append(other) }
        for folder in folders {
            folderPopUp.addItem(withTitle: locations.folders.contains(folder) ? locations.title(for: folder) : Locations.abbreviated(folder))
            folderPopUp.lastItem?.representedObject = folder
            folderPopUp.lastItem?.toolTip = Locations.abbreviated(folder)
        }
        if !folders.isEmpty { folderPopUp.menu?.addItem(.separator()) }
        folderPopUp.addItem(withTitle: "Other Folder…")
        if let select, let i = folderPopUp.itemArray.firstIndex(where: { $0.representedObject as? String == select }) {
            folderPopUp.selectItem(at: i)
        } else {
            folderPopUp.selectItem(at: folders.isEmpty ? folderPopUp.numberOfItems - 1 : 0)
        }
        lastSelection = folderPopUp.indexOfSelectedItem
    }

    @objc private func folderPicked() {
        guard selectedFolder == nil else { lastSelection = folderPopUp.indexOfSelectedItem; return }
        // "Other Folder…"
        if let path = chooseFolder().map(Locations.normalized) {
            otherFolder = path
            rebuildPopUp(select: path)
        } else {
            folderPopUp.selectItem(at: lastSelection)
        }
    }

    @objc private func create() {
        if selectedFolder == nil { folderPicked() }
        guard let folder = selectedFolder else { return }
        guard Locations.notePath(in: folder, name: nameField.stringValue) != nil else { NSSound.beep(); return }
        onDone((nameField.stringValue, folder))
    }

    @objc private func cancel() { onDone(nil) }
}

extension DocumentController {
    /// File > New Note: ask for a name, create the note in the chosen location, open it.
    @objc public func newNote(_ sender: Any?) {
        let panel = NewNotePanel(locations: .load())
        let host = NSApp.mainWindow ?? NSApp.keyWindow ?? documents.compactMap { $0.windowControllers.first?.window }.last
        panel.onDone = { [weak self, weak panel] result in
            guard let self, let panel else { return }
            if let host, panel.sheetParent === host { host.endSheet(panel) } else { NSApp.stopModal(); panel.orderOut(nil) }
            guard let (name, folder) = result else { return }
            // a folder picked while there are no saved locations becomes the first one, and the default
            var locations = Locations.load()
            if locations.folders.isEmpty { locations.add(folder); locations.save() }
            self.openNewNote(name: name, in: folder)
        }
        if let host { host.beginSheet(panel) } else { NSApp.runModal(for: panel) }
    }

    /// Create the note's file and open it with the caret at the end. An empty untitled window the
    /// note was started from goes away.
    public func openNewNote(name: String, in folder: String) {
        let pristine = documents.compactMap { $0 as? Document }.filter { $0.fileURL == nil && !$0.isDocumentEdited && $0.currentText.isEmpty && $0.notes.isEmpty }
        do {
            let url = try Locations.createNote(in: folder, name: name)
            openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error { NSApp.presentError(error); return }
                if let controller = document?.windowControllers.first as? DocumentWindowController {
                    let end = (controller.editor.string as NSString).length
                    controller.editor.setSelectedRange(NSRange(location: end, length: 0))
                    controller.window?.makeFirstResponder(controller.editor)
                }
                for old in pristine where old !== document { old.close() }
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func addLocation(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose a folder for new notes."
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        var locations = Locations.load()
        locations.add(path)
        locations.save()
    }

    @objc func setDefaultLocation(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var locations = Locations.load()
        locations.setDefault(path)
        locations.save()
    }

    @objc func removeLocation(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var locations = Locations.load()
        locations.remove(path)
        locations.save()
    }
}

/// File > Locations: the saved folders (the default has the check mark; choosing one makes it the
/// default), Add Folder…, and Remove.
@MainActor
final class LocationsMenu: NSObject, NSMenuDelegate {
    static let shared = LocationsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let locations = Locations.load()
        let controller = NSDocumentController.shared
        for folder in locations.folders {
            let item = menu.addItem(withTitle: locations.title(for: folder), action: #selector(DocumentController.setDefaultLocation(_:)), keyEquivalent: "")
            item.target = controller
            item.representedObject = folder
            item.state = folder == locations.defaultFolder ? .on : .off
            item.toolTip = Locations.abbreviated(folder) + (folder == locations.defaultFolder ? " (new notes go here)" : "")
        }
        if locations.folders.isEmpty {
            menu.addItem(withTitle: "No Locations Yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Folder…", action: #selector(DocumentController.addLocation(_:)), keyEquivalent: "").target = controller
        if !locations.folders.isEmpty {
            let remove = NSMenu(title: "Remove")
            for folder in locations.folders {
                let item = remove.addItem(withTitle: locations.title(for: folder), action: #selector(DocumentController.removeLocation(_:)), keyEquivalent: "")
                item.target = controller
                item.representedObject = folder
            }
            menu.addItem(withTitle: "Remove", action: nil, keyEquivalent: "").submenu = remove
        }
    }
}
