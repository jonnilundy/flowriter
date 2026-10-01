import AppKit
import FloCore

/// What one state change did to the document, as the sidecar saw it. Ghosts and alternatives
/// get this after the hook moved the shared anchors; they read the moved state from the session.
public struct SidecarEdit {
    /// The document before and after the change.
    public let old: Text
    public let new: Text
    /// The sidecar before the hook moved it (sets or ghosts the edit dropped are still in it).
    public let before: DocumentSidecar
    /// Items the edit dropped (their whole text was deleted).
    public let result: SidecarEditResult
    /// Undo or redo.
    public let history: Bool
    /// Every text change of it came from a feature that moved the anchors itself (`anchored`).
    public let anchored: Bool
    /// The changes the hook applied to the anchors, per transaction (old-document coordinates of
    /// that transaction). Empty for an anchored change.
    public let applied: [[Change]]
}

/// Flowriter: the ONE place where editor text changes reach the document sidecar. Every
/// committed editor transaction (typing, paste, cut, undo / redo, format commands, a stash)
/// goes to `SidecarSession.follow` exactly once, from `EditorFeatures.stateDidChange`, before
/// the ghost and alternatives layers look at the change. The layers never map anchors
/// themselves. A feature that changes the text and has already moved the anchors (a variant
/// swap, where an enclosing set follows its word) dispatches inside `anchored { }`: the hook
/// then skips those transactions.
///
/// Coordinates are the editor text (see DocumentSidecar's FORMAT note on frontmatter).
@MainActor
public final class SidecarEditHook {
    unowned let editor: EditorController
    public let session: SidecarSession
    public var documentPath: String { session.documentURL.path }

    private var lastDoc: Text
    private var anchoredDepth = 0
    /// Documents produced by anchored transactions since the last state change (kept strongly,
    /// so identities cannot be reused).
    private var anchoredResults: [Text] = []

    /// The last change the hook forwarded (tests).
    public private(set) var lastEdit: SidecarEdit?

    init(editor: EditorController, session: SidecarSession) {
        self.editor = editor
        self.session = session
        lastDoc = editor.state.doc
    }

    /// The editor's hook for `documentPath`, created on first use (ghosts, alternatives and
    /// overflow each ask for it; the first one creates it). Loads the sidecar once per document.
    @discardableResult
    public static func ensure(on editor: EditorController, documentPath: String) -> SidecarEditHook {
        let session = SidecarSession.shared(for: documentPath)
        if let h = editor.sidecarHook, h.session === session { return h }
        let h = SidecarEditHook(editor: editor, session: session)
        editor.sidecarHook = h
        h.documentReplaced()
        return h
    }

    /// Run `body`, which dispatches editor transactions whose anchors the caller already moved in
    /// `session.sidecar` (for example `DocumentSidecar.selectVariant`). Those transactions are not
    /// applied again.
    public func anchored<T>(_ body: () throws -> T) rethrows -> T {
        anchoredDepth += 1
        defer { anchoredDepth -= 1 }
        return try body()
    }

    // MARK: editor hooks (EditorFeatures)

    /// Every dispatched transaction (EditorFeatures.observe).
    func observe(_ tr: Transaction) {
        if anchoredDepth > 0, tr.docChanged { anchoredResults.append(tr.state.doc) }
    }

    /// The whole text was loaded or reloaded: load the sidecar on the document's first open,
    /// else find the anchors again in the new text by their quotes.
    func documentReplaced() {
        let doc = editor.state.doc
        if !session.isLoaded { session.load(doc: doc.string) } else { session.reanchor(to: doc.string) }
        lastDoc = doc
        anchoredResults = []
        lastEdit = nil
    }

    /// After a state change reached the text view, with its transactions. Returns the edit
    /// (nil when the text did not change).
    func stateDidChange(_ trs: [Transaction]) -> SidecarEdit? {
        let doc = editor.state.doc
        let old = lastDoc
        let anchoredDocs = anchoredResults
        anchoredResults = []
        guard doc !== old else { return nil }
        lastDoc = doc
        let oldUnits = old.units, newUnits = doc.units
        guard oldUnits != newUnits else { return nil }

        let before = session.sidecar
        var result = SidecarEditResult()
        var applied: [[Change]] = []
        var history = false, allAnchored = true
        var cur = old
        var curUnits = oldUnits
        for tr in trs where tr.docChanged {
            guard tr.startState.doc === cur || tr.startState.doc.units == curUnits else { continue }
            let next = tr.state.doc, nextUnits = next.units
            if tr.isUserEvent("undo") || tr.isUserEvent("redo") { history = true }
            if anchoredDocs.contains(where: { $0 === next }) {
                session.advance(to: nextUnits)
            } else {
                allAnchored = false
                let changes = refine(tr.changes.changes, old: curUnits)
                if let r = session.follow(changes, old: curUnits, new: nextUnits) {
                    result.droppedAlternatives += r.droppedAlternatives
                    result.droppedGhosts += r.droppedGhosts
                    applied.append(changes)
                }
            }
            cur = next
            curUnits = nextUnits
        }
        if curUnits != newUnits {
            // a change that bypassed the transaction observer: follow the one differing span
            allAnchored = false
            history = true
            let changes = GhostMath.diff(old: curUnits, new: newUnits).map { [$0] } ?? []
            if let r = session.follow(changes, old: curUnits, new: newUnits) {
                result.droppedAlternatives += r.droppedAlternatives
                result.droppedGhosts += r.droppedGhosts
                applied.append(changes)
            }
        }
        let e = SidecarEdit(old: old, new: doc, before: before, result: result, history: history,
                            anchored: allAnchored, applied: applied)
        lastEdit = e
        return e
    }

    /// The smallest form of each change: a change that replaces a whole paragraph to add one
    /// letter becomes the one letter (the text view reports some edits that way). A change on
    /// exactly an alternative set's range stays whole, so the set keeps it (an undo of a swap).
    func refine(_ changes: [Change], old: [UInt16]) -> [Change] {
        let sets = session.sidecar.alternatives
        return changes.compactMap { c in
            if c.to > c.from, sets.contains(where: { $0.anchor.from == c.from && $0.anchor.to == c.to }) { return c }
            return GhostMath.refine([c], old: old).first
        }
    }
}
