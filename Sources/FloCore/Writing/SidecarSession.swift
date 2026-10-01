import Foundation

/// The one in-memory sidecar of an open document. Every feature (ghosts, alternatives,
/// overflow) should read and change `sidecar` through the same session, so a save by one
/// feature never drops the others' items. `SidecarSession.shared(for:)` gives one session per
/// document path.
@MainActor
public final class SidecarSession {
    public let documentURL: URL
    public private(set) var sidecar = DocumentSidecar()
    public private(set) var isLoaded = false
    /// The last load's result (status, moved and unresolved anchors), nil before a load.
    public private(set) var lastLoad: SidecarLoadResult?

    public init(documentPath: String) { documentURL = URL(fileURLWithPath: documentPath) }

    private static var sessions: [String: SidecarSession] = [:]

    /// The session for a document path (created on first use).
    public static func shared(for documentPath: String) -> SidecarSession {
        let key = URL(fileURLWithPath: documentPath).standardizedFileURL.path
        if let s = sessions[key] { return s }
        let s = SidecarSession(documentPath: key)
        sessions[key] = s
        return s
    }

    /// Forget a document's session (after close or rename).
    public static func discard(documentPath: String) {
        sessions[URL(fileURLWithPath: documentPath).standardizedFileURL.path] = nil
    }

    /// The text the anchors point into now (the editor text they were loaded in or last followed
    /// to). Nil before a load.
    public private(set) var anchoredText: [UInt16]?
    /// How many edits `follow` applied to the anchors (tests: one keystroke is one edit).
    public private(set) var followCount = 0

    /// Read the file and anchor it in `doc` (the editor text). Later calls reload.
    @discardableResult
    public func load(doc: String) -> SidecarLoadResult {
        let r = SidecarStore.load(for: documentURL, documentText: doc)
        sidecar = r.sidecar
        isLoaded = true
        lastLoad = r
        anchoredText = Array(doc.utf16)
        return r
    }

    /// Load once; later calls keep the in-memory state.
    public func loadIfNeeded(doc: String) { if !isLoaded { load(doc: doc) } }

    /// Write the sidecar for `doc` (the text saved to the .md).
    @discardableResult
    public func save(doc: String) throws -> SidecarSaveOutcome {
        sidecar = sidecar.refreshed(in: doc)
        return try SidecarStore.save(sidecar, for: documentURL, documentText: doc)
    }

    /// Change the sidecar in place.
    public func update<T>(_ change: (inout DocumentSidecar) throws -> T) rethrows -> T { try change(&sidecar) }

    /// Follow text changes (original coordinates, sorted, not overlapping), the same shape as
    /// `ChangeSet.changes` or a refined minimal diff. Low level: in the app the editor's
    /// `SidecarEditHook` calls `follow`, never a feature.
    @discardableResult
    public func applyEdits(_ changes: [Change]) -> SidecarEditResult { sidecar.applyEdits(changes) }

    /// Move the anchors with one edit that turned `old` into `new` (the hook's entry point).
    /// Returns nil and changes nothing when the anchors already point into `new` (a second
    /// editor on the same document reported the same edit), so an edit is applied once however
    /// many editors show the document.
    @discardableResult
    public func follow(_ changes: [Change], old: [UInt16], new: [UInt16]) -> SidecarEditResult? {
        if let t = anchoredText, t.count == new.count, t != old, t == new { return nil }
        anchoredText = new
        guard !changes.isEmpty else { return SidecarEditResult() }
        followCount += 1
        return sidecar.applyEdits(changes, old: old)
    }

    /// A feature changed the text and already moved the anchors itself (a variant swap): the
    /// anchors now point into `new`.
    public func advance(to new: [UInt16]) { anchoredText = new }

    /// The editor's text was replaced as a whole (a reload after an outside edit): find every
    /// anchor again in `doc` by its quote and context. Items that cannot be found move to
    /// `unresolved` (kept, tried again on the next load). No-op when the text is unchanged.
    @discardableResult
    public func reanchor(to doc: String) -> SidecarLoadResult? {
        let units = Array(doc.utf16)
        guard let old = anchoredText else { load(doc: doc); return lastLoad }
        guard old != units else { return nil }
        let stored = sidecar.refreshed(in: String(utf16CodeUnits: old, count: old.count))
        let r = SidecarStore.anchor(stored, in: doc, storedHash: nil)
        sidecar = r.sidecar
        anchoredText = units
        return r
    }
}

