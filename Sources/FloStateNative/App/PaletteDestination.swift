import Foundation
import FloCore

/// Where the new-note palette puts the note, and the choices for it. Pure: no views, so it is
/// unit tested on its own (PaletteDestinationTests). `PaletteState.destination` holds the location
/// the user picked in this palette session (a normalized path); it is gone when the palette closes.
struct PaletteDestination {
    /// Every configured location (`values.noteLocations`).
    var locations: [NoteLocation]
    /// The raw `files.default-note-location` setting ("" when none).
    var defaultPath: String
    /// Today's folder: the workspace root, or the folder of the open note.
    var fallback: String?
    /// The location picked in this session, as a normalized path.
    var chosen: String?

    /// The chip beside the name field.
    struct Chip: Equatable {
        var name: String
        /// The full folder path ("~" for home), shown on hover.
        var tooltip: String
        /// True when there are locations to pick from. Without any the chip is a plain label.
        var hasMenu: Bool
    }

    struct Resolved: Equatable {
        /// The folder the note goes in; nil when there is none.
        var directory: String?
        /// A configured location holds the note: a name cannot leave its folder.
        var confined: Bool
        /// The location in use (nil when the note goes to today's folder).
        var current: NoteLocation?
        /// Why the default location was skipped, quietly shown in the palette.
        var notice: String?
        var chip: Chip?
    }

    /// One row of the drop-down menu.
    struct MenuEntry: Equatable {
        var path: String        // normalized: what a click chooses
        var title: String
        var tooltip: String     // the full path
        var checked: Bool
        var isDefault: Bool
        var problem: NewNoteLocation.Problem?
        var enabled: Bool { problem == nil }
    }

    private var defaultNormalized: String? {
        let d = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? nil : NewNoteLocation.normalized(d)
    }

    func resolve() -> Resolved {
        if let picked = chosen, let loc = locations.first(where: { $0.normalizedPath == picked }),
           NoteLocations.problem(loc) == nil {
            return Resolved(directory: loc.normalizedPath, confined: true, current: loc, notice: nil, chip: chip(for: loc))
        }
        let c = NewNoteLocation.choose(defaultLocation: defaultPath, fallback: fallback)
        if c.usedDefault, let dir = c.directory {
            let loc = locations.first { $0.normalizedPath == dir } ?? NoteLocation(path: dir)
            return Resolved(directory: dir, confined: true, current: loc, notice: nil, chip: chip(for: loc))
        }
        var notice: String?
        let name = LinkPaths.getFileName(defaultNormalized ?? "")
        switch c.problem {
        case .missing?: notice = L("The default folder \"%@\" is missing.", name)
        case .notWritable?: notice = L("The default folder \"%@\" can't be written to.", name)
        case nil: break
        }
        if let n = notice, let d = c.directory { notice = n + " " + L("Using %@.", LinkPaths.getFileName(d)) }
        var chip: Chip?
        if let d = c.directory {
            let n = LinkPaths.getFileName(d)
            chip = Chip(name: n.isEmpty ? d : n, tooltip: NewNoteLocation.abbreviated(d), hasMenu: !locations.isEmpty)
        }
        return Resolved(directory: c.directory, confined: false, current: nil, notice: notice, chip: chip)
    }

    private func chip(for loc: NoteLocation) -> Chip {
        Chip(name: loc.displayName, tooltip: loc.fullPath, hasMenu: !locations.isEmpty)
    }

    /// The row under the input: "Create note in <name>" for a location, else the reason the default
    /// was skipped, else "Create note".
    func heading(_ r: Resolved) -> String {
        if r.confined, let loc = r.current { return L("Create note in %@", loc.displayName) }
        return r.notice ?? L("Create note")
    }

    /// The note's path for the typed name; nil when the name has no valid path.
    func createPath(_ r: Resolved, rawName: String) -> String? {
        guard let dir = r.directory else { return nil }
        return r.confined ? NewNoteLocation.confinedCreatePath(directory: dir, rawName: rawName)
                          : WorkspaceFS.paletteCreatePath(root: dir, rawName: rawName)
    }

    /// The location Tab (delta 1) or Shift-Tab (delta -1) moves to. Only usable locations count; the
    /// list wraps. From today's folder, forward goes to the first and back to the last. Nil when
    /// there is nothing else to move to.
    func cycled(from r: Resolved, by delta: Int) -> NoteLocation? {
        let usable = locations.filter { NoteLocations.problem($0) == nil }
        guard !usable.isEmpty else { return nil }
        guard let cur = r.current, let i = usable.firstIndex(where: { $0.normalizedPath == cur.normalizedPath }) else {
            return delta >= 0 ? usable.first : usable.last
        }
        guard usable.count > 1 else { return nil }
        let n = usable.count
        return usable[(((i + delta) % n) + n) % n]
    }

    /// Every location, in settings order. A location with a problem is listed but disabled.
    func menuEntries(_ r: Resolved) -> [MenuEntry] {
        locations.map { loc in
            let problem = NoteLocations.problem(loc)
            let isDefault = loc.normalizedPath == defaultNormalized
            var notes: [String] = []
            if isDefault { notes.append(L("Default")) }
            switch problem {
            case .missing?: notes.append(L("Folder missing"))
            case .notWritable?: notes.append(L("Read-only"))
            case nil: break
            }
            let title = notes.isEmpty ? loc.displayName : "\(loc.displayName) (\(notes.joined(separator: ", ")))"
            return MenuEntry(path: loc.normalizedPath, title: title, tooltip: loc.fullPath,
                             checked: r.current?.normalizedPath == loc.normalizedPath,
                             isDefault: isDefault, problem: problem)
        }
    }
}
