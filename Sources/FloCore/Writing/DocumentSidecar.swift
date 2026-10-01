import Foundation

// Flowriter document sidecar: the writing state that must not live in the Markdown file.
//
// FILE
//   `post.md` keeps its state in `.post.md.flowriter.json`, a hidden file in the same folder
//   (see `SidecarStore.url(for:)`). Hidden, because the sidebar, the file index and the file
//   watcher already skip dot entries, Finder and Obsidian hide it, and git still carries it.
//   No sidecar file exists while a document stores nothing (`DocumentSidecar.isEmpty`).
//
// FORMAT (schemaVersion 1)
//   UTF-8 JSON, 2-space pretty print, keys always in the order below, trailing newline.
//   Offsets are UTF-16 code units (NSString / NSRange / `Change` units) into the editor text,
//   the same string `SidecarSession.load(doc:)` and `save(doc:)` get and `documentSHA256` hashes.
//   In Flowriter's writing space (FlowriterSettings.rawFrontmatter) the editor holds the whole
//   file, frontmatter included, so offsets are into the .md exactly as it is on disk. The
//   upstream shell (FLO_SPACE=0) splits the frontmatter into its properties table: there the
//   offsets and the hash are of the body after the frontmatter block.
//   Dates are ISO 8601 UTC with whole seconds. Unknown top-level keys are dropped on save.
//
//   {
//     "schemaVersion": 1,
//     "documentSHA256": "<hex of the .md text at save time>",
//     "alternatives": [
//       { "id": "…", "level": "word" | "sentence" | "paragraph",
//         "anchor": { "from": 10, "to": 19, "quote": "thumbtack", "prefix": "…", "suffix": "…" },
//         "originalId": "…", "currentId": "…",
//         "variants": [ { "id": "…", "text": "thumbtack", "author": "me" | "ai", "createdAt": "…" } ] }
//     ],
//     "ghosts": [
//       { "id": "…", "anchor": { … }, "author": "me" | "ai", "state": "ghosted" | "proposed",
//         "createdAt": "…", "source": "lab:trim-10" }            // "source" only when set
//     ],
//     "overflow": [ { "id": "…", "text": "…", "createdAt": "…", "order": 0 } ],
//     "unresolved": { "alternatives": [ … ], "ghosts": [ … ] }  // only when not empty
//   }
//
//   `anchor.quote` is the covered text at save time (for an alternative set it equals the
//   current variant's text, which is what sits in the .md). `prefix` / `suffix` are up to
//   `TextAnchor.contextLength` UTF-16 units of text around it. On load the anchors are found
//   again from quote + context (W3C text-quote selector style); anchors that cannot be found
//   move to `unresolved` and are kept, never guessed.
//
// EDITS
//   Every text change must reach `applyEdit(_:)` / `applyEdits(_:old:)` exactly once so anchors
//   shift, grow, shrink or drop. In the app ONE place does that for all features: FloKit's
//   `SidecarEditHook` (one per editor) forwards each committed editor transaction (typing, paste,
//   undo / redo, format commands) to `SidecarSession.follow`. Features never call it themselves.
//   Methods that return a `SidecarTextChange` (variant swaps, stash from selection) already
//   updated every anchor: dispatch their `changes` inside `SidecarEditHook.anchored { }` so the
//   hook does NOT apply them again.

/// Who wrote a variant or proposed a ghost.
public enum SidecarAuthor: String, Sendable, CaseIterable {
    case me
    case ai
}

/// The size of the unit an alternative set replaces.
public enum AlternativeLevel: String, Sendable, CaseIterable {
    case word
    case sentence
    case paragraph
}

/// One version of a word, sentence or paragraph.
public struct AlternativeVariant: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var author: SidecarAuthor
    public var createdAt: Date

    public init(id: String = SidecarID.make(), text: String, author: SidecarAuthor, createdAt: Date = SidecarClock.now()) {
        self.id = id; self.text = text; self.author = author; self.createdAt = SidecarClock.truncate(createdAt)
    }
}

/// Several versions of one range. The current variant's text is what sits in the document at
/// `anchor`; the original variant is the first one written.
public struct AlternativeSet: Equatable, Sendable, Identifiable {
    public var id: String
    public var level: AlternativeLevel
    public var anchor: TextAnchor
    public var variants: [AlternativeVariant]
    public var originalId: String
    public var currentId: String

    public init(id: String = SidecarID.make(), level: AlternativeLevel, anchor: TextAnchor,
                variants: [AlternativeVariant], originalId: String, currentId: String) {
        self.id = id; self.level = level; self.anchor = anchor
        self.variants = variants; self.originalId = originalId; self.currentId = currentId
    }

