import Foundation
import FloCore

// Flowriter: Alternatives, the pure part (no AppKit). Built on the sidecar model in FloCore
// (DocumentSidecar, AlternativeSet, TextAnchor, Articles, SidecarStore). What this adds for the
// editor:
//   - the current version's text is live: the document is the truth while a version is shown
//     (typing inside it edits that version); only the other versions keep their text;
//   - anchors follow editor transactions through the sidecar's one mapping rule
//     (DocumentSidecar.applyEdit: a change that replaces exactly a set's range keeps the set);
//     in the app the editor's SidecarEditHook applies it to the shared session once and the
//     layer `adopt`s the result;
//   - undo / redo: anchors and current versions are recorded per document content, so an undo
//     puts back the version that went with that text, and brings back sets whose text was
//     deleted whole (kept aside instead of dropped).

extension AlternativeLevel {
    public var title: String {
        switch self { case .word: return "Word"; case .sentence: return "Sentence"; case .paragraph: return "Paragraph" }
    }
}

extension AlternativeSet {
    public var from: Int { anchor.from }
    public var to: Int { anchor.to }
    /// Drawn (underline, dots, margin line) only with a version besides the current text.
    public var visible: Bool { variants.count >= 2 && anchor.to > anchor.from }
    public var showsOriginal: Bool { currentId == originalId }
    public func contains(_ pos: Int) -> Bool { anchor.from <= pos && pos <= anchor.to }
    public func index(of variantId: String) -> Int? { variants.firstIndex { $0.id == variantId } }
}

/// The editor-side state of one document's alternatives. Value type, unit tested.
public struct AlternativesSession: Equatable {
    /// Everything loaded from the sidecar; only `alternatives` is edited here.
    public var sidecar: DocumentSidecar
    public var sets: [AlternativeSet] { sidecar.alternatives }

    /// Sets whose whole text was deleted, kept for undo (never saved).
    private var removedByEdit: [String: AlternativeSet] = [:]
    private var snapshots: [DocKey: [AlternativeSet]] = [:]
    private var snapshotOrder: [DocKey] = []
    static let maxSnapshots = 400

    struct DocKey: Hashable { let length: Int; let hash: Int }
    static func key(_ units: [UInt16]) -> DocKey {
        var h = Hasher()
        units.withUnsafeBufferPointer { h.combine(bytes: UnsafeRawBufferPointer($0)) }
        return DocKey(length: units.count, hash: h.finalize())
    }

    public init(sidecar: DocumentSidecar = DocumentSidecar()) { self.sidecar = sidecar; sortSets() }

    public static func == (a: AlternativesSession, b: AlternativesSession) -> Bool { a.sidecar == b.sidecar }

    public func set(_ id: String) -> AlternativeSet? { sidecar.alternativeSet(id) }

    private mutating func sortSets() { sidecar.alternatives.sort { ($0.anchor.from, $0.anchor.to) < ($1.anchor.from, $1.anchor.to) } }

    static func slice(_ doc: [UInt16], _ a: Int, _ b: Int) -> String {
        let f = max(0, min(a, doc.count)), t = max(f, min(b, doc.count))
        return String(utf16CodeUnits: Array(doc[f..<t]), count: t - f)
    }

    /// Text of a variant: live document text for the current one, stored text for the others.
    public static func text(of v: AlternativeVariant, in set: AlternativeSet, doc: [UInt16]) -> String {
        v.id == set.currentId ? slice(doc, set.anchor.from, set.anchor.to) : v.text
    }

    /// Copy the live text of every current version into its variant (before a swap or a save).
    public mutating func refreshCurrentTexts(doc: [UInt16]) {
        for i in sidecar.alternatives.indices {
            let s = sidecar.alternatives[i]
            if let j = s.index(of: s.currentId) { sidecar.alternatives[i].variants[j].text = Self.slice(doc, s.anchor.from, s.anchor.to) }
        }
    }

    /// The writer typed inside the shown version: an AI version becomes theirs (author "me").
    /// Returns the ids of the sets that changed hands.
    @discardableResult
    public mutating func claimEditedVersions(doc: [UInt16]) -> [String] {
        var out: [String] = []
        for i in sidecar.alternatives.indices {
            let s = sidecar.alternatives[i]
            guard let j = s.index(of: s.currentId), s.variants[j].author == .ai else { continue }
            let live = Self.slice(doc, s.anchor.from, s.anchor.to)
            if live != s.variants[j].text {
                sidecar.alternatives[i].variants[j].author = .me
                sidecar.alternatives[i].variants[j].text = live
                out.append(s.id)
            }
        }
        return out
    }

    // MARK: model edits (through the sidecar API)

