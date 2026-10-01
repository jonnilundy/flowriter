import AppKit
import FloCore
import FloKit

/// Flowriter: UI integrity suite (`--ui-selftest integrity <post> <outDir>`, VM only).
///
/// Drives the real window in process (key and mouse events through the window, like typing) over a
/// real post and measures layout after every step: for each line fragment outside the edited lines,
/// its origin, height and the x of its first and last letter; the scroll origin (apart from caret
/// follow); and after caret moves, the caret against where the target position was drawn before the
/// move. It also samples the layout every 16 ms for 200 ms after each action to catch changes that
/// settle (flicker, reflow). Any change the edit did not cause is a "jump", printed as
///   jump <action> line <n>.<sub> dx <dx> dy <dy> <what>
/// and counted per action in the `integrity:` summary lines.
@MainActor
enum Integrity {
    typealias T = SelfTestRunner

    struct LineGeo: Equatable {
        var y: CGFloat, h: CGFloat, x0: CGFloat, x1: CGFloat
    }

    struct Snap {
        var paras: [Int: [LineGeo]] = [:]   // 0-based doc line -> its line fragments
        var lines: [String] = []
        var clipY: CGFloat = 0
        var clipH: CGFloat = 0
        var caret: CGRect?
        var head = 0
    }

    struct Jump {
        var action: String
        var line: Int, sub: Int
        var dx: CGFloat, dy: CGFloat
        var what: String
        var transient: Bool
        var visible: Bool
    }

    static var jumps: [Jump] = []
    static let trace = Int(ProcessInfo.processInfo.environment["FLO_INTEGRITY_TRACE"] ?? "")
    static var actions: [String] = []
    static let tol: CGFloat = 0.5

    // MARK: measuring

    static func isLetter(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c > 0xBF
    }