    public var current: AlternativeVariant? { variants.first { $0.id == currentId } }
    public var original: AlternativeVariant? { variants.first { $0.id == originalId } }
    public var currentIndex: Int? { variants.firstIndex { $0.id == currentId } }
}

/// Ghost state: `ghosted` is dimmed text the writer kept; `proposed` is a suggestion (for
/// example from the Lab's trim tool) that waits for accept or reject.
public enum GhostState: String, Sendable, CaseIterable {
    case ghosted
    case proposed
}

/// A range shown at ~10% instead of deleted. The text stays in the document.
public struct GhostRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var anchor: TextAnchor
    public var author: SidecarAuthor
    public var state: GhostState
    public var createdAt: Date
    /// Where the ghost came from, for example "lab:trim-10". Nil for a manual ghost.
    public var source: String?

    public init(id: String = SidecarID.make(), anchor: TextAnchor, author: SidecarAuthor, state: GhostState,
                createdAt: Date = SidecarClock.now(), source: String? = nil) {
        self.id = id; self.anchor = anchor; self.author = author; self.state = state
        self.createdAt = SidecarClock.truncate(createdAt); self.source = source
    }
}

/// One snippet in the per-document overflow panel. Lower `order` shows first.
public struct OverflowItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var createdAt: Date
    public var order: Int

    public init(id: String = SidecarID.make(), text: String, createdAt: Date = SidecarClock.now(), order: Int) {
        self.id = id; self.text = text; self.createdAt = SidecarClock.truncate(createdAt); self.order = order
    }
}

/// Items whose anchor could not be found again on load. Kept (and saved) so nothing is lost;
/// every load tries them again. Edits do not touch them.
public struct UnresolvedItems: Equatable, Sendable {
    public var alternatives: [AlternativeSet] = []
    public var ghosts: [GhostRecord] = []
    public init(alternatives: [AlternativeSet] = [], ghosts: [GhostRecord] = []) {
        self.alternatives = alternatives; self.ghosts = ghosts
    }
    public var isEmpty: Bool { alternatives.isEmpty && ghosts.isEmpty }
}

/// Text changes the sidecar made on its own behalf (a variant swap and its article fix, a stash
/// from the selection). The anchors are already updated. `changes` are in the coordinates of
/// the text before the change, sorted and not overlapping; `text` is the result.
public struct SidecarTextChange: Equatable {
    public var changes: [Change]
    public var text: String
    public init(changes: [Change], text: String) { self.changes = changes; self.text = text }
}

/// What an edit did to the anchors.
public struct SidecarEditResult: Equatable, Sendable {
    /// Alternative sets whose whole range was deleted (removed from the sidecar).
    public var droppedAlternatives: [String] = []
    /// Ghosts whose whole range was deleted (removed from the sidecar).
    public var droppedGhosts: [String] = []
    public init(droppedAlternatives: [String] = [], droppedGhosts: [String] = []) {
        self.droppedAlternatives = droppedAlternatives; self.droppedGhosts = droppedGhosts
    }
    public var isEmpty: Bool { droppedAlternatives.isEmpty && droppedGhosts.isEmpty }
}

public enum SidecarError: Error, Equatable {
    case invalidRange
    case unknownId(String)
    /// Select another variant before removing the one in the text.
    case cannotRemoveCurrentVariant
}

/// All sidecar state of one document.
public struct DocumentSidecar: Equatable, Sendable {
    public static let schemaVersion = 1

    public var alternatives: [AlternativeSet]
    public var ghosts: [GhostRecord]
    public var overflow: [OverflowItem]
    public var unresolved: UnresolvedItems

    public init(alternatives: [AlternativeSet] = [], ghosts: [GhostRecord] = [], overflow: [OverflowItem] = [],
                unresolved: UnresolvedItems = UnresolvedItems()) {
        self.alternatives = alternatives; self.ghosts = ghosts; self.overflow = overflow; self.unresolved = unresolved
    }

    /// True when there is nothing to store (then no sidecar file is written).
    public var isEmpty: Bool { alternatives.isEmpty && ghosts.isEmpty && overflow.isEmpty && unresolved.isEmpty }

    public func alternativeSet(_ id: String) -> AlternativeSet? { alternatives.first { $0.id == id } }
    public func ghost(_ id: String) -> GhostRecord? { ghosts.first { $0.id == id } }

    /// Overflow items in display order.
    public var sortedOverflow: [OverflowItem] { overflow.sorted { ($0.order, $0.id) < ($1.order, $1.id) } }

