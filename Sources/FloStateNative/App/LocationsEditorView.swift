import AppKit
import FloCore

/// The edits of the writing locations list, with no UI: what the Settings editor changes and what it
/// writes back. Every edit works on the whole list (a default that was set before the list existed is
/// already in it as the first location), so editing that row writes it into the list.
struct LocationsState: Equatable {
    var locations: [NoteLocation]
    /// The default's path as stored in `files.default-note-location`; empty: no default.
    var defaultPath: String

    init(locations: [NoteLocation], defaultPath: String) {
        self.locations = locations
        self.defaultPath = defaultPath
    }

    init(_ values: SettingsValues) {
        self.init(locations: values.noteLocations, defaultPath: values.filesDefaultNoteLocation)
    }

    func isDefault(_ index: Int) -> Bool {
        let d = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !d.isEmpty && NewNoteLocation.normalized(d) == locations[index].normalizedPath
    }

    /// Click the marker: make this location the default, or clear the default when it already is.
    mutating func toggleDefault(at index: Int) {
        defaultPath = isDefault(index) ? "" : locations[index].path
    }

    /// Sets the nickname. False when nothing changed.
    @discardableResult
    mutating func rename(at index: Int, to nickname: String) -> Bool {
        let clean = NoteLocation.cleanNickname(nickname)
        guard locations[index].nickname != clean else { return false }
        locations[index].nickname = clean
        return true
    }

    /// Points a location at another folder, keeping its nickname and its default status. False when
    /// nothing changed (the same folder, or a folder another row already lists).
    @discardableResult
    mutating func changeFolder(at index: Int, to path: String) -> Bool {
        let moved = NoteLocation(nickname: locations[index].nickname, path: NewNoteLocation.normalized(path))
        guard moved.normalizedPath != locations[index].normalizedPath,
              !locations.indices.contains(where: { $0 != index && locations[$0].normalizedPath == moved.normalizedPath })
        else { return false }
        if isDefault(index) { defaultPath = moved.path }
        locations[index] = moved
        return true
    }

    mutating func remove(at index: Int) {
        let removed = locations.remove(at: index)
        defaultPath = NoteLocations.defaultPath(afterRemoving: removed, defaultPath: defaultPath)
    }

    /// Appends a folder. False when it is already listed.
    @discardableResult
    mutating func add(path: String) -> Bool {
        let added = NoteLocations.adding(NoteLocation(path: NewNoteLocation.normalized(path)), to: locations)
        guard added != locations else { return false }
        locations = added
        return true
    }

    /// The lines for `files.note-locations`; nil: store nothing (an empty list cannot be stored, reset the key).
    var storedLines: [String]? { locations.isEmpty ? nil : NoteLocations.encode(locations) }

    /// The value for `files.default-note-location`; nil: reset the key.
    var storedDefault: String? {
        defaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : defaultPath
    }

    /// What the rows show apart from nicknames. When it matches what is on screen the rows are kept
    /// (so a nickname being typed keeps its focus); when it differs they are rebuilt.
    func structure(fileManager fm: FileManager = .default) -> [String] {
        locations.indices.map { i in
            let p = NoteLocations.problem(locations[i], fileManager: fm)
            return "\(locations[i].normalizedPath)|\(isDefault(i))|\(p.map { "\($0)" } ?? "ok")"
        }
    }
}

/// One location: default marker, nickname, path, Change… and remove.
@MainActor
final class LocationRowView: NSStackView {
    let marker = NSButton()
    let nickname = NSTextField(string: "")
    let pathLabel = NSTextField(labelWithString: "")
    let changeButton = NSButton(title: L("Change…"), target: nil, action: nil)
    let removeButton = NSButton()
    var onToggleDefault: () -> Void = {}
    var onChange: () -> Void = {}
    var onRemove: () -> Void = {}

    static let nicknameWidth: CGFloat = 110
    static let pathWidth: CGFloat = 190

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY

        marker.isBordered = false
        marker.imagePosition = .imageOnly
        marker.imageScaling = .scaleProportionallyDown
        marker.target = self; marker.action = #selector(markerClicked)
        marker.widthAnchor.constraint(equalToConstant: 18).isActive = true
        marker.heightAnchor.constraint(equalToConstant: 18).isActive = true

        nickname.widthAnchor.constraint(equalToConstant: Self.nicknameWidth).isActive = true
        nickname.lineBreakMode = .byTruncatingTail
        nickname.cell?.sendsActionOnEndEditing = true

        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.widthAnchor.constraint(equalToConstant: Self.pathWidth).isActive = true

        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        changeButton.target = self; changeButton.action = #selector(changeClicked)