    /// The layout as it is now (no layout forced: what the last display pass drew).
    static var snapMs: Double = 0, snapN = 0
    static func snap(_ ctx: T.Context) -> Snap {
        let st = CFAbsoluteTimeGetCurrent(); defer { snapMs += (CFAbsoluteTimeGetCurrent() - st) * 1000; snapN += 1 }
        let c = ctx.c
        var s = Snap()
        guard let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager else { return s }
        let doc = c.state.doc
        s.lines = doc.string.components(separatedBy: "\n")
        let start = tcm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: start, options: []) { f in
            let off = tcm.offset(from: start, to: f.rangeInElement.location)
            guard off >= 0, off <= doc.length else { return true }
            let idx = doc.lineAt(off).number - 1
            let fr = f.layoutFragmentFrame
            var geo: [LineGeo] = []
            for lf in f.textLineFragments {
                // the empty line after a final newline rides in the last paragraph's fragment as an
                // extra line: it belongs to the next doc line, not to this one (no rewrap)
                if lf.characterRange.length == 0 && !geo.isEmpty { continue }
                let b = lf.typographicBounds
                let str = lf.attributedString.string as NSString
                let r = lf.characterRange
                var i0: Int?, i1: Int?
                var i = r.location
                while i < NSMaxRange(r) && i < str.length { if isLetter(str.character(at: i)) { i0 = i; break }; i += 1 }
                i = min(NSMaxRange(r), str.length) - 1
                while i >= r.location { if isLetter(str.character(at: i)) { i1 = i; break }; i -= 1 }
                let x0 = i0.map { fr.minX + b.minX + lf.locationForCharacter(at: $0).x } ?? -1
                let x1 = i1.map { fr.minX + b.minX + lf.locationForCharacter(at: $0).x } ?? -1
                geo.append(LineGeo(y: fr.minY + b.minY, h: b.height, x0: x0, x1: x1))
            }
            if geo.isEmpty { geo = [LineGeo(y: fr.minY, h: fr.height, x0: -1, x1: -1)] }
            s.paras[idx] = geo
            return true
        }
        let clip = c.scrollView.contentView.bounds
        s.clipY = clip.minY - c.textView.textContainerOrigin.y; s.clipH = clip.height   // container coordinates, like the lines
        s.head = c.state.selection.main.head
        s.caret = caretRect(ctx, s.head)
        return s
    }

    /// Caret rect for a position in text container coordinates, from the current layout.
    static func caretRect(_ ctx: T.Context, _ pos: Int) -> CGRect? {
        guard let tlm = ctx.c.textView.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: max(0, min(pos, ctx.c.state.doc.length))) else { return nil }
        var rect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, r, _, _ in
            rect = r; return false
        }
        return rect
    }

    /// Caret rects before a move, for every position on the caret's line and `span` lines around it.
    static func caretRects(_ ctx: T.Context, span: Int) -> [Int: CGRect] {
        let doc = ctx.c.state.doc
        let n = doc.lineAt(ctx.c.state.selection.main.head).number
        var out: [Int: CGRect] = [:]
        for l in max(1, n - span)...min(doc.lines, n + span) {
            let line = doc.line(l)
            for p in line.from...line.to { out[p] = caretRect(ctx, p) }
        }
        return out
    }

    /// Changes from `a` to `b` that the edit (the lines whose text changed) did not cause.
    static func compare(_ a: Snap, _ b: Snap, action: String, scroll: Bool, transient: Bool) -> [Jump] {
        var out: [Jump] = []
        var prefix = 0
        while prefix < a.lines.count, prefix < b.lines.count, a.lines[prefix] == b.lines[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.lines.count - prefix, suffix < b.lines.count - prefix,
              a.lines[a.lines.count - 1 - suffix] == b.lines[b.lines.count - 1 - suffix] { suffix += 1 }
        let edited = prefix < a.lines.count || prefix < b.lines.count ? prefix..<(b.lines.count - suffix) : 0..<0
        // lines after the edit move with it: compare them relative to the first unchanged line after it
        var pairs: [(Int, Int)] = (0..<prefix).map { ($0, $0) }
        let firstSuffixOld = a.lines.count - suffix, firstSuffixNew = b.lines.count - suffix
        var shift: CGFloat = 0
        if suffix > 0, edited.count > 0 || a.lines.count != b.lines.count,
           let ya = a.paras[firstSuffixOld]?.first?.y, let yb = b.paras[firstSuffixNew]?.first?.y {
            shift = yb - ya
        }
        let editTouched = edited.count > 0 || a.lines.count != b.lines.count
        for k in 0..<suffix where editTouched { pairs.append((firstSuffixOld + k, firstSuffixNew + k)) }
        let top = b.clipY, bottom = b.clipY + b.clipH
        var carried: CGFloat = 0   // dy inherited from the line above (a height change pushes the rest down)
        var lastPair = -1
        for (oi, ni) in pairs {
            guard let la = a.paras[oi], let lb = b.paras[ni] else { continue }
            let base = oi >= firstSuffixOld && editTouched ? shift : 0
            if oi != lastPair + 1 { carried = 0 }
            lastPair = oi
            let vis = (lb.first?.y ?? 0) < bottom + 50 && (lb.last.map { $0.y + $0.h } ?? 0) > top - 50
            if la.count != lb.count {
                out.append(Jump(action: action, line: ni + 1, sub: 0, dx: 0, dy: (lb.last!.y + lb.last!.h) - (la.last!.y + la.last!.h) - base,
                                what: "rewrap \(la.count)->\(lb.count) lines", transient: transient, visible: vis))
                carried += (lb.last!.y + lb.last!.h) - (la.last!.y + la.last!.h) - base - carried
                continue
            }
            for (j, (ga, gb)) in zip(la, lb).enumerated() {
                let dy = gb.y - ga.y - base
                let dh = gb.h - ga.h
                let dx0 = ga.x0 >= 0 && gb.x0 >= 0 ? gb.x0 - ga.x0 : 0
                let dx1 = ga.x1 >= 0 && gb.x1 >= 0 ? gb.x1 - ga.x1 : 0
                var what: [String] = []
                if abs(dy - carried) > tol { what.append(String(format: "moved %.1f", dy - carried)) }
                if abs(dh) > tol { what.append(String(format: "height %.1f->%.1f", ga.h, gb.h)) }
                if abs(dx0) > tol || abs(dx1) > tol { what.append(String(format: "x first %.1f last %.1f", dx0, dx1)) }
                if !what.isEmpty {
                    out.append(Jump(action: action, line: ni + 1, sub: j, dx: abs(dx0) > abs(dx1) ? dx0 : dx1, dy: abs(dh) > tol ? dh : dy - carried,
                                    what: what.joined(separator: ", "), transient: transient, visible: vis))
                }
                carried = dy + dh
            }
        }
        _ = edited
        // scroll: only allowed when asked for, or to bring the caret into view
        if !scroll, abs(b.clipY - a.clipY) > tol {
            let dy = b.clipY - a.clipY
            if let caret = b.caret {
                // how far the caret was outside the old view: the most a caret follow needs to scroll.
                // Caret follow keeps 6 pt of air around the caret (FloTextView.rectForScroll), so a caret
                // within 6 pt of the edge is not yet "in view" for it.
                let r = caret.insetBy(dx: 0, dy: -6)
                let need = r.maxY > a.clipY + a.clipH ? r.maxY - (a.clipY + a.clipH) : r.minY < a.clipY ? a.clipY - r.minY : 0
                let slack: CGFloat = 48
                if need == 0 || abs(dy) > need + slack {
                    out.append(Jump(action: action, line: 0, sub: 0, dx: 0, dy: dy,
                                    what: String(format: need == 0 ? "scroll (caret was already in view: caret y %.0f, view %.0f-%.0f)" : "scroll further than the caret needs (caret y %.0f, view %.0f-%.0f)",
                                                 r.minY, a.clipY, a.clipY + a.clipH), transient: transient, visible: true))
                }
            }
        }
        return out
    }

    static func record(_ js: [Jump]) {
        for j in js {
            jumps.append(j)
            T.log(String(format: "jump %@ line %d.%d dx %.1f dy %.1f %@%@%@", j.action, j.line, j.sub, j.dx, j.dy, j.what,
                         j.transient ? " [transient]" : "", j.visible ? "" : " [offscreen]"))
        }
    }

    // MARK: events

    /// A real key event, handed to the text view (as the window does for its first responder). Not
    /// through NSWindow.sendEvent: with several runs side by side only one app is active, and an
    /// inactive app's window can drop key events.
    static func key(_ ctx: T.Context, _ chars: String, code: UInt16 = 0, mods: NSEvent.ModifierFlags = []) {
        let w = ctx.wc.window!, tv = ctx.c.textView
        if w.firstResponder !== tv { w.makeFirstResponder(tv) }
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: code)!
        if mods.contains(.command) { if !tv.performKeyEquivalent(with: e) { T.log("unhandled key equivalent \(chars)") } } else { tv.keyDown(with: e) }
    }
    static func backspace(_ ctx: T.Context) { key(ctx, "\u{7f}", code: 51) }
    static func undo(_ ctx: T.Context) { key(ctx, "z", code: 6, mods: [.command]) }
    static let arrows: [String: (String, UInt16)] = [
        "Up": ("\u{F700}", 126), "Down": ("\u{F701}", 125), "Left": ("\u{F702}", 123), "Right": ("\u{F703}", 124),
    ]
    static func arrow(_ ctx: T.Context, _ name: String) {
        let (ch, code) = arrows[name]!
        key(ctx, ch, code: code, mods: [.numericPad, .function])
    }

    enum Kind { case edit, move, scroll }

    /// One action: its steps run one after another with a frame between them; each step is compared
    /// with the layout before it, then the layout is sampled for 200 ms and compared with where it settles.
    static func act(_ ctx: T.Context, _ name: String, _ kind: Kind = .edit, _ steps: [() -> Void]) async {
        actions.append(name)
        var prev = snap(ctx)
        for (i, step) in steps.enumerated() {
            let label = steps.count > 1 ? "\(name) step \(i + 1)" : name
            let pre = kind == .move ? caretRects(ctx, span: 2) : [:]
            // the first key on an empty line: the typed text must sit where the caret was drawn
            let doc0 = ctx.c.state.doc, line0 = doc0.lineAt(prev.head)
            let emptyCaret = kind == .edit && line0.from == line0.to ? prev.caret : nil
            step()
            await T.pause(0.02)
            let s = snap(ctx)
            record(compare(prev, s, action: label, scroll: kind == .scroll, transient: false))
            let doc1 = ctx.c.state.doc, line1 = doc1.lineAt(s.head)
            // (a typed `#` too: a line of only marks is plain text until a character follows them)
            if let a = emptyCaret, let b = s.caret, doc1.lines == doc0.lines, line1.number == line0.number, line1.to > line1.from,
               abs(b.minY - a.minY) > tol || abs(b.height - a.height) > tol {
                record([Jump(action: label, line: line1.number, sub: 0, dx: 0, dy: abs(b.height - a.height) > tol ? b.height - a.height : b.minY - a.minY,
                             what: String(format: "first key on an empty line: caret y %.1f h %.1f -> y %.1f h %.1f", a.minY, a.height, b.minY, b.height),
                             transient: false, visible: true)])
            }
            if kind == .move, let want = pre[s.head], let got = s.caret, abs(got.minX - want.minX) > tol || abs(got.minY - want.minY) > tol {
                let line = ctx.c.state.doc.lineAt(s.head).number
                record([Jump(action: label, line: line, sub: 0, dx: got.minX - want.minX, dy: got.minY - want.minY,
                             what: "caret not where the target was drawn", transient: false, visible: true)])
            }
            if let tl = trace {
                let g = s.paras[tl - 1].map { $0.map { String(format: "(y %.1f h %.1f x %.1f-%.1f)", $0.y, $0.h, $0.x0, $0.x1) }.joined() } ?? "-"
                T.log("trace \(label): head \(s.head) line \(ctx.c.state.doc.lineAt(s.head).number) L\(tl) \(g) text \(s.lines[tl - 1].prefix(50))")
            }
            prev = s
        }
        // settle: sample for 200 ms; anything that differs from the final layout was on screen for a moment
        var samples = [prev]
        for _ in 0..<12 { await T.pause(0.016); samples.append(snap(ctx)) }
        let final = samples.last!
        var seen = Set<String>()
        for s in samples.dropLast() {
            for j in compare(s, final, action: name, scroll: kind == .scroll, transient: true) where !seen.contains("\(j.line).\(j.sub).\(j.what)") {
                seen.insert("\(j.line).\(j.sub).\(j.what)")
                record([j])
            }
            if let a = s.caret, let b = final.caret, s.head == final.head, abs(a.minX - b.minX) > tol || abs(a.minY - b.minY) > tol, !seen.contains("caret") {
                seen.insert("caret")
                record([Jump(action: name, line: ctx.c.state.doc.lineAt(final.head).number, sub: 0, dx: b.minX - a.minX, dy: b.minY - a.minY,
                             what: "caret settled", transient: true, visible: true)])
            }
        }
    }

    /// Setup (not measured): put the caret or selection somewhere and let it settle.
    static func setup(_ ctx: T.Context, _ range: NSRange, scroll: Bool = true) async {
        ctx.c.textView.setSelectedRange(range)
        if scroll { ctx.c.textView.scrollRangeToVisible(range) }
        await T.pause(0.12)
    }

    // MARK: the script

    static func text(_ ctx: T.Context) -> NSString { ctx.c.state.doc.string as NSString }

    /// Plain prose paragraphs (doc lines), longest first is not needed: in document order.
    static func proseLines(_ ctx: T.Context) -> [Int] {
        let doc = ctx.c.state.doc
        var out: [Int] = []
        var inFront = doc.lines > 0 && doc.line(1).text == "---"
        for n in 1...doc.lines {
            let t = doc.line(n).text
            if n > 1, inFront, t == "---" { inFront = false; continue }
            if inFront { continue }
            let first = t.first
            if t.count < 60 || first == "#" || first == ">" || first == "-" || first == "*" || first == "|" || first == " " || (first?.isNumber ?? false) { continue }
            if t.contains("**") || t.contains("](") || t.contains("`") { continue }
            out.append(n)
        }
        return out
    }

    static func lineRange(_ ctx: T.Context, _ n: Int) -> NSRange {
        let l = ctx.c.state.doc.line(n)
        return NSRange(location: l.from, length: l.to - l.from)
    }

    /// Range of the `k`-th word (letters only, 4+ chars) on line `n`.
    static func word(_ ctx: T.Context, _ n: Int, _ k: Int) -> NSRange {
        let r = lineRange(ctx, n)
        let s = text(ctx).substring(with: r) as NSString
        let re = try! NSRegularExpression(pattern: "\\b[A-Za-z]{4,}\\b")
        let ms = re.matches(in: s as String, range: NSRange(location: 0, length: s.length))
        let m = ms[min(k, ms.count - 1)].range
        return NSRange(location: r.location + m.location, length: m.length)
    }

    /// Arrow steps until the caret is off doc line `n` (no-ops once it is).
    static func leave(_ ctx: T.Context, _ n: Int, down: Bool) -> [() -> Void] {
        (0..<5).map { _ in { if ctx.c.state.doc.lineAt(ctx.c.state.selection.main.head).number == n { arrow(ctx, down ? "Down" : "Up") } } }
    }
    /// Arrow steps until the caret is on doc line `n`.
    static func enter(_ ctx: T.Context, _ n: Int, down: Bool) -> [() -> Void] {
        (0..<5).map { _ in { if ctx.c.state.doc.lineAt(ctx.c.state.selection.main.head).number != n { arrow(ctx, down ? "Down" : "Up") } } }
    }

    static func undoUntil(_ ctx: T.Context, _ doc: String, max: Int = 12) -> [() -> Void] {
        (0..<max).map { _ in { if ctx.c.state.doc.string != doc { undo(ctx) } } }
    }

    static func run(_ ctx: T.Context) async {
        let t0 = Date()
        let c = ctx.c
        ctx.wc.window!.displayIfNeeded()
        await T.pause(0.4)
        let prose = proseLines(ctx)
        guard prose.count >= 3 else { T.expect(false, "post has 3 prose paragraphs (\(prose.count))"); return }
        let p1 = prose[0], p2 = prose[1], p3 = prose[2]
        T.log("prose lines \(p1), \(p2), \(p3) of \(c.state.doc.lines)")
        let original = c.state.doc.string

        // 0. a plain text editor: no system text sitting after the caret, no rewrites while typing
        let tv = c.textView
        T.expect(tv.inlinePredictionType == .no, "inline predictions off (type \(tv.inlinePredictionType.rawValue))")
        if #available(macOS 15.0, *) { T.expect(tv.mathExpressionCompletionType == .no, "math completion off (type \(tv.mathExpressionCompletionType.rawValue))") }
        T.expect(!tv.isAutomaticTextReplacementEnabled, "text replacement off")
        T.expect(!tv.isAutomaticSpellingCorrectionEnabled && !tv.isAutomaticQuoteSubstitutionEnabled && !tv.isAutomaticDashSubstitutionEnabled,
                 "autocorrect, smart quotes and smart dashes off")
        T.expect(tv.isContinuousSpellCheckingEnabled, "spelling underlines on")
        WritingMenuScenarios.expectNoWritingTools(ctx)

        // 1. click into a paragraph, then type prose at the end of its first sentence
        await setup(ctx, NSRange(location: lineRange(ctx, p1).location, length: 0))
        let r1 = lineRange(ctx, p1)
        if let target = c.rect(forPosition: r1.location + r1.length / 2, in: c.textView) {
            await act(ctx, "click", .move, [{ T.click(ctx, at: NSPoint(x: target.midX, y: target.midY), in: c.textView) }])
        }
        let sentenceEnd = text(ctx).range(of: ". ", options: [], range: lineRange(ctx, p1))
        await setup(ctx, NSRange(location: sentenceEnd.location != NSNotFound ? sentenceEnd.location + 1 : NSMaxRange(lineRange(ctx, p1)), length: 0))
        await act(ctx, "type prose", .edit, Array(" And the quick brown fox keeps writing".map { ch in { key(ctx, String(ch), code: ch == " " ? 49 : 0) } }))
        // 2. Return in the middle, type, then join again
        await act(ctx, "return", .edit, [{ key(ctx, "\r", code: 36) }])
        await act(ctx, "type on new line", .edit, Array("New line".map { ch in { key(ctx, String(ch), code: ch == " " ? 49 : 0) } }))
        await act(ctx, "backspace join", .edit, Array(repeating: { backspace(ctx) }, count: 9))
        // 3. undo / redo
        await act(ctx, "undo", .edit, [{ undo(ctx) }])
        await act(ctx, "redo", .edit, [{ key(ctx, "z", code: 6, mods: [.command, .shift]) }])
        await act(ctx, "undo all", .edit, undoUntil(ctx, original, max: 8))
        // 4. caret moves across lines and paragraphs
        await setup(ctx, NSRange(location: lineRange(ctx, p2).location, length: 0))
        await act(ctx, "arrow up", .move, Array(repeating: { arrow(ctx, "Up") }, count: 4))
        await act(ctx, "arrow down", .move, Array(repeating: { arrow(ctx, "Down") }, count: 8))
        await setup(ctx, NSRange(location: lineRange(ctx, p2).location + 2, length: 0))
        await act(ctx, "arrow left", .move, Array(repeating: { arrow(ctx, "Left") }, count: 5))
        await act(ctx, "arrow right", .move, Array(repeating: { arrow(ctx, "Right") }, count: 5))
        // 5. inline formatting on a word, then the caret leaves the line and comes back
        for (name, k, code) in [("bold", "b", UInt16(11)), ("italic", "i", UInt16(34)), ("inline code", "e", UInt16(14))] {
            let before = c.state.doc.string
            await setup(ctx, word(ctx, p2, 2))
            await act(ctx, "add \(name)", .edit, [{ key(ctx, k, code: code, mods: [.command]) }])
            await act(ctx, "leave \(name) line", .move, leave(ctx, p2, down: true))
            await act(ctx, "enter \(name) line", .move, enter(ctx, p2, down: false))
            await setup(ctx, word(ctx, p2, 2), scroll: false)
            await act(ctx, "remove \(name)", .edit, undoUntil(ctx, before, max: 3))
        }
        // typed marks
        let beforeTyped = c.state.doc.string
        await setup(ctx, NSRange(location: NSMaxRange(lineRange(ctx, p3)), length: 0))
        await act(ctx, "type bold marks", .edit, Array(" **bold** and *soft*".map { ch in { key(ctx, String(ch), code: ch == " " ? 49 : 0) } }))
        await act(ctx, "leave typed marks", .move, leave(ctx, p3, down: false))
        await act(ctx, "enter typed marks", .move, enter(ctx, p3, down: true))
        await act(ctx, "remove typed marks", .edit, undoUntil(ctx, beforeTyped, max: 30))
        // 6. link
        let beforeLink = c.state.doc.string
        await setup(ctx, word(ctx, p2, 4))
        await act(ctx, "add link", .edit, [{ key(ctx, "k", code: 40, mods: [.command]) }])
        await act(ctx, "type url", .edit, Array("https://example.com".map { ch in { key(ctx, String(ch)) } }))
        await act(ctx, "leave link line", .move, leave(ctx, p2, down: true))
        await act(ctx, "enter link line", .move, enter(ctx, p2, down: false))
        await act(ctx, "remove link", .edit, undoUntil(ctx, beforeLink, max: 25))
        // 7. block prefixes at the start of a paragraph: headings, list, quote
        for (name, prefix) in [("heading #", "# "), ("heading ##", "## "), ("list marker", "- "), ("blockquote", "> ")] {
            let before = c.state.doc.string
            await setup(ctx, NSRange(location: lineRange(ctx, p2).location, length: 0))
            await act(ctx, "add \(name)", .edit, Array(prefix.map { ch in { key(ctx, String(ch), code: ch == " " ? 49 : 0) } }))
            await act(ctx, "leave \(name) line", .move, leave(ctx, p2, down: true))
            await act(ctx, "enter \(name) line", .move, enter(ctx, p2, down: false))
            await setup(ctx, NSRange(location: lineRange(ctx, p2).location + prefix.utf16.count, length: 0), scroll: false)
            await act(ctx, "remove \(name)", .edit, Array(repeating: { backspace(ctx) }, count: prefix.count))
            if c.state.doc.string != before { await act(ctx, "remove \(name) (undo)", .edit, undoUntil(ctx, before, max: 6)) }
        }
        // 8. paste a paragraph after p1, then undo
        let beforePaste = c.state.doc.string
        await setup(ctx, NSRange(location: NSMaxRange(lineRange(ctx, p1)), length: 0))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("\n\nA pasted paragraph with **some bold**, a [link](https://example.com) and enough words to wrap across more than one visual line in the column.", forType: .string)
        await act(ctx, "paste paragraph", .edit, [{ c.textView.paste(nil) }])
        let pastedLine = ctx.c.state.doc.lineAt(ctx.c.state.selection.main.head).number
        await act(ctx, "leave pasted", .move, leave(ctx, pastedLine, down: true))
        await act(ctx, "undo paste", .edit, undoUntil(ctx, beforePaste, max: 4))
        // 9. scroll down and back
        let clip = c.scrollView.contentView
        let y0 = clip.bounds.minY
        await act(ctx, "scroll", .scroll, [
            { clip.scroll(to: NSPoint(x: 0, y: y0 + 300)); c.scrollView.reflectScrolledClipView(clip) },
            { clip.scroll(to: NSPoint(x: 0, y: y0 + 600)); c.scrollView.reflectScrolledClipView(clip) },
            { clip.scroll(to: NSPoint(x: 0, y: max(0, y0 - 200))); c.scrollView.reflectScrolledClipView(clip) },
            { clip.scroll(to: NSPoint(x: 0, y: y0)); c.scrollView.reflectScrolledClipView(clip) },
        ])
        // 10. type at the bottom edge of the window: wrap to a new visual line, Return twice, type
        let beforeBottom = c.state.doc.string
        await setup(ctx, NSRange(location: NSMaxRange(lineRange(ctx, p3)), length: 0))
        if let r = caretRect(ctx, c.state.selection.main.head) {
            clip.scroll(to: NSPoint(x: 0, y: max(0, r.maxY + c.textView.textContainerOrigin.y - clip.bounds.height + 6)))
            c.scrollView.reflectScrolledClipView(clip)
            await T.pause(0.1)
        }
        await act(ctx, "type at bottom edge", .edit, Array(" and it keeps going past the edge of the window so the line has to wrap onto a new one".map { ch in { key(ctx, String(ch), code: ch == " " ? 49 : 0) } }))
        await act(ctx, "return at bottom edge", .edit, [{ key(ctx, "\r", code: 36) }, { key(ctx, "\r", code: 36) }] + Array("More".map { ch in { key(ctx, String(ch)) } }))
        await act(ctx, "undo bottom edge", .edit, undoUntil(ctx, beforeBottom, max: 12))
        await braindump(ctx)
        await T.pause(0.2)
        T.screenshot(ctx, "integrity\(RenderPlanner.readingView ? "-reading" : "")-\(((ctx.file as NSString).lastPathComponent as NSString).deletingPathExtension)-\(ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "system").png")
        T.expect(c.state.doc.string == original, "the post is back to its original text after the script")

        // summary
        let real = jumps.filter { $0.visible }
        var byAction: [String: (Int, Int)] = [:]
        for j in real { let k = j.action.components(separatedBy: " step ").first!; byAction[k, default: (0, 0)].0 += j.transient ? 0 : 1; byAction[k, default: (0, 0)].1 += j.transient ? 1 : 0 }
        for a in actions where byAction[a] != nil { T.log("integrity: action \"\(a)\" jumps \(byAction[a]!.0) transient \(byAction[a]!.1)") }
        T.log(String(format: "integrity: %d snapshots, %.2f ms each", snapN, snapMs / Double(max(1, snapN))))
        T.log("integrity: \(real.count) jumps on screen (\(real.filter(\.transient).count) transient), \(jumps.count - real.count) offscreen, \(actions.count) actions, \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        T.expect(real.isEmpty || ProcessInfo.processInfo.environment["FLO_INTEGRITY_REPORT_ONLY"] == "1", "0 unexpected jumps (\(real.count))")
        // the shortcut line faded and came back through the whole script (the jumps above include its fades)
        if FlowriterSpace.enabled, let h = ctx.pane.hints, ShortcutHintsView.enabled {
            T.log("integrity: shortcut line faded \(h.fadeCount) times during the script")
            T.expect(h.fadeCount > 0, "the shortcut line faded while the script typed (\(h.fadeCount) fades)")
        }
    }

    // MARK: 11. a braindump (build 31 recording)

    static func typing(_ ctx: T.Context, _ s: String) -> [() -> Void] {
        s.map { ch in { key(ctx, String(ch), code: ch == " " ? 49 : 0) } }
    }

    /// At the end of the post: a heading and a list, a line after the list, blank lines, a paragraph of
    /// soft lines, then "-", "- ", "--", "=" and "- item" on the line under the paragraph. Nothing
    /// above the caret may reflow, the first key on an empty line lands where the caret was, and a
    /// blank line is as tall as a text line (the column keeps one line grid).
    static func braindump(_ ctx: T.Context) async {
        let c = ctx.c
        let before = c.state.doc.string
        let end = c.state.doc.length
        await setup(ctx, NSRange(location: end, length: 0))
        c.textView.insertText("\n\n### Todos\n- Water the plants\n- Call the bakery\n", replacementRange: NSRange(location: end, length: 0))
        await T.pause(0.15)
        let ret: () -> Void = { key(ctx, "\r", code: 36) }
        let bs: () -> Void = { backspace(ctx) }
        await act(ctx, "type after list", .edit, typing(ctx, "sdfkjfd"))
        await act(ctx, "return twice after list", .edit, [ret, ret])
        await act(ctx, "type after blank line", .edit, typing(ctx, "dsdfsdf"))
        await act(ctx, "soft lines", .edit, [ret] + typing(ctx, "ddfs") + [ret] + typing(ctx, "dk") + [ret] + typing(ctx, "sldflksdfjsdlkfjdsklf"))
        await act(ctx, "return under paragraph", .edit, [ret])
        // the grid: soft lines one line height apart, a blank line as tall as a text line
        let s = snap(ctx)
        let n = c.state.doc.lines   // the empty line under the paragraph
        if let l1 = s.paras[n - 5]?.first, let l2 = s.paras[n - 4]?.first, let l3 = s.paras[n - 3]?.first, let l4 = s.paras[n - 2]?.first,
           let blank = s.paras[n - 6]?.first {
            T.log(String(format: "braindump lines: blank h %.2f, text h %.2f, %.2f, %.2f, %.2f, steps %.2f %.2f %.2f",
                         blank.h, l1.h, l2.h, l3.h, l4.h, l2.y - l1.y, l3.y - l2.y, l4.y - l3.y))
            T.expect(abs(blank.h - l1.h) <= tol, String(format: "a blank line is as tall as a text line (%.2f vs %.2f)", blank.h, l1.h))
            T.expect(abs((l2.y - l1.y) - (l3.y - l2.y)) <= tol && abs((l3.y - l2.y) - (l4.y - l3.y)) <= tol, "soft lines evenly spaced")
        } else { T.expect(false, "braindump lines measured") }
        T.log("braindump text: \(c.state.doc.string.suffix(120).debugDescription)")
        await act(ctx, "type dash under paragraph", .edit, typing(ctx, "-"))
        let bodySize = c.theme.baseSize
        let paraStart = c.state.doc.line(n - 3).from
        let size = (c.textView.textStorage?.attribute(.font, at: paraStart, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        T.expect(abs(size - bodySize) < 0.01, String(format: "the paragraph above a typed \"-\" keeps the body size (%.1f vs %.1f)", size, bodySize))
        await act(ctx, "type dash space", .edit, typing(ctx, " "))
        await act(ctx, "delete dash", .edit, [bs, bs])
        await act(ctx, "type double dash", .edit, typing(ctx, "--"))
        await act(ctx, "delete double dash", .edit, [bs, bs])
        await act(ctx, "type equals under paragraph", .edit, typing(ctx, "="))
        await act(ctx, "type list item under paragraph", .edit, [bs] + typing(ctx, "- item"))
        // the empty last line after a heading takes the body line box, not the heading's
        // `#`, `##`, `## ` on an empty line: plain text, the caret line keeps its box until the first letter
        await act(ctx, "blank lines for a heading", .edit, [ret, ret, ret])
        let emptyLine = caretRect(ctx, c.state.selection.main.head)
        for (i, ch) in ["#", "#", " "].enumerated() {
            await act(ctx, "type heading mark \(i + 1)", .edit, typing(ctx, ch))
            if let a = emptyLine, let b = caretRect(ctx, c.state.selection.main.head) {
                T.expect(abs(a.minY - b.minY) <= tol && abs(a.height - b.height) <= tol,
                         String(format: "%@ on an empty line keeps the line box (caret y %.1f h %.1f -> y %.1f h %.1f)",
                                c.state.doc.lineAt(c.state.selection.main.head).text.debugDescription, a.minY, a.height, b.minY, b.height))
            }
        }
        await act(ctx, "type heading at the end", .edit, typing(ctx, "Next"))
        await act(ctx, "type under heading", .edit, [ret] + typing(ctx, "x"))
        await act(ctx, "undo braindump", .edit, undoUntil(ctx, before, max: 80))
        if c.state.doc.string != before {
            // the setup insert is one more undo step; anything left is a failure below
            await act(ctx, "undo braindump setup", .edit, undoUntil(ctx, before, max: 4))
        }
    }

    // MARK: writing space screenshots (`--ui-selftest space <post> <out>`)

    /// The document window as the writer sees it: checks what is (not) on screen, then a window shot
    /// space-<post>-<appearance>.png. The caret sits in the second prose paragraph.
    static func spaceShots(_ ctx: T.Context) async {
        let c = ctx.c, root = ctx.wc.root
        await T.pause(0.5)
        let prose = proseLines(ctx)
        if prose.count > 1 { await setup(ctx, NSRange(location: lineRange(ctx, prose[1]).location + 12, length: 0), scroll: false) }
        c.scrollView.contentView.scroll(to: .zero); c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
        await T.pause(0.4)
        root.layoutSubtreeIfNeeded()
        T.expect(ctx.model.isCompact, "document window (no workspace)")
        T.expect(root.sidebar.isHidden, "no sidebar")
        T.expect(root.tabs.isHidden, "no tabs")
        T.expect(root.compactHeader.isHidden, "no file picker header")
        T.expect(ctx.pane.frontmatterPanel?.isHidden ?? true, "no properties table")
        T.expect(c.text.hasPrefix("---\n") == ((try? String(contentsOfFile: ctx.file, encoding: .utf8))?.hasPrefix("---\n") ?? false), "frontmatter is in the text (raw)")
        let count = root.flowriterCount
        T.expect(!count.isHidden && count.text.hasSuffix("chars"), "count at the top: \(count.text)")
        let t = c.theme
        let col = c.textView.textContainer!.size.width - 48   // the gutter (AttributeApplier)
        T.log(String(format: "column %.0f pt = %.1f ch of %@ %.0f pt, line height %.2f", col, col / t.ch, t.font(size: t.baseSize, weight: 400, mono: false).fontName, t.baseSize, t.lineHeight))
        T.expect(col / t.ch >= 64 && col / t.ch <= 70, "column 64 to 70 characters")
        T.log("colours: bg \(t.background.hexDump) text \(t.textColor.hexDump) muted \(t.mutedColor.hexDump) accent \(t.accent.hexDump)")
        let name = ((ctx.file as NSString).lastPathComponent as NSString).deletingPathExtension
        T.screenshot(ctx, "space-\(name)-\(ProcessInfo.processInfo.environment["FLO_TEST_APPEARANCE"] ?? "system").png")
    }
}

extension NSColor {
    var hexDump: String {
        guard let c = usingColorSpace(.sRGB) else { return "\(self)" }
        return String(format: "#%02X%02X%02X/%.2f", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), c.alphaComponent)
    }
}