    // MARK: Edits

    /// Update every anchor for one text change (UTF-16 range of the text before the change,
    /// replaced by `insert`). Insertions at an anchor's edge stay outside it; changes inside it
    /// grow or shrink it; a change that deletes the whole range drops the item.
    ///
    /// Alternative sets have one more rule: a change that replaces exactly a set's range with
    /// new text keeps the set on the new text (an undo of a swap, a retyped word). When the new
    /// text is one of the set's other variants, that variant becomes current and the variant that
    /// was shown keeps the text it had (`old`, the document before the change, gives that text;
    /// without it the stored text is kept). Ghosts keep the plain rule: text typed over a whole
    /// ghost is new writing, not ghosted.
    @discardableResult
    public mutating func applyEdit(_ change: Change, old: [UInt16]? = nil) -> SidecarEditResult {
        var result = SidecarEditResult()
        alternatives = alternatives.compactMap { set in
            var s = set
            if change.from == s.anchor.from && change.to == s.anchor.to && change.to > change.from {
                let n = change.insert.utf16.count
                guard n > 0 else { result.droppedAlternatives.append(s.id); return nil }
                s.anchor.to = s.anchor.from + n
                if let v = s.variants.first(where: { $0.id != s.currentId && $0.text == change.insert }),
                   let j = s.variants.firstIndex(where: { $0.id == s.currentId }) {
                    if let old = old, change.to <= old.count {
                        s.variants[j].text = String(utf16CodeUnits: Array(old[change.from..<change.to]), count: change.to - change.from)
                    }
                    s.currentId = v.id
                }
                return s
            }
            guard let a = s.anchor.mapped(through: change) else { result.droppedAlternatives.append(s.id); return nil }
            s.anchor = a
            return s
        }
        ghosts = ghosts.compactMap { ghost in
            var g = ghost
            guard let a = g.anchor.mapped(through: change) else { result.droppedGhosts.append(g.id); return nil }
            g.anchor = a
            return g
        }
        return result
    }

    /// Several changes in the coordinates of the text before all of them (not overlapping),
    /// like `ChangeSet.changes`.
    /// `old` is the text before them (see `applyEdit(_:old:)`).
    @discardableResult
    public mutating func applyEdits(_ changes: [Change], old: [UInt16]? = nil) -> SidecarEditResult {
        var result = SidecarEditResult()
        for c in changes.sorted(by: { ($0.from, $0.to) > ($1.from, $1.to) }) {
            let r = applyEdit(c, old: old)
            result.droppedAlternatives += r.droppedAlternatives
            result.droppedGhosts += r.droppedGhosts
        }
        return result
    }

    /// An editor transaction's change set.
    @discardableResult
    public mutating func apply(_ changeSet: ChangeSet) -> SidecarEditResult { applyEdits(changeSet.changes) }

    // MARK: Alternatives

    /// Start an alternative set on `from..<to` of `text`. The covered text becomes the original
    /// and current variant.
    @discardableResult
    public mutating func addAlternativeSet(level: AlternativeLevel, from: Int, to: Int, in text: String,
                                           author: SidecarAuthor = .me, id: String = SidecarID.make(),
                                           now: Date = SidecarClock.now()) throws -> AlternativeSet {
        let units = Array(text.utf16)
        guard from >= 0, to > from, to <= units.count else { throw SidecarError.invalidRange }
        let covered = String(utf16CodeUnits: Array(units[from..<to]), count: to - from)
        let v = AlternativeVariant(text: covered, author: author, createdAt: now)
        let set = AlternativeSet(id: id, level: level, anchor: TextAnchor(from: from, to: to), variants: [v],
                                 originalId: v.id, currentId: v.id)
        alternatives.append(set)
        return set
    }

    /// Add a variant to a set without showing it.
    @discardableResult
    public mutating func addVariant(to setId: String, text: String, author: SidecarAuthor,
                                    id: String = SidecarID.make(), now: Date = SidecarClock.now()) throws -> AlternativeVariant {
        guard let i = alternatives.firstIndex(where: { $0.id == setId }) else { throw SidecarError.unknownId(setId) }
        let v = AlternativeVariant(id: id, text: text, author: author, createdAt: now)
        alternatives[i].variants.append(v)
        return v
    }

