import Foundation

/// What a character is in Markdown. Every flag maps to colour or weight only, never to a size,
/// so styling a line cannot move text.
public struct StyleFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    /// Syntax characters: `#`, `*`, `` ` ``, `>`, brackets.
    public static let mark = StyleFlags(rawValue: 1 << 0)
    public static let bold = StyleFlags(rawValue: 1 << 1)
    public static let italic = StyleFlags(rawValue: 1 << 2)
    public static let heading = StyleFlags(rawValue: 1 << 3)
    /// Inline code and the lines of a code block.
    public static let code = StyleFlags(rawValue: 1 << 4)
    public static let link = StyleFlags(rawValue: 1 << 5)
    /// A link's destination.
    public static let url = StyleFlags(rawValue: 1 << 6)
    public static let strike = StyleFlags(rawValue: 1 << 7)
    public static let quote = StyleFlags(rawValue: 1 << 8)
    public static let listMarker = StyleFlags(rawValue: 1 << 9)
    /// The text of a checked task.
    public static let done = StyleFlags(rawValue: 1 << 10)
    /// Frontmatter and HTML comments.
    public static let meta = StyleFlags(rawValue: 1 << 11)
    /// Every character of a fenced code block line, fences included.
    public static let codeBlock = StyleFlags(rawValue: 1 << 12)
    /// The `#` characters that open a heading.
    public static let headingMark = StyleFlags(rawValue: 1 << 13)
}

/// The state a line starts in. It is all a line needs from the lines above it.
public enum BlockState: Hashable, Sendable {
    case normal
    case frontmatter
    case fence(char: UInt16, count: Int)

    /// A stable number for the state, to keep on the text as an attribute.
    public var code: Int {
        switch self {
        case .normal: return 0
        case .frontmatter: return 1
        case let .fence(char, count): return 2 + (char == Chars.tilde ? 1 : 0) + count * 4
        }
    }
}

public struct StyledLine: Equatable, Sendable {
    /// One entry per UTF-16 unit of the line.
    public var flags: [StyleFlags]
    public var endState: BlockState
    /// Columns a wrapped line indents by: the width of a list marker or quote prefix. 0 for none.
    public var hangingColumns: Int
}

enum Chars {
    static let tab: UInt16 = 9, space: UInt16 = 32, bang: UInt16 = 33, hash: UInt16 = 35
    static let lparen: UInt16 = 40, rparen: UInt16 = 41, star: UInt16 = 42, plus: UInt16 = 43
    static let minus: UInt16 = 45, dot: UInt16 = 46, lt: UInt16 = 60, gt: UInt16 = 62
    static let lbracket: UInt16 = 91, backslash: UInt16 = 92, rbracket: UInt16 = 93, caret: UInt16 = 94
    static let underscore: UInt16 = 95, backtick: UInt16 = 96, pipe: UInt16 = 124, tilde: UInt16 = 126
    static let x: UInt16 = 120, X: UInt16 = 88

    static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isAlnum(_ c: UInt16) -> Bool { isDigit(c) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isWhitespace(_ c: UInt16) -> Bool {
        c == space || c == tab || c == 10 || c == 13 || c == 0xA0 || (c >= 0x2000 && c <= 0x200A) || c == 0x3000
    }
    static func isAsciiPunct(_ c: UInt16) -> Bool {
        (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
    }
    static func isPunct(_ c: UInt16) -> Bool {
        isAsciiPunct(c) || (c >= 0x2010 && c <= 0x2027) || (c >= 0x2030 && c <= 0x205E) || (c >= 0x3001 && c <= 0x303F)
            || c == 0xA1 || c == 0xAB || c == 0xBB || c == 0xBF
    }
}

/// A list item's or quote's prefix on one line.
public struct LinePrefix: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bullet(UInt16)
        case ordered(number: Int, delimiter: UInt16)
        case quote
    }
    public var kind: Kind
    /// Leading whitespace, in UTF-16 units.
    public var indent: Int
    /// Where the marker ends (after the bullet, the number and delimiter, or the last `>`).
    public var markerEnd: Int
    /// `[ ]` or `[x]` after the marker: its range in the line, and whether it is checked.
    public var checkbox: (range: Range<Int>, checked: Bool)?
    /// First unit of the item's own text.
    public var contentStart: Int

