import Foundation

/// A file name made from a note's first line: "# Happy days!" is "happy-days".
public enum NoteName {
    public static let fallback = "untitled"

    public static func derive(from text: String, maxLength: Int = 60) -> String {
        // the first line that says something (a frontmatter fence or a code fence says nothing)
        var line = ""
        var seen = 0
        text.enumerateLines { candidate, stop in
            seen += 1
            if candidate.contains(where: { $0.isLetter || $0.isNumber }) { line = candidate; stop = true }
            if seen >= 40 { stop = true }
        }
        var out = ""
        var dash = false, truncated = false
        for ch in line.lowercased() {
            if ch.isLetter || ch.isNumber {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out.append(ch)
            } else {
                dash = true
            }
            if out.count >= maxLength { truncated = true; break }
        }
        // a list number or a task box is structure, not the name: "1. First" is "first"
        if let prefix = LinePrefix.parse(Array(line.utf16)), case .ordered = prefix.kind,
           let rest = out.firstIndex(of: "-"), out[..<rest].allSatisfy(\.isNumber) {
            out = String(out[out.index(after: rest)...])
        }
        // a name cut short ends at a whole word
        if truncated, let cut = out.lastIndex(of: "-") { out = String(out[..<cut]) }
        return out.isEmpty ? fallback : out
    }
}

/// A note that is not in a file of its own yet.
public struct Draft: Hashable, Sendable {
    public var id: String
    public var text: String
    public var notes: String
    public init(id: String = UUID().uuidString, text: String, notes: String = "") {
        self.id = id; self.text = text; self.notes = notes
    }
}

/// Unsaved notes are kept here as they are typed, so they come back after the app quits (or
/// crashes). One plain file per note, plus one for its notes drawer.
public enum Drafts {
    /// `~/Library/Application Support/<app>/Drafts`. A build that is not the installed app gets a
    /// folder of its own: an app under another bundle id uses that id, a test tool its process
    /// name, and a command line build of the app "Flowriter-dev" (its process is also called Flowriter).
    nonisolated(unsafe) public static var directory: URL = {
        let id = Bundle.main.bundleIdentifier, name = ProcessInfo.processInfo.processName
        let app = id == "app.flowriter.Flowriter" ? "Flowriter" : id ?? (name == "Flowriter" ? "Flowriter-dev" : name)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(app).appendingPathComponent("Drafts")
    }()

    private static func textURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".md") }
    private static func notesURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".notes.md") }

    /// Write a draft. One with no text and no notes leaves no file.
    public static func write(_ draft: Draft) {
        guard !(draft.text.isEmpty && draft.notes.isEmpty) else { remove(draft.id); return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(draft.text.utf8).write(to: textURL(draft.id), options: .atomic)
        if draft.notes.isEmpty {
            try? FileManager.default.removeItem(at: notesURL(draft.id))
        } else {
            try? Data(draft.notes.utf8).write(to: notesURL(draft.id), options: .atomic)
        }
    }

    public static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: textURL(id))
        try? FileManager.default.removeItem(at: notesURL(id))
    }

    /// Every draft, oldest first.
    public static func all() -> [Draft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let texts = files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasSuffix(".notes.md") }
        func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return texts.sorted { date($0) < date($1) }.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            return Draft(id: id, text: (try? String(contentsOf: url, encoding: .utf8)) ?? "",
                         notes: (try? String(contentsOf: notesURL(id), encoding: .utf8)) ?? "")
        }
    }

    public static func removeAll() { try? FileManager.default.removeItem(at: directory) }
}
