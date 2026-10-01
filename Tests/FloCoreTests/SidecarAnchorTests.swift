import XCTest
@testable import FloCore

/// Anchors following in-app edits: a table of edit shapes, then a seeded fuzz against a
/// per-character model (each UTF-16 unit carries an identity; an anchor owns a set of them).
final class SidecarAnchorTests: XCTestCase {
    // MARK: Shapes

    func testEditShapes() {
        // Anchor 10..<20 through (from, to, insert) -> expected, nil = dropped.
        let cases: [(Int, Int, String, (Int, Int)?, String)] = [
            (0, 0, "abc", (13, 23), "insert before"),
            (10, 10, "abc", (13, 23), "insert at start stays outside"),
            (20, 20, "abc", (10, 20), "insert at end stays outside"),
            (15, 15, "abc", (10, 23), "insert inside grows"),
            (30, 30, "abc", (10, 20), "insert after"),
            (2, 5, "", (7, 17), "delete before"),
            (5, 10, "", (5, 15), "delete ending at start"),
            (20, 25, "", (10, 20), "delete starting at end"),
            (12, 15, "", (10, 17), "delete inside shrinks"),
            (10, 12, "", (10, 18), "delete head"),
            (18, 20, "", (10, 18), "delete tail"),
            (10, 20, "", nil, "delete whole"),
            (5, 25, "x", nil, "replace around"),
            (10, 20, "xyz", nil, "replace whole drops"),
            (10, 11, "An", (10, 21), "replace first unit keeps new text"),
            (19, 20, "yz", (10, 21), "replace last unit keeps new text"),
            (12, 14, "wxyz", (10, 22), "replace inside"),
            (5, 12, "ab", (7, 15), "cross start: new text outside"),
            (18, 25, "ab", (10, 18), "cross end: new text outside"),
            (15, 15, "", (10, 20), "empty change"),
        ]
        for (a, b, ins, want, name) in cases {
            let got = TextAnchor(from: 10, to: 20).mapped(through: Change(from: a, to: b, insert: ins))
            if let want {
                XCTAssertEqual(got.map { [$0.from, $0.to] }, [want.0, want.1], name)
            } else {
                XCTAssertNil(got, name)
            }
        }
    }

    func testUTF16Units() {
        // An emoji is two UTF-16 units; inserting it inside grows the anchor by 2.
        let got = TextAnchor(from: 0, to: 4).mapped(through: Change(from: 2, to: 2, insert: "😀"))
        XCTAssertEqual(got?.to, 6)
    }

    func testChangeSetPath() throws {
        let text = "one two three four five"
        var sc = DocumentSidecar()
        let g = try sc.addGhost(from: 8, to: 13)            // "three"
        let cs = ChangeSet([Change(from: 0, to: 3, insert: "ONE!"), Change(from: 14, to: 18, insert: "")], docLength: text.utf16.count)
        sc.apply(cs)
        let newText = DocumentSidecar.applying(cs.changes, to: text)
        let a = try XCTUnwrap(sc.ghost(g.id)).anchor
        XCTAssertEqual(slice(newText, a), "three")
    }

    // MARK: Fuzz

    /// Stats of the last fuzz run, printed for the report.
    struct Stats { var docs = 0, edits = 0, batches = 0, checks = 0, dropped = 0, survived = 0 }

    func testFuzzAnchorsFollowEdits() throws {
        var stats = Stats()
        for seed in UInt64(1)...250 {
            try fuzzOne(seed: seed, edits: 250, stats: &stats)
        }
        print("SIDECAR FUZZ docs=\(stats.docs) edits=\(stats.edits) batches=\(stats.batches) anchorChecks=\(stats.checks) dropped=\(stats.dropped) survivedToEnd=\(stats.survived)")
        XCTAssertGreaterThan(stats.dropped, 0, "the generator must also produce whole-range deletions")
        XCTAssertGreaterThan(stats.survived, 0)
    }