    /// Add `text` as a version of `range` at `level`: to the set on exactly that range, else a
    /// new set whose original is the text there now. Returns (set id, new variant id).
    public mutating func addVersion(_ text: String, author: SidecarAuthor, level: AlternativeLevel, range: NSRange, doc: String) throws -> (String, String) {
        let setId: String
        if let s = sets.first(where: { $0.level == level && $0.anchor.from == range.location && $0.anchor.to == NSMaxRange(range) }) {
            setId = s.id
        } else {
            setId = try sidecar.addAlternativeSet(level: level, from: range.location, to: NSMaxRange(range), in: doc).id
            sortSets()
        }
        let v = try sidecar.addVariant(to: setId, text: text, author: author)
        return (setId, v.id)
    }

    /// The document changes that show `variantId` (the range, plus a/an before it). The anchors
    /// are already updated for them: `stateDidChange` must not map them again.
    public mutating func select(_ variantId: String, in setId: String, doc: [UInt16]) throws -> SidecarTextChange? {
        refreshCurrentTexts(doc: doc)
        let r = try sidecar.selectVariant(variantId, in: setId, text: String(utf16CodeUnits: doc, count: doc.count))
        sortSets()
        return r
    }

    /// The variant `step` places after the current one (wrapping).
    public func stepped(_ setId: String, _ step: Int) -> String? {
        guard let s = set(setId), s.variants.count >= 2, let i = s.index(of: s.currentId) else { return nil }
        let n = s.variants.count
        return s.variants[((i + step) % n + n) % n].id
    }

    /// Remove a version that is not shown. With one version left, the set goes (the text stays).
    public mutating func remove(_ variantId: String, from setId: String) throws {
        try sidecar.removeVariant(variantId, from: setId)
        if let s = set(setId), s.variants.count < 2 { sidecar.removeAlternativeSet(setId) }
    }

    // MARK: following edits

    /// Map the anchors through one transaction's changes (old-document coordinates) with the
    /// sidecar's rule. `old` is the document before them (a version that stops being shown keeps
    /// its text). The app does not call this: its SidecarEditHook maps the shared session once
    /// and the layer calls `adopt`. Tests and tools drive the session with it.
    public mutating func map(_ changes: ChangeSet, old: [UInt16]) {
        guard !changes.isEmpty else { return }
        let before = sidecar.alternatives
        var sc = DocumentSidecar(alternatives: before)
        let r = sc.applyEdits(changes.changes, old: old)
        adopt(sc.alternatives, dropped: before.filter { r.droppedAlternatives.contains($0.id) })
    }

    /// Take anchors that were already moved (the shared session after the editor's hook), and
    /// keep the sets the edit dropped aside for undo.
    public mutating func adopt(_ mapped: [AlternativeSet], dropped: [AlternativeSet]) {
        for s in dropped { removedByEdit[s.id] = s }
        sidecar.alternatives = mapped
        sortSets()
    }

    /// Remember anchors + current versions for this document content.
    public mutating func record(doc: [UInt16]) {
        let k = Self.key(doc)
        if snapshots[k] == nil { snapshotOrder.append(k) }
        snapshots[k] = sidecar.alternatives
        if snapshotOrder.count > Self.maxSnapshots { snapshots[snapshotOrder.removeFirst()] = nil }
    }

    /// Undo / redo: the document is back to a content seen before. Put back the anchors and
    /// current versions recorded with it (and sets its text had deleted). `old` / `oldSets`: the
    /// state before the undo, so the version that stops being shown keeps its live text.
    /// Sets created since stay as mapped; sets the writer removed stay removed.
    @discardableResult
    public mutating func restore(doc: [UInt16], old: [UInt16], oldSets: [AlternativeSet]) -> Bool {
        guard let snap = snapshots[Self.key(doc)] else { return false }
        var out: [AlternativeSet] = []
        var seen = Set<String>()
        for s in snap {
            guard var live = sidecar.alternativeSet(s.id) ?? removedByEdit[s.id] else { continue }
            if let before = oldSets.first(where: { $0.id == s.id }), before.currentId != s.currentId,
               let j = live.index(of: before.currentId) {
                live.variants[j].text = Self.slice(old, before.anchor.from, before.anchor.to)
            }
            live.anchor = s.anchor
            if live.index(of: s.currentId) != nil { live.currentId = s.currentId }
            // authors go back with the text they had then (an undone edit gives an AI version back)
            for j in live.variants.indices {
                guard let sv = s.variants.first(where: { $0.id == live.variants[j].id }), sv.author != live.variants[j].author else { continue }
                if Self.text(of: live.variants[j], in: live, doc: doc) == sv.text { live.variants[j].author = sv.author }
            }
            out.append(live)
            seen.insert(s.id)
            removedByEdit[s.id] = nil
        }
        out += sidecar.alternatives.filter { !seen.contains($0.id) }
        sidecar.alternatives = out
        sortSets()
        return true
    }

    /// Smallest visible set at a position, optionally of one level.
    public func innermost(at pos: Int, level: AlternativeLevel? = nil) -> AlternativeSet? {
        sets.filter { $0.visible && $0.contains(pos) && (level == nil || $0.level == level) }
            .min { $0.anchor.length < $1.anchor.length }
    }
}

// MARK: - text units: word, sentence, paragraph at a position

