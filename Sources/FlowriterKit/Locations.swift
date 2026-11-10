import AppKit

/// The folders notes are saved in, and which one is the default: the folder the save sheet offers
/// first, so saving a new note is one Return.
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
}

/// The sheet behind the note's name in the top bar: the name, and the folder it is in. It saves
/// a note that has no file yet, and renames or moves one that has. The pop-up lists the saved
/// locations (the default first chosen) and always ends with "Other Folder…".
@MainActor
public final class NamePanel: NSPanel {
    public let nameField = NSTextField()
    public let folderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let message = NSTextField(labelWithString: "")
    private var locations: Locations
    /// A folder outside the saved locations: where the note is now, or one picked with "Other Folder…".
    private var otherFolder: String?
    private var lastSelection = 0
    /// Picks a folder for "Other Folder…"; nil when the writer cancels. Tests replace it.
    public var chooseFolder: () -> String? = {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    /// Why this name cannot be used in this folder, nil when it can.
    public var validate: (_ name: String, _ folder: String) -> String? = { _, _ in nil }
    public var onDone: ((name: String, folder: String)?) -> Void = { _ in }

    public init(heading: String, action: String, name: String, folder: String?, locations: Locations) {
        self.locations = locations
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150), styleMask: [.titled], backing: .buffered, defer: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: 114, width: 400, height: 18)
        nameField.stringValue = name
        nameField.placeholderString = "Name"
        nameField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        nameField.frame = NSRect(x: 20, y: 80, width: 400, height: 24)
        nameField.target = self
        nameField.action = #selector(commit)   // Return in the field
        nameField.setAccessibilityLabel("Name")
        message.font = .systemFont(ofSize: 11)
        message.textColor = .systemRed
        message.frame = NSRect(x: 20, y: 56, width: 400, height: 16)
        folderPopUp.frame = NSRect(x: 18, y: 16, width: 210, height: 26)
        folderPopUp.target = self
        folderPopUp.action = #selector(folderPicked)
        folderPopUp.setAccessibilityLabel("Location")
        let done = NSButton(title: action, target: self, action: #selector(commit))
        done.frame = NSRect(x: 336, y: 14, width: 88, height: 30)
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPanel))
        cancel.frame = NSRect(x: 248, y: 14, width: 88, height: 30)
        cancel.keyEquivalent = "\u{1B}"
        for v in [title, nameField, message, folderPopUp, cancel, done] { content.addSubview(v) }
        contentView = content
        initialFirstResponder = nameField
        if let folder = folder.map(Locations.normalized), !locations.folders.contains(folder) { otherFolder = folder }
        rebuildPopUp(select: folder.map(Locations.normalized) ?? locations.defaultFolder)
    }

    /// The folder the note will be in, nil when none is chosen yet.
    public var selectedFolder: String? { folderPopUp.selectedItem?.representedObject as? String }

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
        message.stringValue = ""
        guard selectedFolder == nil else { lastSelection = folderPopUp.indexOfSelectedItem; return }
        // "Other Folder…"
        if let path = chooseFolder().map(Locations.normalized) {
            otherFolder = path
            rebuildPopUp(select: path)
        } else {
            folderPopUp.selectItem(at: lastSelection)
        }
    }

    @objc private func commit() {
        if selectedFolder == nil { folderPicked() }
        guard let folder = selectedFolder else { return }
        let name = nameField.stringValue
        if Locations.notePath(in: folder, name: name) == nil { message.stringValue = "A name cannot hold \"..\"."; return }
        if let problem = validate(name, folder) { message.stringValue = problem; return }
        onDone((name, folder))
    }

    @objc private func cancelPanel() { onDone(nil) }
}

extension DocumentController {
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
