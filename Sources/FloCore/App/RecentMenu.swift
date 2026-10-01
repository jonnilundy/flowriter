import Foundation

/// One row of File > Open Recent and of the quick recent picker.
public struct RecentMenuItem: Equatable {
    public var path: String
    /// The file name without ".md" ("notes").
    public var name: String
    /// The parent folder's name, set only when another row has the same name ("drafts").
    public var folder: String?
    /// The full path with "~" for the home folder.
    public var tooltip: String
    public var parentTooltip: String

    /// "notes", or "notes — drafts" when the name is not unique in the list.
    public var title: String { folder.map { "\(name) — \($0)" } ?? name }
}

/// The recent documents as a menu shows them: order, cap, dedupe, missing files dropped, names.
public enum RecentMenu {
    /// Rows in File > Open Recent.
    public static let menuLimit = 10

    /// The file name without ".md" (also ".markdown", ".mdx"); other extensions stay ("todo.txt").
    public static func displayName(_ path: String) -> String {
        let name = LinkPaths.getFileName(path)
        for ext in [".md", ".markdown", ".mdx"] where name.lowercased().hasSuffix(ext) && name.count > ext.count {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    /// `~` for the home folder at the start of a path.
    public static func tildePath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return home != "/" && path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Newest first (the order of `entries`), one row per path, files that are gone and the current
    /// file left out, at most `limit` rows. A name that two rows share gets its parent folder's name.
    public static func items(_ entries: [RecentEntry], current: String? = nil, limit: Int = menuLimit,
                             home: String = NSHomeDirectory(), exists: (String) -> Bool = { WorkspaceFS.isFile($0) }) -> [RecentMenuItem] {
        var seen = Set<String>()
        var rows: [RecentMenuItem] = []
        for e in entries where !e.hidden && e.path != current && seen.insert(e.path).inserted && exists(e.path) {
            rows.append(RecentMenuItem(path: e.path, name: displayName(e.path), folder: nil,
                                       tooltip: tildePath(e.path, home: home), parentTooltip: tildePath(LinkPaths.getParentDir(e.path), home: home)))
            if rows.count == limit { break }
        }
        var count: [String: Int] = [:]
        for r in rows { count[r.name, default: 0] += 1 }
        for i in rows.indices where count[rows[i].name]! > 1 {
            let parent = LinkPaths.getParentDir(rows[i].path)
            rows[i].folder = parent == "/" ? "/" : LinkPaths.getFileName(parent)
        }
        return rows
    }
}