        removeButton.isBordered = false
        removeButton.imagePosition = .imageOnly
        removeButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L("Remove"))
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.setAccessibilityLabel(L("Remove"))
        removeButton.target = self; removeButton.action = #selector(removeClicked)

        for v in [marker, nickname, pathLabel, changeButton, removeButton] { addArrangedSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func markerClicked() { onToggleDefault() }
    @objc private func changeClicked() { onChange() }
    @objc private func removeClicked() { onRemove() }

    /// Shows one location. `editing`: leave the nickname text alone (it is being typed).
    func show(_ loc: NoteLocation, isDefault: Bool, problem: NewNoteLocation.Problem?, editing: Bool) {
        let full = loc.fullPath
        if !editing { nickname.stringValue = loc.nickname }
        nickname.placeholderString = NoteLocation(path: loc.path).displayName   // the folder's name
        pathLabel.stringValue = full
        let reason: String? = problem.map {
            $0 == .missing ? L("The folder \"%@\" is missing.", full) : L("The folder \"%@\" can't be written to.", full)
        }
        // warning style: the system's orange; the other rows use plain label colours
        pathLabel.textColor = problem == nil ? .labelColor : .systemOrange
        let tip = reason ?? full
        toolTip = tip; nickname.toolTip = tip; pathLabel.toolTip = tip
        marker.image = NSImage(systemSymbolName: isDefault ? "largecircle.fill.circle" : "circle",
                               accessibilityDescription: L("Default location for new notes"))
        marker.contentTintColor = isDefault ? .controlAccentColor : .secondaryLabelColor
        marker.setAccessibilityValue(isDefault ? "1" : "0")
        marker.toolTip = isDefault ? "\(L("Default location for new notes"))\n\(tip)" : "\(L("Make default"))\n\(tip)"
    }
}

/// The "Writing locations" editor in the Files pane: one row per location and an Add Location… button.
/// Edits go straight to the settings backend (live, like every other control); the rows are only
/// rebuilt when the folders, the default or a folder's state change, never while a nickname is typed.
@MainActor
final class LocationsEditorView: NSStackView, NSTextFieldDelegate {
    unowned let backend: SettingsBackend
    /// Asks for a folder (the current one first); nil when cancelled.
    var askFolder: (_ current: String) -> String? = { _ in nil }
    /// The editor grew or shrank: the pane refits its window.
    var onSizeChange: () -> Void = {}
    private(set) var rows: [LocationRowView] = []
    let emptyLabel = NSTextField(labelWithString: L("Not set"))
    let addButton = NSButton(title: L("Add Location…"), target: nil, action: nil)
    private var shown: [String]?

    init(backend: SettingsBackend) {
        self.backend = backend
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        emptyLabel.textColor = .secondaryLabelColor
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.target = self; addButton.action = #selector(addClicked)
        addArrangedSubview(emptyLabel)
        addArrangedSubview(addButton)
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var state: LocationsState { LocationsState(backend.values) }

    /// Pull the stored locations into the rows.
    func sync() {
        let s = state
        let structure = s.structure()
        if structure != shown { rebuild(s, structure) }
        for (i, row) in rows.enumerated() where i < s.locations.count {
            row.show(s.locations[i], isDefault: s.isDefault(i),
                     problem: NoteLocations.problem(s.locations[i]), editing: row.nickname.currentEditor() != nil)
        }
    }

    private func rebuild(_ s: LocationsState, _ structure: [String]) {
        let hadRows = rows.count
        for r in rows { removeArrangedSubview(r); r.removeFromSuperview() }
        rows = s.locations.indices.map { i in
            let row = LocationRowView()
            row.nickname.delegate = self
            row.onToggleDefault = { [weak self] in self?.edit { $0.toggleDefault(at: i); return true } }
            row.onChange = { [weak self] in self?.changeFolder(at: i) }
            row.onRemove = { [weak self] in self?.edit { $0.remove(at: i); return true } }
            return row
        }
        for (i, r) in rows.enumerated() { insertArrangedSubview(r, at: i) }
        emptyLabel.isHidden = !rows.isEmpty
        shown = structure
        if rows.count != hadRows || hadRows == 0 { layoutSubtreeIfNeeded(); onSizeChange() }
    }

    /// Applies an edit to the stored state and writes the two settings in one go. The closure returns
    /// false (or nothing) when it changed nothing.
    private func edit(_ change: (inout LocationsState) -> Bool) {
        var s = state
        guard change(&s) else { return }
        backend.setMany([("files.note-locations", s.storedLines.map { .list($0) }),
                         ("files.default-note-location", s.storedDefault.map { .string($0) })])
    }

    private func changeFolder(at i: Int) {
        let s = state
        guard i < s.locations.count, let picked = askFolder(s.locations[i].normalizedPath) else { return }
        edit { $0.changeFolder(at: i, to: picked) }
    }

    @objc private func addClicked() {
        guard let picked = askFolder("") else { return }
        edit { $0.add(path: picked) }
    }

    // MARK: nickname

    /// Return and focus loss both end editing: the nickname is stored then, not on every keystroke.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let i = rows.firstIndex(where: { $0.nickname === f }),
              i < state.locations.count else { return }
        f.stringValue = NoteLocation.cleanNickname(f.stringValue)
        edit { $0.rename(at: i, to: f.stringValue) }
    }
}
