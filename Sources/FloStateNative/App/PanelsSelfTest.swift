import AppKit
import FloCore
import FloKit

/// Flowriter: the side panels and the page column (`--ui-selftest panels <post> <out>`, VM
/// only; scripts/panels-vm-test.sh on Tests/fixtures/combined/pencil-case.md), in the writing
/// space's document window, animations on:
///   - in windows 1280, 1090 and 900 pt wide: open and close the Alternatives panel (left), the
///     Overflow panel (right) and both. A panel that fits its margin must not move a single line
///     (sampled every 16 ms while it slides); one that does not fit moves the column over once,
///     settled within 300 ms, never under a panel (text and hanging `#` marks clear of it); closing
///     puts every line back where it was
///   - typing with both panels open: no line other than the edited one moves (Integrity's jump
///     check) and the column stays put
///   - the count at the top keeps its centre gap when both counts gain a digit
///   - screenshots with both panels open: polish-<width>-<appearance>.png
@MainActor
enum PanelsScenario {
    typealias T = SelfTestRunner
    typealias Ctx = SelfTestRunner.Context
    static var appearance: String { ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "light" }
    static let tol: CGFloat = 0.5
    static let trace = ProcessInfo.processInfo.environment["FLO_PANELS_TRACE"] == "1"

    /// One visual line: x of its first and last visible character in pane points, y and height in
    /// text container points.
    struct Line: Equatable { var x0: CGFloat, x1: CGFloat, y: CGFloat, h: CGFloat }

    static func lines(_ ctx: Ctx) -> [Line] {
        let c = ctx.c, tv = c.textView
        guard let tlm = tv.textLayoutManager else { return [] }
        let o = tv.textContainerOrigin
        var out: [Line] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { f in
            let fr = f.layoutFragmentFrame
            for lf in f.textLineFragments {
                let str = lf.attributedString.string as NSString, r = lf.characterRange
                var i0: Int?, i1: Int?
                var i = r.location
                while i < NSMaxRange(r) && i < str.length { if !isBlank(str.character(at: i)) { i0 = i; break }; i += 1 }
                i = min(NSMaxRange(r), str.length) - 1
                while i >= r.location { if !isBlank(str.character(at: i)) { i1 = i; break }; i -= 1 }
                guard let a = i0, let b = i1 else { continue }
                let bx = fr.minX + lf.typographicBounds.minX + o.x
                let x0 = tv.convert(NSPoint(x: bx + lf.locationForCharacter(at: a).x, y: 0), to: ctx.pane).x
                let x1 = tv.convert(NSPoint(x: bx + lf.locationForCharacter(at: b + 1).x, y: 0), to: ctx.pane).x
                out.append(Line(x0: x0, x1: x1, y: fr.minY + lf.typographicBounds.minY, h: lf.typographicBounds.height))
            }
            return true
        }
        return out
    }
    static func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    static func worst(_ a: [Line], _ b: [Line]) -> CGFloat {
        guard a.count == b.count else { return .infinity }
        return zip(a, b).map { max(abs($0.x0 - $1.x0), abs($0.x1 - $1.x1), abs($0.y - $1.y), abs($0.h - $1.h)) }.max() ?? 0
    }

    /// Sample the page every 16 ms for `ms` after `body`: every distinct layout seen, the time the
    /// last change happened.
    static func watch(_ ctx: Ctx, ms: Int = 450, _ body: () -> Void) async -> (samples: [[Line]], settledMs: Int) {
        var samples = [lines(ctx)]
        let t0 = Date()
        body()
        var settled = 0
        for _ in 0..<(ms / 16) {
            await T.pause(0.016)
            let l = lines(ctx)
            if trace { T.log(String(format: "trace: inset %.1f reserve %.0f/%.0f sliding %@ x0 %.1f", ctx.c.textView.textContainerInset.width, ctx.c.sideReserve.left, ctx.c.sideReserve.right, ctx.c.isSliding ? "yes" : "no", l.map(\.x0).min() ?? -1)) }
            if worst(l, samples.last!) > tol { samples.append(l); settled = Int(Date().timeIntervalSince(t0) * 1000) }
        }
        return (samples, settled)
    }

    static func resize(_ ctx: Ctx, width: CGFloat) async {
        let w = ctx.wc.window!
        w.setFrame(NSRect(x: 30, y: 60, width: width, height: 900), display: true)
        ctx.wc.root.layoutSubtreeIfNeeded()
        await T.pause(0.5)   // the full layout after a width change runs on the next turns
        ctx.c.ensureFullLayout()
        await T.pause(0.1)
    }

