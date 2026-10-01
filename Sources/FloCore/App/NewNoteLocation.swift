import Foundation

/// Where a new note goes: the "default location for new notes" setting, with a quiet fallback.
public enum NewNoteLocation {
    public enum Problem: Equatable { case missing, notWritable }

    public struct Choice: Equatable {
        /// The folder the note goes in; nil when there is none (no default, nothing to fall back to).
        public var directory: String?
        /// True when `directory` is the default location.
        public var usedDefault: Bool
        /// Why the default location was not used (nil when unset or used).
        public var problem: Problem?
    }

    /// The default location when set and usable, else `fallback` (today's behaviour).
    public static func choose(defaultLocation: String, fallback: String?,
                              fileManager fm: FileManager = .default) -> Choice {
        let raw = defaultLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Choice(directory: fallback, usedDefault: false, problem: nil) }
        let dir = normalized(raw)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return Choice(directory: fallback, usedDefault: false, problem: .missing)
        }
        guard fm.isWritableFile(atPath: dir) else {
            return Choice(directory: fallback, usedDefault: false, problem: .notWritable)
        }
        return Choice(directory: dir, usedDefault: true, problem: nil)
    }

    /// Absolute, no trailing slash, "~" expanded.
    public static func normalized(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The note's path inside `directory`: "drafts/idea" becomes "<dir>/drafts/idea.md". A name with a
    /// ".." part has no path (nil), so a note never leaves the folder. Empty and "." parts are dropped.
    public static func confinedCreatePath(directory: String, rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        let name = parts.joined(separator: "/")
        return "\(directory)/\(name.hasSuffix(".md") ? name : name + ".md")"
    }

    /// "/Users/me/Notes" as "~/Notes".
    public static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