    private struct Model {
        var units: [UInt16]
        var ids: [Int]
        var nextId: Int
        /// Anchor id -> owned character ids.
        var members: [String: Set<Int>]
    }

    private func fuzzOne(seed: UInt64, edits: Int, stats: inout Stats) throws {
        var rng = SplitMix64(seed: seed)
        let alphabet = Array("abcdefghij  .,\n".utf16) + Array("é😀".utf16)
        let len = rng.int(20...300)
        var model = Model(units: (0..<len).map { _ in alphabet[rng.int(0..<alphabet.count)] }, ids: Array(0..<len), nextId: len, members: [:])
        var sc = DocumentSidecar()
        stats.docs += 1

        func addAnchor() throws {
            guard model.units.count >= 2 else { return }
            let f = rng.int(0..<(model.units.count - 1)), t = rng.int((f + 1)...min(model.units.count, f + 40))
            let id: String
            if rng.bool() {
                id = try sc.addGhost(from: f, to: t, id: "g\(model.nextId)").id
            } else {
                id = try sc.addAlternativeSet(level: .word, from: f, to: t, in: string(model.units), id: "a\(model.nextId)").id
            }
            model.nextId += 1
            model.members[id] = Set(model.ids[f..<t])
        }
        for _ in 0..<rng.int(3...10) { try addAnchor() }

        for step in 0..<edits {
            if step % 8 == 7 || sc.alternatives.count + sc.ghosts.count < 3 { try addAnchor() }
            let n = model.units.count
            if rng.int(0..<10) == 0 && n > 10 {
                // A batch of 2 to 4 changes in original coordinates, gaps between them.
                var cuts = Set<Int>()
                while cuts.count < rng.int(4...8) { cuts.insert(rng.int(0...n)) }
                let points = cuts.sorted()
                var changes: [Change] = []
                var k = 0
                while k + 1 < points.count {
                    let a = points[k], b = rng.bool() ? points[k] : points[k + 1]
                    changes.append(Change(from: a, to: b, insert: insertText(&rng, alphabet)))
                    k += 2
                }
                changes = changes.filter { !($0.from == $0.to && $0.insert.isEmpty) }
                var ok = true
                for i in 1..<max(1, changes.count) where changes[i].from <= changes[i - 1].to { ok = false }
                guard ok, !changes.isEmpty else { continue }
                if rng.bool() {
                    sc.applyEdits(changes)
                } else {
                    sc.apply(ChangeSet(changes, docLength: n))
                }
                for c in changes.reversed() { apply(c, to: &model) }
                stats.batches += 1
                stats.edits += changes.count
            } else {
                let c = randomEdit(&rng, n: n, sc: sc, alphabet: alphabet)
                sc.applyEdit(c)
                apply(c, to: &model)
                stats.edits += 1
            }
            try check(sc, model, seed: seed, step: step, stats: &stats)
        }
        stats.survived += sc.alternatives.count + sc.ghosts.count
        stats.dropped += model.members.values.filter { $0.isEmpty }.count
    }

    /// Edits biased to anchor edges, where the rules differ.
    private func randomEdit(_ rng: inout SplitMix64, n: Int, sc: DocumentSidecar, alphabet: [UInt16]) -> Change {
        let anchors = sc.alternatives.map(\.anchor) + sc.ghosts.map(\.anchor)
        func pos() -> Int {
            if !anchors.isEmpty && rng.int(0..<3) > 0 {
                let a = anchors[rng.int(0..<anchors.count)]
                let p = [a.from, a.to, a.from - 1, a.from + 1, a.to - 1, a.to + 1][rng.int(0..<6)]
                return max(0, min(n, p))
            }
            return rng.int(0...n)
        }
        switch rng.int(0..<12) {
        case 0...3: return Change(from: pos(), insert: insertText(&rng, alphabet))
        case 4...7:
            let a = pos(), b = min(n, a + rng.int(0...12))
            return Change(from: a, to: b, insert: rng.bool() ? "" : insertText(&rng, alphabet))
        case 8:
            var a = pos(), b = pos()
            if a > b { swap(&a, &b) }
            return Change(from: a, to: b, insert: rng.bool() ? "" : insertText(&rng, alphabet))
        case 9:
            if let a = anchors.randomElement(using: &rng) {   // exactly the anchor
                return Change(from: a.from, to: a.to, insert: rng.bool() ? "" : insertText(&rng, alphabet))
            }
            return Change(from: pos(), insert: "x")
        default:
            let a = rng.int(0...n), b = min(n, a + rng.int(0...5))
            return Change(from: a, to: b, insert: rng.bool() ? "" : insertText(&rng, alphabet))
        }
    }