    static func run(_ ctx: Ctx) async {
        AlternativesPanelView.animations = true
        OverflowController.animations = true
        UserDefaults.standard.removeObject(forKey: OverflowSidecarStore.openKey(ctx.file))
        await T.pause(0.6)
        let area = ctx.wc.root.area
        guard let l = await T.waitFor(3, { ctx.c.alternatives }), let ov = ctx.pane.overflow else { T.expect(false, "alternatives and overflow attached"); return }
        ov.setOpen(false, animated: false)
        let alt = AlternativesAttach.panel(area)
        let original = ctx.c.state.doc.string

        // content for the screenshots: versions of a word, a paragraph in the overflow panel
        let wr = (original as NSString).range(of: "thumbtack")
        guard l.addVersion("pushpin", level: .word, range: wr, show: false) != nil,
              l.addVersion("paperclip", author: .ai, level: .word, range: wr, show: false) != nil else { T.expect(false, "versions added"); return }
        ov.text = "I once tried to carry a whole notebook, but it never left the drawer."
        let withVersions = ctx.c.state.doc.string

        await countPinned(ctx)

        let widths = (ProcessInfo.processInfo.environment["FLO_PANELS_WIDTHS"] ?? "1280 1090 900").split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
        for width in widths {
            await resize(ctx, width: width)
            let c = ctx.c
            let span = c.centredTextSpan
            let paneW = ctx.pane.bounds.width
            let leftMargin = span.left - c.gutterWidth, rightMargin = paneW - span.right - EditorController.panelAir
            let altFits = leftMargin >= OverflowController.minPanelWidth
            let ovFits = max(rightMargin, paneW - span.right - EditorController.panelMinAir) >= OverflowController.minPanelWidth
            T.log(String(format: "window %.0f: text %.0f..%.0f (%.0f pt), gutter %.0f, left margin %.0f, right margin %.0f: alternatives %@, overflow %@",
                         width, span.left, span.right, span.right - span.left, c.gutterWidth, leftMargin, rightMargin,
                         altFits ? "fits" : "moves the column", ovFits ? "fits" : "moves the column"))
            let g0 = lines(ctx)
            T.expect(!g0.isEmpty, "\(Int(width)): lines measured (\(g0.count))")
            let w = Int(width)

            // Alternatives alone
            c.textView.setSelectedRange(NSRange(location: (c.state.doc.string as NSString).range(of: "thumbtack").location + 2, length: 0))
            let openAlt = await watch(ctx) { AlternativesAttach.toggle(area) }
            T.expect(alt.isOpen && alt.frame.minX == 0 && abs(alt.frame.width - alt.panelWidth(in: area)) < tol && alt.frame.height == area.bounds.height,
                     String(format: "%d: Alternatives floats over the left margin (x %.0f, %.0f pt wide, %.0f high)", w, alt.frame.minX, alt.frame.width, alt.frame.height))
            T.expect(alt.frame.width >= OverflowController.minPanelWidth - tol && (altFits ? alt.frame.width <= leftMargin + tol : true),
                     String(format: "%d: Alternatives is as wide as the margin, 220 pt at least (%.0f, margin %.0f)", w, alt.frame.width, leftMargin))
            alt.display()
            if let last = alt.tabRects.last?.1 {
                let side = AlternativesPanelView.pad
                T.expect(last.maxX - 6 <= alt.bounds.width - side + tol, String(format: "%d: the tabs keep %.0f pt from the panel's edge (last tab ends at %.1f of %.0f)", w, side, last.maxX - 6, alt.bounds.width))
                if let first = alt.tabRects.first?.1 { T.expect(abs(first.minX + 6 - side) < tol, String(format: "%d: the first tab starts %.0f pt from the edge (%.1f)", w, side, first.minX + 6)) }
                AlternativesScenarios.expectPlainList(alt, "\(w)")
            }
            expectMove(ctx, "\(w): opening Alternatives", openAlt, from: g0, fits: altFits)
            expectClear(ctx, "\(w): Alternatives open", left: alt.frame.maxX, right: nil)
            if trace {
                T.screenshot(ctx, "trace-\(w)-alt.png")
                let tv = c.textView
                T.log(String(format: "trace views: tv frame %@ bounds %@ minSize %@ maxSize %@ clip %@ content %@ scroll %@ pane %@ inset %.1f origin %.1f",
                             NSStringFromRect(tv.frame), NSStringFromRect(tv.bounds), NSStringFromSize(tv.minSize), NSStringFromSize(tv.maxSize),
                             NSStringFromRect(c.scrollView.contentView.bounds), NSStringFromSize(c.scrollView.contentSize), NSStringFromRect(c.scrollView.frame),
                             NSStringFromRect(ctx.pane.frame), tv.textContainerInset.width, tv.textContainerOrigin.x))
            }
            let closeAlt = await watch(ctx) { AlternativesAttach.toggle(area) }
            T.expect(!alt.isOpen, "\(w): Alternatives closed")
            expectBack(ctx, "\(w): closing Alternatives", closeAlt, to: g0, fits: altFits)

            // Overflow alone
            let openOv = await watch(ctx) { ov.setOpen(true) }
            T.expect(ov.isOpen && abs(ov.panel.frame.maxX - paneW) < tol, String(format: "%d: Overflow floats over the right margin (%.0f pt wide)", w, ov.panel.frame.width))
            expectMove(ctx, "\(w): opening Overflow", openOv, from: g0, fits: ovFits)
            expectClear(ctx, "\(w): Overflow open", left: nil, right: ov.panel.frame.minX)
            let closeOv = await watch(ctx) { ov.setOpen(false) }
            expectBack(ctx, "\(w): closing Overflow", closeOv, to: g0, fits: ovFits)

            // both, typing with both open, the screenshot
            let openA = await watch(ctx) { AlternativesAttach.toggle(area) }
            let openB = await watch(ctx) { ov.setOpen(true) }
            expectMove(ctx, "\(w): opening Alternatives, then Overflow", (openA.samples + openB.samples.dropFirst(), max(openA.settledMs, openB.settledMs)),
                       from: g0, fits: altFits && ovFits)
            expectClear(ctx, "\(w): both panels open", left: alt.frame.maxX, right: ov.panel.frame.minX)
            let gBoth = lines(ctx), originBoth = c.textView.textContainerOrigin.x
            ctx.wc.window!.makeFirstResponder(c.textView)
            c.textView.setSelectedRange(NSRange(location: NSMaxRange((c.state.doc.string as NSString).range(of: "The last line stays where it is.")), length: 0))
            let before = c.state.doc.string
            Integrity.jumps = []
            await Integrity.act(ctx, "\(w): type with both panels open", .edit, " and the column holds still while I type".map { ch in { Integrity.key(ctx, String(ch), code: ch == " " ? 49 : 0) } })
            await Integrity.act(ctx, "\(w): Return with both panels open", .edit, [{ Integrity.key(ctx, "\r", code: 36) }] + "More".map { ch in { Integrity.key(ctx, String(ch)) } })
            let jumps = Integrity.jumps.filter(\.visible)
            T.expect(jumps.isEmpty, "\(w): typing with both panels open moves no other line (\(jumps.count) jumps\(jumps.first.map { ": \($0.what) dx \($0.dx) dy \($0.dy)" } ?? ""))")
            T.expect(abs(c.textView.textContainerOrigin.x - originBoth) < tol, "\(w): the column stays put while typing")
            expectClear(ctx, "\(w): after typing", left: alt.frame.maxX, right: ov.panel.frame.minX)
            await Integrity.act(ctx, "\(w): undo typing", .edit, Integrity.undoUntil(ctx, before, max: 20))
            T.expect(c.state.doc.string == before && worst(lines(ctx), gBoth) <= tol, "\(w): undo puts the page back")
            if width != 1280 {
                c.textView.setSelectedRange(NSRange(location: (c.state.doc.string as NSString).range(of: "thumbtack").location + 2, length: 0))
                c.scrollView.contentView.scroll(to: .zero); c.scrollView.reflectScrolledClipView(c.scrollView.contentView)   // the page from its top
                alt.refresh()
                await T.pause(0.3)
                T.screenshot(ctx, "polish-\(w)-\(appearance).png")
            }
            let closeA = await watch(ctx) { AlternativesAttach.toggle(area) }
            let closeB = await watch(ctx) { ov.setOpen(false) }
            expectBack(ctx, "\(w): closing both", (closeA.samples + closeB.samples.dropFirst(), max(closeA.settledMs, closeB.settledMs)), to: g0, fits: altFits && ovFits)
        }
        T.expect(ctx.c.state.doc.string == withVersions, "the page text is unchanged by the panels")
    }

