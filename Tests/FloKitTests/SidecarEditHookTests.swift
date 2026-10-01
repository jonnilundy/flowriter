import XCTest
import AppKit
@testable import FloKit
import FloCore

/// The one shared edit hook: with ghosts, alternatives and overflow on the same document, every
/// editor change moves every anchor exactly once. Needs a window (KeyReplayer): run in the VM.
@MainActor
final class SidecarEditHookTests: XCTestCase {
    var dir: URL!
    var path: String { dir.appendingPathComponent("post.md").path }
    // "thumbtack" gets a second version, "ruler, and some string" is ghosted, one overflow item.
    let text = "---\ntitle: Pencil case\n---\n\nThe case holds a thumbtack, a ruler, and some string. None of it matters much.\n"

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("flo-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        SidecarSession.discard(documentPath: path)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    struct Setup { let r: KeyReplayer; let ghosts: GhostLayer; let alts: AlternativesLayer; let session: SidecarSession; let setId: String }

    /// A post with one alternative set, one ghost and one overflow item saved in its sidecar, open
    /// in an editor with all three features attached.
    func open() throws -> Setup {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let ns = text as NSString
        var sc = DocumentSidecar()
        let word = ns.range(of: "thumbtack")
        let set = try sc.addAlternativeSet(level: .word, from: word.location, to: NSMaxRange(word), in: text)
        try sc.addVariant(to: set.id, text: "pushpin", author: .me)
        let ghost = ns.range(of: "ruler, and some string")
        try sc.addGhost(from: ghost.location, to: NSMaxRange(ghost))
        sc.addOverflow("a line I cut")
        try SidecarStore.save(sc.refreshed(in: text), for: URL(fileURLWithPath: path), documentText: text)
        SidecarSession.discard(documentPath: path)

        let r = KeyReplayer()
        r.controller.documentPath = path
        r.load(text, selection: .cursor(0))
        let g = GhostLayer.attach(to: r.controller, store: SidecarGhostStore(documentPath: path))
        let a = AlternativesLayer.attach(to: r.controller, documentPath: path)
        let hook = SidecarEditHook.ensure(on: r.controller, documentPath: path)   // overflow asks for it too
        XCTAssertTrue(r.controller.sidecarHook === hook, "one hook per editor, shared by the features")
        return Setup(r: r, ghosts: g, alts: a, session: SidecarSession.shared(for: path), setId: set.id)
    }

    struct Spans: Equatable { var alt: [Int]; var layerAlt: [Int]; var ghost: [Int]; var layerGhost: [Int] }
    func spans(_ s: Setup) -> Spans {
        let a = s.session.sidecar.alternatives[0].anchor, g = s.session.sidecar.ghosts[0].anchor
        let la = s.alts.session.sets[0].anchor, lg = s.ghosts.ranges[0]
        return Spans(alt: [a.from, a.to], layerAlt: [la.from, la.to], ghost: [g.from, g.to], layerGhost: [lg.from, lg.to])
    }
    func shifted(_ x: Spans, _ d: Int) -> Spans {
        Spans(alt: x.alt.map { $0 + d }, layerAlt: x.layerAlt.map { $0 + d }, ghost: x.ghost.map { $0 + d }, layerGhost: x.layerGhost.map { $0 + d })
    }

    func testOneKeystrokeMovesEveryAnchorExactlyOnce() throws {
        let s = try open()
        XCTAssertEqual(s.session.sidecar.overflow.count, 1)
        let start = spans(s)
        let body = (text as NSString).range(of: "The case").location
        s.r.controller.run { t in t.dispatch(TransactionSpec(selection: .cursor(body))); return true }
        let follows = s.session.followCount

        s.r.press("x")   // one keystroke, native typing path, before every anchor
        XCTAssertEqual(s.r.doc, (text as NSString).replacingCharacters(in: NSRange(location: body, length: 0), with: "x"))
        XCTAssertEqual(s.session.followCount, follows + 1, "the hook applied the keystroke once")
        XCTAssertEqual(spans(s), shifted(start, 1), "every anchor moved by exactly one unit")

        // a paste (a command, not the native path) before the anchors: once more, by its length
        s.r.controller.run { t in t.dispatch(TransactionSpec(changes: [Change(from: body, insert: "Yes. ")], userEvent: "input.paste")); return true }
        XCTAssertEqual(s.session.followCount, follows + 2)
        XCTAssertEqual(spans(s), shifted(start, 6))

        // undo both: back where they started, one follow per undo transaction
        XCTAssertTrue(s.r.controller.handleKey("Mod-z"))
        XCTAssertTrue(s.r.controller.handleKey("Mod-z"))
        XCTAssertEqual(s.r.doc, text)
        XCTAssertEqual(spans(s), start)
        XCTAssertEqual(s.session.followCount, follows + 4)

        // typing inside the ghost grows it by one, the set before it does not move
        let inGhost = start.ghost[0] + 3
        s.r.controller.run { t in t.dispatch(TransactionSpec(selection: .cursor(inGhost))); return true }
        s.r.press("q")
        var want = start
        want.ghost[1] += 1; want.layerGhost[1] += 1
        XCTAssertEqual(spans(s), want)
        XCTAssertEqual(s.session.followCount, follows + 5)
        XCTAssertEqual(s.session.anchoredText, s.r.controller.state.doc.units)
    }

    func testSwapIsAnchoredOnceAndTypingAfterItIsItsOwnUndoStep() throws {
        let s = try open()
        let start = spans(s)
        // caret at the end of the word, so typing after the swap touches it
        s.r.controller.run { t in t.dispatch(TransactionSpec(selection: .cursor(start.alt[1]))); return true }
        let follows = s.session.followCount
        // the swap moves the anchors itself: the hook must not apply it again
        XCTAssertTrue(s.alts.cycle(s.setId, by: 1))
        XCTAssertTrue(s.r.doc.contains("holds a pushpin, a ruler"), s.r.doc)
        XCTAssertEqual(s.session.followCount, follows, "an anchored change is not followed")
        let d = "pushpin".utf16.count - "thumbtack".utf16.count
        var want = start
        want.alt[1] += d; want.layerAlt[1] += d
        want.ghost = start.ghost.map { $0 + d }; want.layerGhost = start.layerGhost.map { $0 + d }
        XCTAssertEqual(spans(s), want, "the swap moved every anchor once")
        XCTAssertEqual(s.session.anchoredText, s.r.controller.state.doc.units)

        // typing right after the swap, touching the swapped word, is its own undo step (FloCore
        // isolateHistory; without it the adjacent typing would join the swap's undo event)
        XCTAssertEqual(s.r.controller.state.selection.main.head, want.alt[1], "the caret follows the swap")
        s.r.press("t:Ok")
        XCTAssertTrue(s.r.doc.contains("holds a pushpinOk, a ruler"), s.r.doc)
        XCTAssertTrue(s.r.controller.handleKey("Mod-z"))
        XCTAssertTrue(s.r.doc.contains("holds a pushpin, a ruler"), "undo took only the typing back")
        XCTAssertFalse(s.r.doc.contains("Ok"))
        XCTAssertTrue(s.r.controller.handleKey("Mod-z"))
        XCTAssertEqual(s.r.doc, text, "the next undo takes the swap back")
        XCTAssertEqual(spans(s), start)
        XCTAssertEqual(s.alts.session.sets[0].currentId, s.alts.session.sets[0].originalId)
    }

    func testExternalReloadReanchorsOnceForAllFeatures() throws {
        let s = try open()
        let start = spans(s)
        let edited = "Intro line.\n" + text
        s.r.controller.load(edited, selection: .cursor(0))
        let d = "Intro line.\n".utf16.count
        XCTAssertEqual(spans(s), shifted(start, d))
        XCTAssertEqual(s.session.anchoredText, Array(edited.utf16))
    }
}
