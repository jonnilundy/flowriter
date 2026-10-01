import Foundation

/// A range of the document in UTF-16 code units (`from..<to`, never empty), plus the text-quote
/// selector saved with it: the covered `quote` and up to `contextLength` units of `prefix` and
/// `suffix`. The selector is refreshed on save (`refreshed(in:)`) and used on load to find the
/// range again after edits made outside the app (`TextAnchor.resolve`).
public struct TextAnchor: Equatable, Sendable {
    public static let contextLength = 32

    public var from: Int
    public var to: Int
    public var quote: String
    public var prefix: String
    public var suffix: String

    public init(from: Int, to: Int, quote: String = "", prefix: String = "", suffix: String = "") {
        self.from = from; self.to = to; self.quote = quote; self.prefix = prefix; self.suffix = suffix
    }

    public var length: Int { to - from }
    public var range: NSRange { NSRange(location: from, length: to - from) }

    // MARK: Following edits

    /// This anchor after `change` (a UTF-16 range of the text before the change, replaced by
    /// `change.insert`), or nil when the change deleted every character it covered.
    ///
    /// Rules, which the fuzz test checks against a per-character model:
    /// - An insertion at `from` or at `to` stays outside; one strictly inside grows the anchor.
    /// - A deletion or replacement that lies within the anchor (edges included, but not the
    ///   whole anchor) shrinks it and the new text joins it.
    /// - One that crosses an edge removes the covered part; the new text stays outside.
    /// - One that covers the whole anchor drops it.
    public func mapped(through change: Change) -> TextAnchor? {
        guard let (f, t) = Self.map(from: from, to: to, a: change.from, b: change.to, n: change.insert.utf16.count) else { return nil }
        var m = self
        m.from = f; m.to = t
        return m
    }

    /// Like `mapped(through:)` for a replacement of `a..<b` by `insertLength` units, except that an
    /// anchor containing `a..<b` (edges included, also when equal) keeps the new text. Used for
    /// variant swaps, where an enclosing sentence or paragraph set must follow its word.
    func mapped(throughReplacementOf a: Int, _ b: Int, insertLength n: Int) -> TextAnchor? {
        if from <= a && b <= to {
            var m = self
            m.to = to + n - (b - a)
            return m.to > m.from ? m : nil
        }
        guard let (f, t) = Self.map(from: from, to: to, a: a, b: b, n: n) else { return nil }
        var m = self
        m.from = f; m.to = t
        return m
    }

    static func map(from f: Int, to t: Int, a: Int, b: Int, n: Int) -> (Int, Int)? {
        let d = n - (b - a)
        if a == b {
            if n == 0 { return (f, t) }
            if a <= f { return (f + n, t + n) }
            if a >= t { return (f, t) }
            return (f, t + n)
        }
        if b <= f { return (f + d, t + d) }
        if a >= t { return (f, t) }
        if a <= f && b >= t { return nil }
        if a >= f && b <= t { return (f, t + d) }
        if a < f { return (a + n, t + d) }   // crosses the start: b is inside
        return (f, a)                         // crosses the end: a is inside
    }

    // MARK: Selector

    /// The anchor with quote, prefix and suffix taken from `units` (the current document).
    public func refreshed(in units: [UInt16]) -> TextAnchor {
        let f = max(0, min(from, units.count)), t = max(f, min(to, units.count))
        let p0 = max(0, f - Self.contextLength), s1 = min(units.count, t + Self.contextLength)
        return TextAnchor(from: f, to: t,
                          quote: Self.string(units[f..<t]),
                          prefix: Self.string(units[p0..<f]),
                          suffix: Self.string(units[t..<s1]))
    }

    static func string(_ s: ArraySlice<UInt16>) -> String { String(utf16CodeUnits: Array(s), count: s.count) }
}

/// Why an anchor could not be found again.
public enum AnchorFailure: String, Sendable, Equatable {
    /// The quoted text is no longer in the document.
    case notFound
    /// The quote occurs more than once and the context does not pick one.
    case ambiguous
    /// The file stored no quote (nothing to search for).
    case noQuote
}

/// How an anchor was found again on load.
public enum AnchorResolution: Equatable, Sendable {
    /// Same text at the stored offsets, with the same context.
    case exact(TextAnchor)
    /// Found at another place (the document changed outside the app).
    case moved(TextAnchor)
    case failed(AnchorFailure)

    public var anchor: TextAnchor? {
        switch self {
        case let .exact(a), let .moved(a): return a
        case .failed: return nil
        }
    }
}

extension TextAnchor {
    /// Find this anchor's quote in `units`, like a W3C text-quote selector with a position hint.
    ///
    /// 1. The quote at the stored offsets with matching context (or an unchanged document) wins.
    /// 2. Else every occurrence of the quote is scored by how much of the stored prefix and
    ///    suffix still borders it. One occurrence: taken. Several: the best score is taken when
    ///    it beats the second best; a tie is `ambiguous` (reported, not guessed).
    public func resolve(in units: [UInt16], documentUnchanged: Bool = false) -> AnchorResolution {
        let q = Array(quote.utf16)
        guard !q.isEmpty else { return .failed(.noQuote) }
        let p = Array(prefix.utf16), s = Array(suffix.utf16)
        func score(_ at: Int) -> Int {
            Self.commonSuffix(p, units[max(0, at - p.count)..<at]) + Self.commonPrefix(s, units[(at + q.count)..<min(units.count, at + q.count + s.count)])
        }
        let hintOK = from >= 0 && from + q.count <= units.count && Array(units[from..<(from + q.count)]) == q
        if hintOK && (documentUnchanged || score(from) == p.count + s.count) {
            return .exact(TextAnchor(from: from, to: from + q.count).refreshed(in: units))
        }
        let hits = Self.occurrences(of: q, in: units)
        guard !hits.isEmpty else { return .failed(.notFound) }
        if hits.count == 1 { return .moved(TextAnchor(from: hits[0], to: hits[0] + q.count).refreshed(in: units)) }
        let ranked = hits.map { (at: $0, score: score($0)) }.sorted { $0.score > $1.score }
        guard ranked[0].score > ranked[1].score else { return .failed(.ambiguous) }
        let at = ranked[0].at
        return .moved(TextAnchor(from: at, to: at + q.count).refreshed(in: units))
    }

    static func occurrences(of q: [UInt16], in units: [UInt16]) -> [Int] {
        guard !q.isEmpty, q.count <= units.count else { return [] }
        var out: [Int] = []
        let first = q[0]
        var i = 0
        let last = units.count - q.count
        while i <= last {
            if units[i] == first {
                var k = 1
                while k < q.count && units[i + k] == q[k] { k += 1 }
                if k == q.count { out.append(i) }
            }
            i += 1
        }
        return out
    }

    /// Length of the common tail of `a` and `b`.
    static func commonSuffix(_ a: [UInt16], _ b: ArraySlice<UInt16>) -> Int {
        var n = 0
        var i = a.count - 1, j = b.endIndex - 1
        while i >= 0 && j >= b.startIndex && a[i] == b[j] { n += 1; i -= 1; j -= 1 }
        return n
    }

    /// Length of the common head of `a` and `b`.
    static func commonPrefix(_ a: [UInt16], _ b: ArraySlice<UInt16>) -> Int {
        var n = 0
        var j = b.startIndex
        while n < a.count && j < b.endIndex && a[n] == b[j] { n += 1; j += 1 }
        return n
    }
}