    /// Show `variantId` in place of the current variant: replaces the anchored text, fixes a
    /// preceding "a" / "an" (see `Articles`), and updates every anchor. Returns nil when the
    /// variant is already current.
    public mutating func selectVariant(_ variantId: String, in setId: String, text: String) throws -> SidecarTextChange? {
        guard let i = alternatives.firstIndex(where: { $0.id == setId }) else { throw SidecarError.unknownId(setId) }
        guard let v = alternatives[i].variants.first(where: { $0.id == variantId }) else { throw SidecarError.unknownId(variantId) }
        if alternatives[i].currentId == variantId { return nil }
        let a = alternatives[i].anchor
        let units = Array(text.utf16)
        guard a.from >= 0, a.to <= units.count, a.from < a.to else { throw SidecarError.invalidRange }
        // Keep what the writer typed inside the current variant before it leaves the text.
        if let c = alternatives[i].variants.firstIndex(where: { $0.id == alternatives[i].currentId }) {
            alternatives[i].variants[c].text = String(utf16CodeUnits: Array(units[a.from..<a.to]), count: a.length)
        }

        var changes: [Change] = []
        if let fix = Articles.fix(in: text, before: a.from, nextText: v.text) { changes.append(fix) }
        let swap = Change(from: a.from, to: a.to, insert: v.text)
        changes.append(swap)

        // Map every other anchor (last change first, so earlier coordinates stay valid). An
        // anchor that contains the swapped range grows or shrinks with it.
        let swapLen = v.text.utf16.count
        for j in alternatives.indices where j != i {
            if let m = alternatives[j].anchor.mapped(throughReplacementOf: a.from, a.to, insertLength: swapLen) {
                alternatives[j].anchor = m
            }
        }
        for j in ghosts.indices {
            if let m = ghosts[j].anchor.mapped(throughReplacementOf: a.from, a.to, insertLength: swapLen) {
                ghosts[j].anchor = m
            }
        }
        alternatives[i].anchor = TextAnchor(from: a.from, to: a.from + swapLen)
        alternatives[i].currentId = variantId
        // The article fix sits before the swap, so mapping it after the swap keeps both valid.
        if changes.count == 2 { applyEdit(changes[0]) }
        return SidecarTextChange(changes: changes, text: Self.applying(changes, to: text))
    }

    /// Step through the variants of a set (wraps around). `by` is +1 for the next one.
    public mutating func cycleVariant(in setId: String, by offset: Int, text: String) throws -> SidecarTextChange? {
        guard let set = alternativeSet(setId) else { throw SidecarError.unknownId(setId) }
        guard set.variants.count > 1, let idx = set.currentIndex else { return nil }
        let n = set.variants.count
        let next = ((idx + offset) % n + n) % n
        return try selectVariant(set.variants[next].id, in: setId, text: text)
    }

    /// Change a stored variant in place: its text, its author, or both. For the current variant
    /// the text is what the document holds at `anchor` (a save copies it in), so set it only to
    /// match the document.
    public mutating func updateVariant(_ variantId: String, in setId: String, text: String? = nil, author: SidecarAuthor? = nil) throws {
        guard let i = alternatives.firstIndex(where: { $0.id == setId }) else { throw SidecarError.unknownId(setId) }
        guard let j = alternatives[i].variants.firstIndex(where: { $0.id == variantId }) else { throw SidecarError.unknownId(variantId) }
        if let t = text { alternatives[i].variants[j].text = t }
        if let a = author { alternatives[i].variants[j].author = a }
    }

    /// Put a set's anchor at `from..<to` (a feature that tracks the range itself, for example
    /// after restoring an undo snapshot). The selector is refreshed on the next save.
    public mutating func setAnchor(of setId: String, from: Int, to: Int) throws {
        guard let i = alternatives.firstIndex(where: { $0.id == setId }) else { throw SidecarError.unknownId(setId) }
        guard from >= 0, to > from else { throw SidecarError.invalidRange }
        alternatives[i].anchor = TextAnchor(from: from, to: to)
    }

    /// Remove a set and keep whatever text is in the document.
    @discardableResult
    public mutating func removeAlternativeSet(_ id: String) -> AlternativeSet? {
        guard let i = alternatives.firstIndex(where: { $0.id == id }) else { return nil }
        return alternatives.remove(at: i)
    }

    /// Remove one variant. The current variant cannot be removed (select another one first);
    /// removing the original makes the oldest remaining variant the original.
    public mutating func removeVariant(_ variantId: String, from setId: String) throws {
        guard let i = alternatives.firstIndex(where: { $0.id == setId }) else { throw SidecarError.unknownId(setId) }
        guard alternatives[i].currentId != variantId else { throw SidecarError.cannotRemoveCurrentVariant }
        alternatives[i].variants.removeAll { $0.id == variantId }
        if alternatives[i].originalId == variantId, let oldest = alternatives[i].variants.min(by: { $0.createdAt < $1.createdAt }) {
            alternatives[i].originalId = oldest.id
        }
    }