    public static func == (a: LinePrefix, b: LinePrefix) -> Bool {
        a.kind == b.kind && a.indent == b.indent && a.markerEnd == b.markerEnd && a.contentStart == b.contentStart
            && a.checkbox?.range == b.checkbox?.range && a.checkbox?.checked == b.checkbox?.checked
    }

    /// The prefix of `u[from...]`, nil when the line is not a list item or a quote.
    public static func parse(_ u: [UInt16], from: Int = 0) -> LinePrefix? {
        let n = u.count
        var i = from
        while i < n, Chars.isSpace(u[i]) { i += 1 }
        let indent = i - from
        guard i < n else { return nil }
        if u[i] == Chars.gt, indent <= 3 {
            var j = i + 1
            // nested quotes: `> > text`
            while true {
                var k = j
                while k < n, Chars.isSpace(u[k]), k - j < 1 { k += 1 }
                if k < n, u[k] == Chars.gt { j = k + 1 } else { break }
            }
            var content = j
            if content < n, u[content] == Chars.space { content += 1 }
            return LinePrefix(kind: .quote, indent: indent, markerEnd: j, checkbox: nil, contentStart: content)
        }
        var kind: Kind
        var j = i
        if u[i] == Chars.minus || u[i] == Chars.star || u[i] == Chars.plus {
            kind = .bullet(u[i])
            j = i + 1
        } else if Chars.isDigit(u[i]) {
            var number = 0
            while j < n, Chars.isDigit(u[j]), j - i < 9 { number = number * 10 + Int(u[j] - 48); j += 1 }
            guard j < n, u[j] == Chars.dot || u[j] == Chars.rparen else { return nil }
            kind = .ordered(number: number, delimiter: u[j])
            j += 1
        } else {
            return nil
        }
        // a marker needs a space after it: "-" alone or "-word" is text
        guard j < n, Chars.isSpace(u[j]) else { return nil }
        let markerEnd = j
        var content = j
        while content < n, Chars.isSpace(u[content]) { content += 1 }
        var checkbox: (range: Range<Int>, checked: Bool)?
        if content + 2 < n, u[content] == Chars.lbracket, u[content + 2] == Chars.rbracket,
           u[content + 1] == Chars.space || u[content + 1] == Chars.x || u[content + 1] == Chars.X,
           content + 3 == n || Chars.isSpace(u[content + 3]) {
            checkbox = (content..<(content + 3), u[content + 1] != Chars.space)
            content += 3
            if content < n, Chars.isSpace(u[content]) { content += 1 }
        }
        return LinePrefix(kind: kind, indent: indent, markerEnd: markerEnd, checkbox: checkbox, contentStart: content)
    }
}

public enum MarkdownStyler {
    public static func style(_ line: String, state: BlockState = .normal, isFirstLine: Bool = false) -> StyledLine {
        style(Array(line.utf16), state: state, isFirstLine: isFirstLine)
    }

    /// Style one line (no line terminator) that starts in `state`.
    public static func style(_ u: [UInt16], state: BlockState, isFirstLine: Bool) -> StyledLine {
        var f = [StyleFlags](repeating: [], count: u.count)
        func fill(_ flags: StyleFlags) { for i in f.indices { f[i] = flags } }
        switch state {
        case .frontmatter:
            fill([.meta])
            let end = isOnly(u, Chars.minus, 3) || isOnly(u, Chars.dot, 3)
            return StyledLine(flags: f, endState: end ? .normal : .frontmatter, hangingColumns: 0)
        case let .fence(char, count):
            if let run = fenceRun(u), run.char == char, run.count >= count, restIsBlank(u, from: run.end) {
                fill([.mark, .codeBlock])
                return StyledLine(flags: f, endState: .normal, hangingColumns: 0)
            }
            fill([.code, .codeBlock])
            return StyledLine(flags: f, endState: state, hangingColumns: 0)
        case .normal:
            if isFirstLine, isOnly(u, Chars.minus, 3) {
                fill([.meta])
                return StyledLine(flags: f, endState: .frontmatter, hangingColumns: 0)
            }
            if let run = fenceRun(u), run.char == Chars.tilde || !u[run.end...].contains(Chars.backtick) {
                fill([.mark, .codeBlock])
                return StyledLine(flags: f, endState: .fence(char: run.char, count: run.count), hangingColumns: 0)
            }
            let hanging = block(u, from: 0, &f)
            return StyledLine(flags: f, endState: .normal, hangingColumns: hanging)
        }
    }

    // MARK: blocks

