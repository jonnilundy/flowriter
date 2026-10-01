import Foundation
import FloCore

/// Flowriter Overflow: what the panel shows and saves for one document.
struct OverflowData: Equatable {
    /// The panel's whole text: the sidecar's overflow items, in order, separated by a blank line.
    var text: String = ""
    /// Panel open or closed. The sidecar has no field for it, so it is a per-viewer setting.
    var open: Bool = false
}

/// Where a document's Overflow lives between runs. `documentText` is the editor's text now: the
/// sidecar anchors its other state (alternatives, ghosts) against it.
@MainActor
protocol OverflowStoring {
    func load(documentPath: String, documentText: String) -> OverflowData
    func save(_ data: OverflowData, documentPath: String, documentText: String)
}

@MainActor
enum OverflowStoreFactory {
    static var make: () -> OverflowStoring = { OverflowSidecarStore() }
}

/// The document sidecar (`.post.md.flowriter.json`, key "overflow"), through the one shared
/// `SidecarSession` of the document: a save here keeps the alternatives and ghosts other features
/// hold in the same session. The .md never changes.
@MainActor
struct OverflowSidecarStore: OverflowStoring {
    var defaults: UserDefaults = .standard

    static func openKey(_ documentPath: String) -> String { "FlowriterOverflowOpen." + documentPath }

    func load(documentPath: String, documentText: String) -> OverflowData {
        let session = SidecarSession.shared(for: documentPath)
        session.loadIfNeeded(doc: documentText)
        return OverflowData(text: OverflowItems.join(session.sidecar.sortedOverflow.map(\.text)), open: defaults.bool(forKey: Self.openKey(documentPath)))
    }

    func save(_ data: OverflowData, documentPath: String, documentText: String) {
        if data.open { defaults.set(true, forKey: Self.openKey(documentPath)) } else { defaults.removeObject(forKey: Self.openKey(documentPath)) }
        let session = SidecarSession.shared(for: documentPath)
        session.loadIfNeeded(doc: documentText)
        let current = session.sidecar.sortedOverflow
        let next = OverflowItems.reconcile(existing: current, blocks: OverflowItems.split(data.text))
        guard next != current else { return }
        session.update { $0.overflow = next }
        _ = try? session.save(doc: documentText)
    }
}

/// Panel text <-> sidecar items. An item is a block of text between blank lines.
enum OverflowItems {
    static func join(_ items: [String]) -> String { items.joined(separator: "\n\n") }

    /// Blocks between blank lines, without leading or trailing newlines; empty blocks dropped.
    static func split(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        func flush() {
            var lines = current
            while lines.last.map({ $0.allSatisfy { $0 == " " || $0 == "\t" } }) == true { lines.removeLast() }
            guard !lines.isEmpty else { current = []; return }
            var block = lines.joined(separator: "\n")
            while block.last == " " || block.last == "\t" { block.removeLast() }
            blocks.append(block)
            current = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { flush() } else { current.append(line) }
        }
        flush()
        return blocks
    }

    /// Items for `blocks`, keeping the id and date of an existing item when its text is unchanged, or
    /// (for a changed block) when it stands in the same place among the changed ones.
    static func reconcile(existing: [OverflowItem], blocks: [String], now: Date = SidecarClock.now()) -> [OverflowItem] {
        var unused = existing
        var assigned: [OverflowItem?] = Array(repeating: nil, count: blocks.count)
        for (i, b) in blocks.enumerated() {
            if let k = unused.firstIndex(where: { $0.text == b }) { assigned[i] = unused.remove(at: k) }
        }
        var out: [OverflowItem] = []
        for (i, b) in blocks.enumerated() {
            var item: OverflowItem
            if let a = assigned[i] { item = a }
            else if !unused.isEmpty { item = unused.removeFirst(); item.text = b }
            else { item = OverflowItem(text: b, createdAt: now, order: i) }
            item.order = i
            out.append(item)
        }
        return out
    }
}

/// Pure text logic for stashing, kept apart from AppKit so it is unit-testable.
enum OverflowStash {
    /// `from..<to` (UTF-16) of the document is the selection. Returns the range to remove (the selection,
    /// plus the paragraph break after it when the selection is whole lines, so no hole is left behind)
    /// and the text to put in the panel (without the surrounding blank lines).
    static func plan(doc: String, from: Int, to: Int) -> (remove: NSRange, stashed: String)? {
        let ns = doc as NSString
        guard from < to, to <= ns.length else { return nil }
        let sel = ns.substring(with: NSRange(location: from, length: to - from))
        let stashed = sel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stashed.isEmpty else { return nil }
        var end = to
        let atLineStart = from == 0 || ns.character(at: from - 1) == 10
        let atLineEnd = to == ns.length || ns.character(at: to) == 10 || (to > from && ns.character(at: to - 1) == 10)
        if atLineStart && atLineEnd {
            var swallowed = 0
            while end < ns.length, ns.character(at: end) == 10, swallowed < 2 { end += 1; swallowed += 1 }
        }
        return (NSRange(location: from, length: end - from), stashed)
    }

    /// `existing` without the last occurrence of `chunk` and the blank line that joined it
    /// (the reverse of `append`). Unchanged when the panel no longer holds it.
    static func remove(_ chunk: String, from existing: String) -> String {
        let ns = existing as NSString
        let r = ns.range(of: chunk, options: .backwards)
        guard r.location != NSNotFound else { return existing }
        var a = r.location, b = NSMaxRange(r)
        if a >= 2, ns.substring(with: NSRange(location: a - 2, length: 2)) == "\n\n" { a -= 2 }
        else if b + 2 <= ns.length, ns.substring(with: NSRange(location: b, length: 2)) == "\n\n" { b += 2 }
        return ns.replacingCharacters(in: NSRange(location: a, length: b - a), with: "")
    }

    /// `existing` with `add` appended after a blank line.
    static func append(_ add: String, to existing: String) -> String {
        var base = existing
        while base.hasSuffix("\n") { base.removeLast() }
        return base.isEmpty ? add : base + "\n\n" + add
    }
}
