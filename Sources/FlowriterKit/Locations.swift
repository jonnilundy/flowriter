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

/// The one sheet for a note's name and place. It saves a note that has no file yet, renames or
/// moves one that has, and is also the question asked when a note with no file is closed (then
/// it has a Delete button). The pop-up lists the saved locations (the default first chosen) and
/// always ends with "Other Folder…". It is drawn in the page's own colours and typeface.
@MainActor
public final class NamePanel: NSPanel, NSTextFieldDelegate {
    public enum Mode { case save, rename, close }
    public enum Outcome: Equatable { case name(String, folder: String), delete, cancel }

    public let mode: Mode
    public let nameField: NSTextField = SheetField()
    public let folderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Only in `.close` mode.
    public private(set) var deleteButton: NSButton?
    private let message = NSTextField(labelWithString: "")
    /// ".md" after the typed name, dimmed: the extension the file gets without typing it.
    public let suffix = NSTextField(labelWithString: ".md")
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
    public var onDone: (Outcome) -> Void = { _ in }

    public init(mode: Mode, name: String, folder: String?, locations: Locations) {
        self.mode = mode
        self.locations = locations
        let width: CGFloat = 420, height: CGFloat = 204, inset: CGFloat = 24
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: true)
        backgroundColor = Theme.background
        let content = SheetBackground(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let mono = Theme.mono

        let title = NSTextField(labelWithString: mode == .rename ? "Rename note" : "Save note")
        title.font = mono(13, .semibold)
        title.textColor = Theme.heading
        title.frame = NSRect(x: inset, y: height - 42, width: width - 2 * inset, height: 18)

        let box = SheetBox(frame: NSRect(x: inset, y: height - 86, width: width - 2 * inset, height: 32))
        nameField.stringValue = name
        nameField.placeholderString = "name"
        nameField.font = mono(13, .regular)
        nameField.textColor = Theme.text
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingHead
        suffix.font = mono(13, .regular)
        suffix.textColor = Theme.mark
        suffix.sizeToFit()
        nameField.frame = NSRect(x: 10, y: 7, width: box.frame.width - 20 - suffix.frame.width, height: 18)
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commit)   // Return in the field
        nameField.setAccessibilityLabel("Name")
        box.addSubview(nameField)
        box.addSubview(suffix)

        folderPopUp.isBordered = false
        folderPopUp.font = mono(12, .regular)
        folderPopUp.contentTintColor = Theme.secondary
        folderPopUp.target = self
        folderPopUp.action = #selector(folderPicked)
        folderPopUp.setAccessibilityLabel("Location")
        folderPopUp.frame = NSRect(x: inset + 2, y: height - 122, width: 200, height: 22)

        message.font = mono(11, .regular)
        message.lineBreakMode = .byTruncatingMiddle
        message.frame = NSRect(x: inset, y: 60, width: width - 2 * inset, height: 15)