    /// Style `u[from...]` as a block, and return the columns its wrapped lines hang by.
    private static func block(_ u: [UInt16], from: Int, _ f: inout [StyleFlags]) -> Int {
        let n = u.count
        var i = from
        while i < n, u[i] == Chars.space, i - from < 3 { i += 1 }
        guard i < n else { return 0 }
        if u[i] == Chars.hash {
            var j = i
            while j < n, u[j] == Chars.hash { j += 1 }
            if j - i <= 6, j == n || Chars.isSpace(u[j]) {
                for k in i..<j { f[k] = [.mark, .bold, .headingMark] }
                var content = j
                while content < n, Chars.isSpace(u[content]) { content += 1 }
                inline(u, content, n, &f)
                for k in content..<n { f[k].formUnion([.heading, .bold]) }
                return 0
            }
        }
        if isRule(u, from: i) {
            for k in i..<n { f[k] = [.mark] }
            return 0
        }
        if let p = LinePrefix.parse(u, from: from) {
            switch p.kind {
            case .quote:
                for k in (from + p.indent)..<p.markerEnd where u[k] == Chars.gt { f[k] = [.mark] }
                let inner = block(u, from: p.contentStart, &f)
                for k in p.contentStart..<n { f[k].insert(.quote) }
                return columns(u, from, p.contentStart) + inner
            case .bullet, .ordered:
                for k in (from + p.indent)..<p.markerEnd { f[k] = [.listMarker] }
                var done = false
                if let box = p.checkbox {
                    done = box.checked
                    for k in box.range { f[k] = done ? [.mark] : [.listMarker] }
                }
                inline(u, p.contentStart, n, &f)
                if done { for k in p.contentStart..<n { f[k].insert(.done) } }
                return columns(u, from, p.contentStart)
            }
        }
        inline(u, i, n, &f)
        if u[i] == Chars.pipe {
            // a table row: the pipes are structure
            for k in i..<n where u[k] == Chars.pipe && !f[k].contains(.code) && (k == 0 || u[k - 1] != Chars.backslash) { f[k] = [.mark] }
        }
        return 0
    }

    /// Display columns of `u[from..<to]` (a tab runs to the next multiple of 4).
    private static func columns(_ u: [UInt16], _ from: Int, _ to: Int) -> Int {
        var c = 0
        for k in from..<to { c = u[k] == Chars.tab ? (c / 4 + 1) * 4 : c + 1 }
        return c
    }

    private static func isOnly(_ u: [UInt16], _ c: UInt16, _ count: Int) -> Bool {
        var end = u.count
        while end > 0, Chars.isSpace(u[end - 1]) { end -= 1 }
        return end == count && u[..<end].allSatisfy { $0 == c }
    }

    private static func restIsBlank(_ u: [UInt16], from: Int) -> Bool { u[from...].allSatisfy(Chars.isSpace) }

    /// A run of three or more backticks or tildes after at most three spaces.
    private static func fenceRun(_ u: [UInt16]) -> (char: UInt16, count: Int, end: Int)? {
        var i = 0
        while i < u.count, u[i] == Chars.space, i < 3 { i += 1 }
        guard i < u.count, u[i] == Chars.backtick || u[i] == Chars.tilde else { return nil }
        let c = u[i]
        var j = i
        while j < u.count, u[j] == c { j += 1 }
        return j - i >= 3 ? (c, j - i, j) : nil
    }

    /// `---`, `***`, `___` with optional spaces between: a thematic break.
    private static func isRule(_ u: [UInt16], from i: Int) -> Bool {
        let c = u[i]
        guard c == Chars.minus || c == Chars.star || c == Chars.underscore else { return false }
        var count = 0
        for k in i..<u.count {
            if u[k] == c { count += 1 } else if !Chars.isSpace(u[k]) { return false }
        }
        return count >= 3
    }

    // MARK: inline

    private struct Delimiter {
        var pos: Int
        var count: Int
        let original: Int
        let char: UInt16
        let canOpen: Bool
        let canClose: Bool
    }

