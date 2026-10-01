import Foundation
import FloCore

/// Flowriter: Ghost. A ghost is a range of the document that is drawn faded and left out of the
/// word count. The text stays in the document. `author` ghosts are made by the writer. `proposed`
/// ghosts are made by the Lab's trim tool and wait for the writer to accept (delete) or reject
/// (revive) them.
public enum GhostOrigin: String, Codable, Sendable { case author, proposed }

public struct GhostRange: Equatable, Sendable {
    public var from: Int
    public var to: Int
    public var origin: GhostOrigin
    public init(from: Int, to: Int, origin: GhostOrigin = .author) { self.from = from; self.to = to; self.origin = origin }
    public var length: Int { to - from }
}

/// Pure range math, kept apart from the editor so it tests without a window.
public enum GhostMath {
    /// Sort, drop empty ranges, merge overlapping or touching ranges of the same origin.
    public static func normalize(_ rs: [GhostRange]) -> [GhostRange] {
        var out: [GhostRange] = []
        for r in rs.filter({ $0.to > $0.from }).sorted(by: { $0.from < $1.from }) {
            if let l = out.last, l.origin == r.origin, r.from <= l.to { out[out.count - 1].to = max(l.to, r.to) } else { out.append(r) }
        }
        return out
    }

    /// Add `[from, to)` as an author ghost. Proposed ghosts are left as they are.
    public static func ghost(_ rs: [GhostRange], from: Int, to: Int) -> [GhostRange] {
        guard to > from else { return rs }
        return normalize(rs + [GhostRange(from: from, to: to, origin: .author)])
    }

    /// Take `[from, to)` out of the author ghosts (a ghost that spans it splits in two).
    public static func revive(_ rs: [GhostRange], from: Int, to: Int) -> [GhostRange] {
        var out: [GhostRange] = []
        for r in rs {
            guard r.origin == .author, r.from < to, r.to > from else { out.append(r); continue }
            if r.from < from { out.append(GhostRange(from: r.from, to: from, origin: r.origin)) }
            if r.to > to { out.append(GhostRange(from: to, to: r.to, origin: r.origin)) }
        }
        return normalize(out)
    }

    /// The author ghosts Revive reaches from `[from, to)`: for a caret (`from == to`) the ghost it
    /// sits in or at the edge of, for a selection every ghost it overlaps. Revive takes these whole.
    public static func touching(_ rs: [GhostRange], from: Int, to: Int) -> [GhostRange] {
        let a = min(from, to), b = max(from, to)
        return rs.filter { $0.origin == .author && (a == b ? ($0.from <= a && a <= $0.to) : ($0.from < b && $0.to > a)) }
    }

    /// Is the selection `[from, to)` ghost text? True when it touches an author ghost and every
    /// character of it outside the author ghosts is white space (a ghost selected with the space or
    /// line break after it, or two ghosts with only a blank line between them).
    public static func isGhostText(_ rs: [GhostRange], from: Int, to: Int, in text: [UInt16]) -> Bool {
        let a = max(0, min(from, to)), b = min(text.count, max(from, to))
        let authors = rs.filter { $0.origin == .author }
        guard b > a, !touching(authors, from: a, to: b).isEmpty else { return false }
        var i = a
        while i < b {
            if let g = authors.first(where: { $0.from <= i && i < $0.to }) { i = g.to; continue }
            guard let u = UnicodeScalar(text[i]), CharacterSet.whitespacesAndNewlines.contains(u) else { return false }
            i += 1
        }
        return true
    }

    /// The ghost that holds position `pos` (an edge counts as inside, as a click between the last
    /// ghosted letter and the next one can land on either side).
    public static func ghost(at pos: Int, in rs: [GhostRange]) -> GhostRange? {
        rs.first { $0.from <= pos && pos <= $0.to }
    }

    /// The smallest single replacement that turns `old` into `new`, nil when they match.
    public static func diff(old: [UInt16], new: [UInt16]) -> Change? {
        if old == new { return nil }
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        return Change(from: p, to: old.count - s, insert: String(utf16CodeUnits: Array(new[p..<(new.count - s)]), count: new.count - s - p))
    }

    /// A change that replaces a whole paragraph to add one letter becomes the one letter: trim the
    /// text the old and new side share at both ends of each change.
    public static func refine(_ changes: [Change], old: [UInt16]) -> [Change] {
        changes.compactMap { c in
            let oldPart = Array(old[c.from..<c.to]), newPart = Array(c.insert.utf16)
            guard let d = diff(old: oldPart, new: newPart) else { return nil }
            return Change(from: c.from + d.from, to: c.from + d.to, insert: d.insert)
        }
    }

    public static func covers(_ rs: [GhostRange], from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        var pos = from
        for r in rs.sorted(by: { $0.from < $1.from }) where r.to > pos && r.from <= pos {
            pos = r.to
            if pos >= to { return true }
        }
        return false
    }

    /// Number of words in `text` outside the ghosts. A ghost counts as a gap between words.
    public static func wordCount(_ text: String, ghosts: [GhostRange]) -> Int {
        let ns = NSMutableString(string: text)
        for r in ghosts.sorted(by: { $0.from > $1.from }) {
            let a = max(0, min(r.from, ns.length)), b = max(a, min(r.to, ns.length))
            if b > a { ns.replaceCharacters(in: NSRange(location: a, length: b - a), with: " ") }
        }
        var n = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }
}

/// Conformance of the sidecar's ghost store to the ghost UI's ranges.
extension SidecarGhostStore {
    func ghostRanges(doc: String) -> [GhostRange] {
        loadSpans(doc: doc).map { GhostRange(from: $0.from, to: $0.to, origin: $0.proposed ? .proposed : .author) }
    }
    func saveGhostRanges(_ ranges: [GhostRange], doc: String) {
        saveSpans(ranges.map { GhostSpan(from: $0.from, to: $0.to, proposed: $0.origin == .proposed) }, doc: doc)
    }
}