/// A ghost as the ghost UI sees it: a range and whether it waits for review.
public struct GhostSpan: Equatable, Sendable {
    public var from: Int
    public var to: Int
    /// True for a Lab proposal that waits for accept or reject.
    public var proposed: Bool
    public init(from: Int, to: Int, proposed: Bool) { self.from = from; self.to = to; self.proposed = proposed }
}

/// Sidecar-backed ghost store with the shape of the ghost UI's `GhostStoring` protocol
/// (`load(doc:)` / `save(_:doc:)`). The UI keeps plain ranges and may merge or split them;
/// on save each span keeps the id, author, date and source of the stored ghost it overlaps,
/// so provenance survives. The quote and context of every ghost are saved for re-anchoring.
///
/// FloKit conformance, to add where `GhostStoring` lives:
///
///     extension SidecarGhostStore: GhostStoring {
///         public func load(doc: String) -> [GhostRange] {
///             loadSpans(doc: doc).map { GhostRange(from: $0.from, to: $0.to, origin: $0.proposed ? .proposed : .author) }
///         }
///         public func save(_ ranges: [GhostRange], doc: String) {
///             saveSpans(ranges.map { GhostSpan(from: $0.from, to: $0.to, proposed: $0.origin == .proposed) }, doc: doc)
///         }
///     }
@MainActor
public final class SidecarGhostStore {
    public let session: SidecarSession
    /// Set when the last save failed (the UI can show it); nil after a good save.
    public private(set) var lastError: Error?

    public init(session: SidecarSession) { self.session = session }
    public convenience init(documentPath: String) { self.init(session: .shared(for: documentPath)) }

    /// Ghosts of the document anchored in `doc`, sorted. Loads the file on first use.
    public func loadSpans(doc: String) -> [GhostSpan] {
        session.loadIfNeeded(doc: doc)
        let length = doc.utf16.count
        return session.sidecar.ghosts
            .filter { $0.anchor.from >= 0 && $0.anchor.to <= length && $0.anchor.to > $0.anchor.from }
            .sorted { ($0.anchor.from, $0.anchor.to) < ($1.anchor.from, $1.anchor.to) }
            .map { GhostSpan(from: $0.anchor.from, to: $0.anchor.to, proposed: $0.state == .proposed) }
    }

    /// Replace the document's ghosts with `spans` and write the sidecar (alternatives and
    /// overflow in the same file are kept).
    public func saveSpans(_ spans: [GhostSpan], doc: String) {
        session.loadIfNeeded(doc: doc)
        session.update { $0.ghosts = Self.merge(spans, into: $0.ghosts, docLength: doc.utf16.count) }
        do { try session.save(doc: doc); lastError = nil } catch { lastError = error }
    }

    /// New ghost records for `spans`, reusing the metadata of the old ghost each one overlaps
    /// most (same state). Spans with no match are new: author `me` when ghosted, `ai` when proposed.
    static func merge(_ spans: [GhostSpan], into old: [GhostRecord], docLength: Int, now: Date = SidecarClock.now()) -> [GhostRecord] {
        var used = Set<String>()
        var out: [GhostRecord] = []
        for s in spans where s.from >= 0 && s.to > s.from && s.to <= docLength {
            let state: GhostState = s.proposed ? .proposed : .ghosted
            let candidates = old.filter { $0.state == state && !used.contains($0.id) && $0.anchor.from < s.to && s.from < $0.anchor.to }
            let best = candidates.max { overlap($0, s) < overlap($1, s) }
            var g = best ?? GhostRecord(anchor: TextAnchor(from: s.from, to: s.to), author: s.proposed ? .ai : .me, state: state, createdAt: now)
            if let b = best { used.insert(b.id) }
            g.anchor = TextAnchor(from: s.from, to: s.to)
            out.append(g)
        }
        return out
    }

    private static func overlap(_ g: GhostRecord, _ s: GhostSpan) -> Int {
        max(0, min(g.anchor.to, s.to) - max(g.anchor.from, s.from))
    }
}