    /// Opening: a panel that fits moves nothing; one that does not moves the column once, settled in 300 ms.
    static func expectMove(_ ctx: Ctx, _ what: String, _ w: (samples: [[Line]], settledMs: Int), from g0: [Line], fits: Bool) {
        let final = w.samples.last!
        if fits {
            T.expect(w.samples.count == 1, String(format: "%@: no line moved (%d layouts seen, worst %.1f pt)", what, w.samples.count, worst(final, g0)))
        } else {
            T.expect(w.settledMs <= 300, "\(what): the column moved over and settled in \(w.settledMs) ms")
            T.log(String(format: "%@: column moved %.0f pt over %d frames (text %.0f..%.0f)", what, (final.first?.x0 ?? 0) - (g0.first?.x0 ?? 0),
                         w.samples.count - 1, final.map(\.x0).min() ?? 0, final.map(\.x1).max() ?? 0))
        }
    }

    /// Closing: every line back where it was before the panel opened.
    static func expectBack(_ ctx: Ctx, _ what: String, _ w: (samples: [[Line]], settledMs: Int), to g0: [Line], fits: Bool) {
        let final = w.samples.last!
        T.expect(worst(final, g0) <= tol, String(format: "%@: every line is back where it was (worst %.1f pt)", what, worst(final, g0)))
        if fits { T.expect(w.samples.count == 1, "\(what): no line moved (\(w.samples.count) layouts seen)") }
        else { T.expect(w.settledMs <= 300, "\(what): settled in \(w.settledMs) ms") }
    }