        let done = SheetButton(mode == .rename ? "Rename" : "Save", primary: true, target: self, action: #selector(commit))
        done.keyEquivalent = "\r"
        let cancel = SheetButton("Cancel", primary: false, target: self, action: #selector(cancelPanel))
        cancel.keyEquivalent = "\u{1B}"
        done.frame.origin = NSPoint(x: width - inset - done.frame.width, y: 18)
        cancel.frame.origin = NSPoint(x: done.frame.minX - 6 - cancel.frame.width, y: 18)
        var views: [NSView] = [title, box, folderPopUp, message, cancel, done]
        if mode == .close {
            let delete = SheetButton("Delete", primary: false, target: self, action: #selector(deleteNote))
            delete.frame.origin = NSPoint(x: inset - SheetButton.pad, y: 18)
            deleteButton = delete
            views.append(delete)
        }
        views.forEach(content.addSubview)
        contentView = content
        initialFirstResponder = nameField
        if let folder = folder.map(Locations.normalized), !locations.folders.contains(folder) { otherFolder = folder }
        rebuildPopUp(select: folder.map(Locations.normalized) ?? locations.defaultFolder)
        show(problem: nil)
        placeSuffix()
    }

    public func controlTextDidChange(_ obj: Notification) { placeSuffix() }

    /// Put ".md" right after the name. A name typed with its own extension keeps it: no ".md" then.
    private func placeSuffix() {
        let name = nameField.stringValue
        let lower = name.lowercased()
        suffix.isHidden = lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".txt")
        let shown = name.isEmpty ? (nameField.placeholderString ?? "") : name
        let width = (shown as NSString).size(withAttributes: [.font: nameField.font as Any]).width
        suffix.frame.origin = NSPoint(x: min(nameField.frame.minX + 2 + width.rounded(.up), nameField.frame.maxX), y: nameField.frame.minY)
    }

    /// The folder the note will be in, nil when none is chosen yet.
    public var selectedFolder: String? { folderPopUp.selectedItem?.representedObject as? String }
    /// The line under the location: why the name cannot be used.
    public var messageText: String { message.stringValue }

    private func show(problem: String?) {
        message.stringValue = problem ?? ""
        message.textColor = Theme.accent
    }

    private func rebuildPopUp(select: String?) {
        folderPopUp.removeAllItems()
        folderPopUp.menu?.font = folderPopUp.font
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
        // the arrows sit next to the folder's name
        let origin = folderPopUp.frame.origin
        let title = (folderPopUp.titleOfSelectedItem ?? "") as NSString
        let width = title.size(withAttributes: [.font: folderPopUp.font as Any]).width + 36
        folderPopUp.frame = NSRect(x: origin.x, y: origin.y, width: min(width.rounded(.up), 368), height: 22)
    }

    @objc private func folderPicked() {
        show(problem: nil)
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
        if Locations.notePath(in: folder, name: name) == nil { show(problem: "A name cannot hold \"..\"."); return }
        if let problem = validate(name, folder) { show(problem: problem); return }
        onDone(.name(name, folder: folder))
    }

    // Off screen (the test driver) the sheet stays off screen too.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        AppDelegate.offScreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(AppDelegate.parked(frameRect), display: flag)
    }
    public override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(AppDelegate.parked(frameRect), display: displayFlag, animate: animateFlag && !AppDelegate.offScreen)
    }
    public override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(AppDelegate.parked(NSRect(origin: point, size: frame.size)).origin)
    }

    /// Command-Delete is Delete, as in the system's own save question.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = event.charactersIgnoringModifiers
        if deleteButton != nil, event.modifierFlags.intersection([.command, .option, .control]) == .command, key == "\u{7F}" || key == "\u{8}" {
            deleteNote()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func cancelPanel() { onDone(.cancel) }
    @objc private func deleteNote() { onDone(.delete) }
}

/// The name field: the caret and the selection have the page's colours.
private final class SheetField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = Theme.accent
            editor.selectedTextAttributes = [.backgroundColor: Theme.selection]
        }
        return ok
    }
}

/// The sheet's surface: the page's own colour (a titled panel puts a lighter one behind its content).
private final class SheetBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { Theme.background.setFill(); bounds.fill() }
}

/// The quiet box around the name field.
private final class SheetBox: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.codeBackground.setFill()
        path.fill()
        Theme.hairline.setStroke()
        path.stroke()
    }
}

/// A flat text button. The primary one is filled with the accent.
final class SheetButton: NSButton {
    static let pad: CGFloat = 14
    private var primary = false
    private var pressed = false

    convenience init(_ title: String, primary: Bool, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.primary = primary
        self.target = target
        self.action = action
        isBordered = false
        font = Theme.mono(12, primary ? .semibold : .regular)
        let text = (title as NSString).size(withAttributes: [.font: font!])
        frame.size = NSSize(width: (text.width + 2 * Self.pad).rounded(.up), height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        if primary {
            Theme.accent.withAlphaComponent(pressed ? 0.7 : 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let color = primary ? Theme.background : Theme.secondary.withAlphaComponent(pressed ? 0.55 : 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true; needsDisplay = true
        super.mouseDown(with: event)   // returns when the button is let go
        pressed = false; needsDisplay = true
    }
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