    private func insertText(_ rng: inout SplitMix64, _ alphabet: [UInt16]) -> String {
        var s = ""
        for _ in 0..<rng.int(1...6) {
            let pick = rng.int(0..<4)
            s += pick == 0 ? "😀" : pick == 1 ? "é" : String(UnicodeScalar(UInt8(97 + rng.int(0..<26))))
        }
        return s
    }

    /// Apply to the per-character model. New characters join an anchor only when the change
    /// lies inside it (see `TextAnchor.mapped(through:)`), or, for an alternative set ("a" ids),
    /// when the change replaces exactly its range (see `DocumentSidecar.applyEdit`).
    private func apply(_ c: Change, to m: inout Model) {
        let ins = Array(c.insert.utf16)
        let newIds = (0..<ins.count).map { m.nextId + $0 }
        m.nextId += ins.count
        let deleted = Set(m.ids[c.from..<c.to])
        for (key, set) in m.members {
            guard let f = m.ids.firstIndex(where: set.contains), let l = m.ids.lastIndex(where: set.contains) else { continue }
            let t = l + 1
            if key.hasPrefix("a"), c.from == f, c.to == t, c.to > c.from {
                m.members[key] = Set(newIds)
                continue
            }
            var s = set.subtracting(deleted)
            let inside: Bool
            if c.from == c.to { inside = f < c.from && c.from < t }
            else { inside = f <= c.from && c.to <= t && !(c.from <= f && c.to >= t) }
            if inside && !s.isEmpty { s.formUnion(newIds) }
            m.members[key] = s
        }
        m.units.replaceSubrange(c.from..<c.to, with: ins)
        m.ids.replaceSubrange(c.from..<c.to, with: newIds)
    }

    private func check(_ sc: DocumentSidecar, _ m: Model, seed: UInt64, step: Int, stats: inout Stats) throws {
        var live: [String: TextAnchor] = [:]
        for a in sc.alternatives { live[a.id] = a.anchor }
        for g in sc.ghosts { live[g.id] = g.anchor }
        for (key, set) in m.members {
            let ctx = "seed \(seed) step \(step) anchor \(key)"
            if set.isEmpty {
                if live[key] != nil { XCTFail("\(ctx): should have been dropped"); throw Stop() }
                continue
            }
            guard let a = live[key] else { XCTFail("\(ctx): dropped but still owns \(set.count) characters"); throw Stop() }
            let covered = m.ids[a.from..<a.to]
            if Set(covered) != set || covered.count != set.count {
                XCTFail("\(ctx): covers \(a.from)..<\(a.to), not its characters")
                throw Stop()
            }
            stats.checks += 1
        }
        XCTAssertEqual(live.count, m.members.values.filter { !$0.isEmpty }.count)
    }

    struct Stop: Error {}

    private func string(_ u: [UInt16]) -> String { String(utf16CodeUnits: u, count: u.count) }
    private func slice(_ s: String, _ a: TextAnchor) -> String { string(Array(Array(s.utf16)[a.from..<a.to])) }
}

/// Deterministic generator for the fuzz tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: Range<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func bool() -> Bool { Bool.random(using: &self) }
}
