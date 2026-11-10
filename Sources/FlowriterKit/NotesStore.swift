import Foundation

/// A document's notes live in a plain text file next to it: `.<name>.notes.md`. Hidden, so a
/// folder of drafts stays a folder of drafts; plain, so any tool can read it. What is typed in
/// the drawer is what the file holds.
public enum NotesStore {
    public static func notesURL(for document: URL) -> URL {
        document.deletingLastPathComponent().appendingPathComponent("." + document.lastPathComponent + ".notes.md")
    }

    /// The sidecar of earlier versions: JSON with the notes as a list of `overflow` items.
    public static func legacyURL(for document: URL) -> URL {
        document.deletingLastPathComponent().appendingPathComponent("." + document.lastPathComponent + ".flowriter.json")
    }

    public static func load(for document: URL) -> String {
        if let data = try? Data(contentsOf: notesURL(for: document)) { return String(decoding: data, as: UTF8.self) }
        return legacyNotes(for: document) ?? ""
    }

    /// The `overflow` items of an old sidecar, in their order, a blank line between them.
    static func legacyNotes(for document: URL) -> String? {
        guard let data = try? Data(contentsOf: legacyURL(for: document)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["overflow"] as? [[String: Any]], !items.isEmpty else { return nil }
        let ordered = items.enumerated().sorted { a, b in
            let x = a.element["order"] as? Int ?? a.offset, y = b.element["order"] as? Int ?? b.offset
            return x == y ? a.offset < b.offset : x < y
        }
        let texts = ordered.compactMap { $0.element["text"] as? String }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// Write the notes. Empty notes leave no file behind. The old sidecar is never changed.
    public static func save(_ text: String, for document: URL) throws {
        let url = notesURL(for: document)
        if text.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// The document moved or was renamed: its notes file goes with it.
    public static func move(from old: URL, to new: URL) {
        let source = notesURL(for: old), target = notesURL(for: new)
        guard source != target, FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.moveItem(at: source, to: target)
    }
}