    private static func inline(_ u: [UInt16], _ lo: Int, _ hi: Int, _ f: inout [StyleFlags]) {
        guard lo < hi else { return }
        var delimiters: [Delimiter] = []
        var i = lo
        while i < hi {
            let c = u[i]
            switch c {
            case Chars.backslash:
                if i + 1 < hi, Chars.isAsciiPunct(u[i + 1]) { f[i].insert(.mark); i += 2 } else { i += 1 }
            case Chars.backtick:
                var r = i
                while r < hi, u[r] == Chars.backtick { r += 1 }
                let len = r - i
                if let close = closingBackticks(u, from: r, hi, len) {
                    for k in i..<r { f[k] = [.mark, .code] }
                    for k in r..<close { f[k] = [.code] }
                    for k in close..<(close + len) { f[k] = [.mark, .code] }
                    i = close + len
                } else {
                    i = r
                }
            case Chars.lt:
                if let end = comment(u, i, hi) {
                    for k in i..<end { f[k] = [.meta] }
                    i = end
                } else if let end = autolink(u, i, hi) {
                    f[i] = [.mark]; f[end - 1] = [.mark]
                    for k in (i + 1)..<(end - 1) { f[k] = [.link] }
                    i = end
                } else {
                    i += 1
                }
            case Chars.lbracket:
                i = bracket(u, i, lo, hi, &f)
            case 104 where (i == lo || !Chars.isAlnum(u[i - 1])):   // "h"
                if let end = bareURL(u, i, hi) {
                    for k in i..<end { f[k] = [.link] }
                    i = end
                } else {
                    i += 1
                }
            case Chars.star, Chars.underscore, Chars.tilde:
                var r = i
                while r < hi, u[r] == c { r += 1 }
                let len = r - i
                if c == Chars.tilde && len != 2 { i = r; break }
                let before = i > lo ? u[i - 1] : Chars.space, after = r < hi ? u[r] : Chars.space
                let left = !Chars.isWhitespace(after) && (!Chars.isPunct(after) || Chars.isWhitespace(before) || Chars.isPunct(before))
                let right = !Chars.isWhitespace(before) && (!Chars.isPunct(before) || Chars.isWhitespace(after) || Chars.isPunct(after))
                let open = c == Chars.underscore ? left && (!right || Chars.isPunct(before)) : left
                let close = c == Chars.underscore ? right && (!left || Chars.isPunct(after)) : right
                delimiters.append(Delimiter(pos: i, count: len, original: len, char: c, canOpen: open, canClose: close))
                i = r
            default:
                i += 1
            }
        }
        emphasis(&delimiters, &f)
    }

    /// CommonMark's delimiter pairing, on one line.
    private static func emphasis(_ d: inout [Delimiter], _ f: inout [StyleFlags]) {
        var ci = 0
        while ci < d.count {
            let closer = d[ci]
            guard closer.canClose, closer.count > 0 else { ci += 1; continue }
            var found = -1
            var oi = ci - 1
            while oi >= 0 {
                let o = d[oi]
                if o.char == closer.char, o.canOpen, o.count > 0 {
                    let either = (o.canOpen && o.canClose) || (closer.canOpen && closer.canClose)
                    let blocked = either && (o.original + closer.original) % 3 == 0 && !(o.original % 3 == 0 && closer.original % 3 == 0)
                    if !blocked { found = oi; break }
                }
                oi -= 1
            }
            guard found >= 0 else { ci += 1; continue }
            let opener = d[found]
            let use = closer.char == Chars.tilde ? 2 : (min(opener.count, closer.count) >= 2 ? 2 : 1)
            let openStart = opener.pos + opener.count - use
            for k in openStart..<(openStart + use) { f[k].insert(.mark) }
            for k in closer.pos..<(closer.pos + use) { f[k].insert(.mark) }
            let style: StyleFlags = closer.char == Chars.tilde ? .strike : (use == 2 ? .bold : .italic)
            for k in (opener.pos + opener.count)..<closer.pos { f[k].insert(style) }
            d[found].count -= use
            d[ci].pos += use
            d[ci].count -= use
            for k in (found + 1)..<ci { d[k].count = 0 }
            if d[ci].count == 0 { ci += 1 }
        }
    }

    private static func closingBackticks(_ u: [UInt16], from: Int, _ hi: Int, _ len: Int) -> Int? {
        var i = from
        while i < hi {
            if u[i] == Chars.backtick {
                var r = i
                while r < hi, u[r] == Chars.backtick { r += 1 }
                if r - i == len { return i }
                i = r
            } else {
                i += 1
            }
        }
        return nil
    }

    private static func hasPrefix(_ u: [UInt16], _ i: Int, _ hi: Int, _ s: String) -> Bool {
        let p = Array(s.utf16)
        guard i + p.count <= hi else { return false }
        for k in p.indices where u[i + k] != p[k] { return false }
        return true
    }

