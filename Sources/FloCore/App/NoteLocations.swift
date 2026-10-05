import Foundation

/// One folder new notes can go in, with a nickname. The nickname is optional: without one the
/// folder's own name is shown. Stored as one config line, "Nickname|path" ("|path" has no nickname).
public struct NoteLocation: Equatable, Hashable, Sendable {
    public var nickname: String
    /// As the user chose it, so a "~" stays a "~" in the config file.
    public var path: String

    public init(nickname: String = "", path: String) {
        self.nickname = Self.cleanNickname(nickname)
        self.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Absolute, "~" expanded, no trailing slash. Two locations are the same folder when this matches.
    public var normalizedPath: String { NewNoteLocation.normalized(path) }

    /// The nickname, else the folder's name ("~/Writing/journal" shows as "journal").
    public var displayName: String {
        if !nickname.isEmpty { return nickname }
        let last = (normalizedPath as NSString).lastPathComponent
        return last.isEmpty ? normalizedPath : last
    }

    /// The full path for a tooltip: absolute, with the home folder as "~".
    public var fullPath: String { NewNoteLocation.abbreviated(normalizedPath) }

    /// The config line.
    public var encoded: String { "\(nickname)|\(path)" }

    /// A config line back into a location; nil when it has no path.
    public static func decode(_ line: String) -> NoteLocation? {
        let nick: String, path: String
        if let bar = line.firstIndex(of: "|") {
            nick = String(line[..<bar]); path = String(line[line.index(after: bar)...])
        } else { nick = ""; path = line }   // a bare path is a location without a nickname
        let loc = NoteLocation(nickname: nick, path: path)
        return loc.path.isEmpty ? nil : loc
    }

    /// One line, no "|" (it separates the nickname from the path).
    public static func cleanNickname(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "/")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The list of locations (setting `files.note-locations`) and which one is the default
/// (`files.default-note-location`, the default's path, as before the list existed).
public enum NoteLocations {
    /// The config lines as locations, in order; a folder listed twice counts once (first wins).
    public static func parse(_ lines: [String]) -> [NoteLocation] {
        var seen = Set<String>(), out: [NoteLocation] = []
        for line in lines {
            guard let loc = NoteLocation.decode(line), seen.insert(loc.normalizedPath).inserted else { continue }
            out.append(loc)
        }
        return out
    }

    public static func encode(_ locations: [NoteLocation]) -> [String] { locations.map(\.encoded) }

    /// The list plus the default folder when the list does not hold it yet (a default set before the
    /// list existed keeps working: it shows up as a location named after its folder).
    public static func all(lines: [String], defaultPath: String) -> [NoteLocation] {
        var out = parse(lines)
        let d = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty {
            let loc = NoteLocation(path: d)
            if !out.contains(where: { $0.normalizedPath == loc.normalizedPath }) { out.insert(loc, at: 0) }
        }
        return out
    }

    /// The default location, nil when no default is set.
    public static func defaultLocation(in locations: [NoteLocation], defaultPath: String) -> NoteLocation? {
        let d = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        let n = NewNoteLocation.normalized(d)
        return locations.first { $0.normalizedPath == n }
    }

    /// Why a location cannot take a new note right now (nil: it can).
    public static func problem(_ loc: NoteLocation, fileManager fm: FileManager = .default) -> NewNoteLocation.Problem? {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: loc.normalizedPath, isDirectory: &isDir), isDir.boolValue else { return .missing }
        return fm.isWritableFile(atPath: loc.normalizedPath) ? nil : .notWritable
    }

    /// `locations` with `loc` appended, unless that folder is already there (then the list is unchanged).
    public static func adding(_ loc: NoteLocation, to locations: [NoteLocation]) -> [NoteLocation] {
        locations.contains { $0.normalizedPath == loc.normalizedPath } ? locations : locations + [loc]
    }

    /// The default path to store after `removed` leaves the list: empty when it was the default.
    public static func defaultPath(afterRemoving removed: NoteLocation, defaultPath: String) -> String {
        let d = defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !d.isEmpty && NewNoteLocation.normalized(d) == removed.normalizedPath ? "" : defaultPath
    }
}