    /// No text or hanging mark under a panel: 8 pt of air at least.
    static func expectClear(_ ctx: Ctx, _ what: String, left: CGFloat?, right: CGFloat?) {
        let ls = lines(ctx)
        let lo = ls.map(\.x0).min() ?? 0, hi = ls.map(\.x1).max() ?? 0
        var ok = true
        var s = String(format: "text and marks span %.0f..%.0f", lo, hi)
        if let l = left { ok = ok && lo >= l + 8; s += String(format: ", left panel ends at %.0f", l) }
        if let r = right { ok = ok && hi <= r - 8; s += String(format: ", right panel starts at %.0f", r) }
        T.expect(ok, "\(what): no text under a panel (\(s))")
    }

    // MARK: the count

    /// Type until both counts gain a digit (68 -> 100+ words, 330 -> 1,000+ chars): the gap between
    /// them stays on the window's centre line, so "words" and the chars number do not move.
    static func countPinned(_ ctx: Ctx) async {
        let count = ctx.wc.root.flowriterCount
        let c = ctx.c
        let before = c.state.doc.string
        func edges() -> (String, CGFloat, CGFloat) {
            count.refresh()
            let o = count.origins
            return (count.text, o.words + count.style.width(count.words), o.chars)
        }
        let (t0, wordsEnd0, chars0) = edges()
        ctx.wc.window!.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(NSRange(location: NSMaxRange((before as NSString).range(of: "The last line stays where it is.")), length: 0))
        for _ in 0..<70 { T.type(ctx, " abcdefghi") }
        ctx.model.flushDirtyFiles()
        let t1 = await T.waitFor(3) { () -> (String, CGFloat, CGFloat)? in let e = edges(); return e.0 != t0 ? e : nil }
        if let (t, wordsEnd, chars) = t1 {
            T.expect(abs(wordsEnd - wordsEnd0) < tol && abs(chars - chars0) < tol,
                     String(format: "count \"%@\" -> \"%@\": \"words\" ends at %.1f -> %.1f, the chars count starts at %.1f -> %.1f", t0, t, wordsEnd0, wordsEnd, chars0, chars))
            let mid = count.bounds.width / 2, half = count.style.width(FlowriterCountView.gap) / 2
            T.expect(abs((wordsEnd + chars) / 2 - mid) <= 1, String(format: "the gap sits on the centre line (%.1f vs %.1f, gap %.1f)", (wordsEnd + chars) / 2, mid, 2 * half))
        } else { T.expect(false, "the count followed the typing (\(count.text))") }
        for _ in 0..<200 where c.state.doc.string != before { T.undo(ctx) }
        T.expect(c.state.doc.string == before, "undo took the typing out")
        ctx.model.flushDirtyFiles()
    }
}