    private static func find(_ u: [UInt16], _ from: Int, _ hi: Int, _ s: String) -> Int? {
        let p = Array(s.utf16)
        guard from + p.count <= hi else { return nil }
        for i in from...(hi - p.count) where hasPrefix(u, i, hi, s) { return i }
        return nil
    }

    private static func comment(_ u: [UInt16], _ i: Int, _ hi: Int) -> Int? {
        guard hasPrefix(u, i, hi, "<!--"), let end = find(u, i + 4, hi, "-->") else { return nil }
        return end + 3
    }

    /// `<https://example.com>` or `<me@example.com>`: returns the index after `>`.
    private static func autolink(_ u: [UInt16], _ i: Int, _ hi: Int) -> Int? {
        var j = i + 1
        var marker = false
        while j < hi, u[j] != Chars.gt {
            if Chars.isWhitespace(u[j]) || u[j] == Chars.lt { return nil }
            if u[j] == 58 || u[j] == 64 { marker = true }   // ":" or "@"
            j += 1
        }
        return j < hi && marker && j > i + 3 ? j + 1 : nil
    }

    private static func bareURL(_ u: [UInt16], _ i: Int, _ hi: Int) -> Int? {
        guard hasPrefix(u, i, hi, "http://") || hasPrefix(u, i, hi, "https://") else { return nil }
        var j = i
        while j < hi, !Chars.isWhitespace(u[j]), u[j] != Chars.lt, u[j] != Chars.gt { j += 1 }
        // punctuation that ends the sentence is not part of the address
        while j > i {
            let c = u[j - 1]
            if c == Chars.rparen {
                let inside = u[i..<j]
                if inside.filter({ $0 == Chars.rparen }).count > inside.filter({ $0 == Chars.lparen }).count { j -= 1; continue }
                break
            }
            if c == Chars.dot || c == 44 || c == 59 || c == 58 || c == 33 || c == 63 || c == 39 || c == 34 || c == Chars.star || c == Chars.underscore { j -= 1; continue }
            break
        }
        return j - i > 8 ? j : nil
    }

    /// A `[` at `i`: a wiki link, a footnote, an inline or reference link. Returns where to go on.
    private static func bracket(_ u: [UInt16], _ i: Int, _ lo: Int, _ hi: Int, _ f: inout [StyleFlags]) -> Int {
        if i + 1 < hi, u[i + 1] == Chars.lbracket, let end = find(u, i + 2, hi, "]]"), !u[(i + 2)..<end].contains(Chars.lbracket) {
            for k in [i, i + 1, end, end + 1] { f[k] = [.mark] }
            for k in (i + 2)..<end { f[k] = [.link] }
            return end + 2
        }
        guard let close = closingBracket(u, i, hi) else { return i + 1 }
        if i + 1 < close, u[i + 1] == Chars.caret {
            for k in i...close { f[k] = [.link] }
            return close + 1
        }
        let next = close + 1
        var end: Int?
        if next < hi, u[next] == Chars.lparen {
            var depth = 0
            var j = next
            while j < hi {
                if u[j] == Chars.backslash { j += 2; continue }
                if u[j] == Chars.lparen { depth += 1 }
                if u[j] == Chars.rparen { depth -= 1; if depth == 0 { end = j; break } }
                j += 1
            }
        } else if next < hi, u[next] == Chars.lbracket {
            end = (next + 1..<hi).first { u[$0] == Chars.rbracket }
        }
        guard let last = end else { return i + 1 }
        inline(u, i + 1, close, &f)
        for k in (i + 1)..<close { f[k].insert(.link) }
        f[i] = [.mark]; f[close] = [.mark]; f[next] = [.mark]; f[last] = [.mark]
        for k in (next + 1)..<last { f[k] = [.url] }
        if i > lo, u[i - 1] == Chars.bang, f[i - 1].isEmpty { f[i - 1] = [.mark] }   // an image
        return last + 1
    }

    private static func closingBracket(_ u: [UInt16], _ i: Int, _ hi: Int) -> Int? {
        var depth = 0
        var j = i
        while j < hi {
            let c = u[j]
            if c == Chars.backslash { j += 2; continue }
            if c == Chars.backtick {
                var r = j
                while r < hi, u[r] == Chars.backtick { r += 1 }
                if let close = closingBackticks(u, from: r, hi, r - j) { j = close + (r - j) } else { j = r }
                continue
            }
            if c == Chars.lbracket { depth += 1 }
            if c == Chars.rbracket { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return nil
    }
}