    // MARK: Ghosts

    /// Ghost `from..<to`. `state: .proposed` for AI suggestions that wait for accept.
    @discardableResult
    public mutating func addGhost(from: Int, to: Int, author: SidecarAuthor = .me, state: GhostState = .ghosted,
                                  source: String? = nil, id: String = SidecarID.make(), now: Date = SidecarClock.now()) throws -> GhostRecord {
        guard from >= 0, to > from else { throw SidecarError.invalidRange }
        let g = GhostRecord(id: id, anchor: TextAnchor(from: from, to: to), author: author, state: state, createdAt: now, source: source)
        ghosts.append(g)
        return g
    }

    /// Turn a proposed ghost into a ghosted range.
    public mutating func acceptGhost(_ id: String) throws {
        guard let i = ghosts.firstIndex(where: { $0.id == id }) else { throw SidecarError.unknownId(id) }
        ghosts[i].state = .ghosted
    }

    /// Bring the text back to full strength (or reject a proposal): the record goes, the text stays.
    @discardableResult
    public mutating func reviveGhost(_ id: String) -> GhostRecord? {
        guard let i = ghosts.firstIndex(where: { $0.id == id }) else { return nil }
        return ghosts.remove(at: i)
    }

    /// Ghosts that overlap `from..<to`, in document order.
    public func ghosts(overlapping from: Int, _ to: Int) -> [GhostRecord] {
        ghosts.filter { $0.anchor.from < to && from < $0.anchor.to }.sorted { $0.anchor.from < $1.anchor.from }
    }

    // MARK: Overflow

    /// Add a snippet at the end of the overflow panel.
    @discardableResult
    public mutating func addOverflow(_ text: String, id: String = SidecarID.make(), now: Date = SidecarClock.now()) -> OverflowItem {
        let item = OverflowItem(id: id, text: text, createdAt: now, order: (overflow.map(\.order).max() ?? -1) + 1)
        overflow.append(item)
        return item
    }

    /// Cut `from..<to` out of `text` into a new overflow item. Anchors are updated.
    public mutating func stashSelection(from: Int, to: Int, in text: String, id: String = SidecarID.make(),
                                        now: Date = SidecarClock.now()) throws -> (item: OverflowItem, change: SidecarTextChange) {
        let units = Array(text.utf16)
        guard from >= 0, to > from, to <= units.count else { throw SidecarError.invalidRange }
        let snippet = String(utf16CodeUnits: Array(units[from..<to]), count: to - from)
        let item = addOverflow(snippet, id: id, now: now)
        let cut = Change(from: from, to: to, insert: "")
        applyEdit(cut)
        return (item, SidecarTextChange(changes: [cut], text: Self.applying([cut], to: text)))
    }

    public mutating func updateOverflow(_ id: String, text: String) throws {
        guard let i = overflow.firstIndex(where: { $0.id == id }) else { throw SidecarError.unknownId(id) }
        overflow[i].text = text
    }

    @discardableResult
    public mutating func removeOverflow(_ id: String) -> OverflowItem? {
        guard let i = overflow.firstIndex(where: { $0.id == id }) else { return nil }
        return overflow.remove(at: i)
    }

    /// Move an item to `index` in display order and renumber `order` 0, 1, 2, ...
    public mutating func moveOverflow(_ id: String, to index: Int) throws {
        var list = sortedOverflow
        guard let from = list.firstIndex(where: { $0.id == id }) else { throw SidecarError.unknownId(id) }
        let item = list.remove(at: from)
        list.insert(item, at: max(0, min(index, list.count)))
        for k in list.indices { list[k].order = k }
        overflow = list
    }

    // MARK: Helpers

    /// Apply non-overlapping changes (coordinates of `text`) to `text`.
    public static func applying(_ changes: [Change], to text: String) -> String {
        var units = Array(text.utf16)
        for c in changes.sorted(by: { ($0.from, $0.to) > ($1.from, $1.to) }) {
            units.replaceSubrange(c.from..<c.to, with: Array(c.insert.utf16))
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

/// Short random ids (12 hex digits), unique enough within one document.
public enum SidecarID {
    public static func make() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
    }
}

/// Dates in the sidecar have whole-second precision so the file round-trips byte for byte.
public enum SidecarClock {
    public static func now() -> Date { truncate(Date()) }
    public static func truncate(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }
}