public enum AltText {
    static func isWordChar(_ c: unichar) -> Bool {
        if c == 0x27 || c == 0x2019 || c == 0x2D { return true }   // ' ’ -
        guard let s = Unicode.Scalar(c) else { return true }        // surrogates: part of a word
        return CharacterSet.alphanumerics.contains(s)
    }

    static func isWordBoundary(_ ns: NSString, _ r: NSRange) -> Bool {
        let before = r.location == 0 || !isWordChar(ns.character(at: r.location - 1))
        let end = NSMaxRange(r)
        let after = end >= ns.length || !isWordChar(ns.character(at: end))
        return before && after
    }

    /// The word touching `pos` (the one on the left when `pos` sits between two).
    public static func word(in ns: NSString, at pos: Int) -> NSRange? {
        let p = max(0, min(pos, ns.length))
        let right = p < ns.length && isWordChar(ns.character(at: p))
        let left = p > 0 && isWordChar(ns.character(at: p - 1))
        guard right || left else { return nil }
        var a = p, b = p
        while a > 0, isWordChar(ns.character(at: a - 1)) { a -= 1 }
        while b < ns.length, isWordChar(ns.character(at: b)) { b += 1 }
        // trim leading / trailing apostrophes and hyphens (quotes, dashes)
        while a < b, [0x27, 0x2019, 0x2D].contains(ns.character(at: a)) { a += 1 }
        while b > a, [0x27, 0x2019, 0x2D].contains(ns.character(at: b - 1)) { b -= 1 }
        return b > a ? NSRange(location: a, length: b - a) : nil
    }

    /// Markdown block prefix of a line: heading hashes, quote marks, list markers, checkboxes.
    static let blockPrefix = try! NSRegularExpression(pattern: #"^[ \t]*(?:(?:#{1,6}[ \t]+)|(?:>[ \t]?)|(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?)|(?:\d{1,9}[.)][ \t]+(?:\[[ xX]\][ \t]+)?))*"#)

    /// The paragraph (source line) holding `pos`, without its block prefix and trailing spaces.
    public static func paragraph(in ns: NSString, at pos: Int) -> NSRange? {
        let p = max(0, min(pos, ns.length))
        let line = ns.lineRange(for: NSRange(location: p, length: 0))
        var a = line.location, b = NSMaxRange(line)
        while b > a, [0x0A, 0x0D].contains(ns.character(at: b - 1)) { b -= 1 }
        let m = blockPrefix.firstMatch(in: ns as String, range: NSRange(location: a, length: b - a))
        if let m = m { a = NSMaxRange(m.range) }
        while b > a, [0x20, 0x09].contains(ns.character(at: b - 1)) { b -= 1 }
        guard b > a, !isFence(ns.substring(with: NSRange(location: a, length: b - a))) else { return nil }
        return NSRange(location: a, length: b - a)
    }

    static func isFence(_ s: String) -> Bool { s.hasPrefix("```") || s.hasPrefix("~~~") || s == "---" }

    /// The sentence holding `pos`, inside its paragraph, without trailing spaces.
    public static func sentence(in ns: NSString, at pos: Int) -> NSRange? {
        guard let para = paragraph(in: ns, at: pos) else { return nil }
        let p = max(para.location, min(pos, NSMaxRange(para)))
        var found: NSRange?
        var last: NSRange?
        ns.enumerateSubstrings(in: para, options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            var a = r.location, b = NSMaxRange(r)
            while b > a, [0x20, 0x09, 0x0A].contains(ns.character(at: b - 1)) { b -= 1 }
            while a < b, [0x20, 0x09].contains(ns.character(at: a)) { a += 1 }
            let t = NSRange(location: a, length: b - a)
            if t.length > 0 { last = t }
            if t.length > 0, p >= a, p <= b { found = t; stop.pointee = true }
        }
        return found ?? (p >= NSMaxRange(para) ? last : nil)
    }

    public static func range(_ level: AlternativeLevel, in ns: NSString, at pos: Int) -> NSRange? {
        switch level {
        case .word: return word(in: ns, at: pos)
        case .sentence: return sentence(in: ns, at: pos)
        case .paragraph: return paragraph(in: ns, at: pos)
        }
    }

    /// The level a selection reads as: a whole paragraph, a single word, else a sentence.
    public static func level(of r: NSRange, in ns: NSString) -> AlternativeLevel {
        if let p = paragraph(in: ns, at: r.location), p == r { return .paragraph }
        let s = ns.substring(with: r)
        if s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return .word }
        return .sentence
    }

    /// A selection trimmed of surrounding whitespace.
    public static func trimmed(_ r: NSRange, in ns: NSString) -> NSRange {
        var a = r.location, b = NSMaxRange(r)
        while a < b, CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(ns.character(at: a)) ?? " ") { a += 1 }
        while b > a, CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(ns.character(at: b - 1)) ?? " ") { b -= 1 }
        return NSRange(location: a, length: b - a)
    }
}

