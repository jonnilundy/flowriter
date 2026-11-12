import Foundation

/// One replacement in the text and the selection after it.
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var text: String
    public var selection: NSRange
    public init(range: NSRange, text: String, selection: NSRange) {
        self.range = range; self.text = text; self.selection = selection
    }
}

/// What Return, Tab, Shift-Tab and Backspace do in lists and quotes. Pure text in, one edit out;
/// nil means the key does what it does in any text field.
public enum ListEditing {
    /// Width of an indent step outside a list.
    public static let indentWidth = 4

    private struct LineInfo {
        var range: NSRange          // without the line terminator
        var next: Int               // start of the next line (the text's length on the last line)
        var terminator: String      // "\n", "\r\n", or "" on the last line
        var units: [UInt16]
        var prefix: LinePrefix?

        var indent: Int {
            var i = 0
            while i < units.count, Chars.isSpace(units[i]) { i += 1 }
            return i
        }
        var isBlank: Bool { units.allSatisfy(Chars.isSpace) }
        /// A list item's prefix (a quote is not a list).
        var item: LinePrefix? { prefix?.kind == .quote ? nil : prefix }
    }

    private static func line(_ text: NSString, at location: Int) -> LineInfo {
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: min(max(0, location), text.length), length: 0))
        let range = NSRange(location: start, length: contentsEnd - start)
        var units = [UInt16](repeating: 0, count: range.length)
        if range.length > 0 { text.getCharacters(&units, range: range) }
        let terminator = text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
        return LineInfo(range: range, next: end, terminator: terminator, units: units, prefix: LinePrefix.parse(units))
    }

    private static func lineAbove(_ text: NSString, _ l: LineInfo) -> LineInfo? {
        l.range.location > 0 ? line(text, at: l.range.location - 1) : nil
    }

    private static func string(_ units: ArraySlice<UInt16>) -> String { String(utf16CodeUnits: Array(units), count: units.count) }
    private static func spaces(_ n: Int) -> String { String(repeating: " ", count: max(0, n)) }

    /// The text that starts the next item after `p`: same indent, same kind of marker, the next number.
    private static func continuation(_ l: LineInfo, _ p: LinePrefix) -> String {
        let indent = string(l.units[0..<p.indent])
        switch p.kind {
        case .quote:
            return string(l.units[0..<p.contentStart])
        case let .bullet(c):
            return indent + string([c]) + " " + (p.checkbox != nil ? "[ ] " : "")
        case let .ordered(number, delimiter):
            return indent + "\(number + 1)" + string([delimiter]) + " " + (p.checkbox != nil ? "[ ] " : "")
        }
    }

    // MARK: Return

    public static func newline(in text: NSString, selection: NSRange) -> TextEdit? {
        let l = line(text, at: selection.location)
        guard NSMaxRange(selection) <= NSMaxRange(l.range) else { return nil }   // a selection across lines: plain Return
        let caret = selection.location - l.range.location
        guard let p = l.prefix else {
            // keep the line's indent
            let indent = l.indent
            guard indent > 0, indent < l.units.count, caret >= indent else { return nil }
            return insert("\n" + string(l.units[0..<indent]), at: selection)
        }
        guard caret >= p.contentStart else { return nil }
        if selection.length == 0, l.units[p.contentStart...].allSatisfy(Chars.isSpace) {
            // Return on an empty item leaves the list: one level out, or out of it at the top level
            if p.indent > 0, l.item != nil {
                let newLine = spaces(p.indent - outdentStep(text, l)) + string(l.units[p.indent...])
                return TextEdit(range: l.range, text: newLine, selection: NSRange(location: l.range.location + newLine.utf16.count, length: 0))
            }
            return TextEdit(range: l.range, text: "", selection: NSRange(location: l.range.location, length: 0))
        }
        return insert("\n" + continuation(l, p), at: selection)
    }

    private static func insert(_ s: String, at selection: NSRange) -> TextEdit {
        TextEdit(range: selection, text: s, selection: NSRange(location: selection.location + s.utf16.count, length: 0))
    }

    // MARK: Backspace

    /// Backspace steps out of a list one level per key, never one space per key:
    /// - right after the marker of a nested item: the item moves one level out (as Shift-Tab);
    /// - right after the marker of a top-level item or a quote: the marker goes;
    /// - in the spaces that indent a line: back to the previous indent stop.
    public static func backspace(in text: NSString, selection: NSRange) -> TextEdit? {
        guard selection.length == 0 else { return nil }
        let l = line(text, at: selection.location)
        let caret = selection.location - l.range.location
        if let p = l.prefix, caret == p.contentStart {
            if l.item != nil, p.indent > 0 { return shift([l], by: -outdentStep(text, l), selection: selection) }
            let range = NSRange(location: l.range.location + p.indent, length: p.contentStart - p.indent)
            return TextEdit(range: range, text: "", selection: NSRange(location: range.location, length: 0))
        }
        if caret > 0, caret <= l.indent, l.units[0..<caret].allSatisfy({ $0 == Chars.space }) {
            let remove = caret % indentWidth == 0 ? indentWidth : caret % indentWidth
            let range = NSRange(location: selection.location - remove, length: remove)
            return TextEdit(range: range, text: "", selection: NSRange(location: range.location, length: 0))
        }
        return nil
    }

    // MARK: Tab and Shift-Tab

    public static func tab(in text: NSString, selection: NSRange, outdent: Bool) -> TextEdit? {
        let first = line(text, at: selection.location)
        let last = selection.length == 0 ? first : line(text, at: NSMaxRange(selection) - 1)
        var lines = [first]
        while let l = lines.last, l.range.location < last.range.location, l.next > l.range.location, l.next <= text.length {
            lines.append(line(text, at: l.next))
        }
        if first.item != nil {
            return shift(lines, by: outdent ? -outdentStep(text, first) : indentStep(text, first), selection: selection)
        }
        if outdent || selection.length > 0 {
            return shift(lines, by: outdent ? -indentWidth : indentWidth, selection: selection)
        }
        // soft tab: spaces up to the next stop
        let column = selection.location - first.range.location
        return insert(spaces(indentWidth - column % indentWidth), at: selection)
    }

    /// A nested item sits under its parent's text: two columns for "- ", three for "1. ".
    private static func indentStep(_ text: NSString, _ l: LineInfo) -> Int {
        guard let p = l.item else { return indentWidth }
        var above = lineAbove(text, l)
        while let a = above, a.isBlank { above = lineAbove(text, a) }
        if let q = above?.item {
            if q.indent > p.indent { return q.indent - p.indent }
            if q.indent == p.indent { return q.markerEnd - q.indent + 1 }
        }
        return p.markerEnd - p.indent + 1
    }

    /// Back to the indent of the nearest item above that is less indented.
    private static func outdentStep(_ text: NSString, _ l: LineInfo) -> Int {
        guard let p = l.item, p.indent > 0 else { return 0 }
        var above = lineAbove(text, l)
        var looked = 0
        while let a = above, looked < 500 {
            if let q = a.item, q.indent < p.indent { return p.indent - q.indent }
            if !a.isBlank, a.item == nil, a.indent == 0 { break }   // text that is not part of the list
            above = lineAbove(text, a)
            looked += 1
        }
        return p.indent
    }

    /// Move the indent of `lines` by `step` columns (negative: remove up to that many).
    private static func shift(_ lines: [LineInfo], by step: Int, selection: NSRange) -> TextEdit? {
        guard let first = lines.first, let last = lines.last, step != 0 else { return nil }
        var out: [String] = []
        var deltas: [Int] = []
        for l in lines {
            if step > 0 {
                let add = l.units.isEmpty && lines.count > 1 ? 0 : step
                deltas.append(add)
                out.append(spaces(add) + string(l.units[...]))
            } else {
                var remove = 0
                let indent = l.indent
                while remove < min(indent, -step), l.units[remove] == Chars.space { remove += 1 }
                if remove == 0, indent > 0, l.units[0] == Chars.tab { remove = 1 }
                deltas.append(-remove)
                out.append(string(l.units[remove...]))
            }
        }
        guard deltas.contains(where: { $0 != 0 }) else { return nil }
        // a position moves with the text of its line, and never to before the line's start
        func moved(_ p: Int, stayAtLineStart: Bool) -> Int {
            var r = p
            for (l, d) in zip(lines, deltas) {
                if p > NSMaxRange(l.range) { r += d; continue }
                if p >= l.range.location {
                    let base = l.range.location + (r - p)
                    if !(stayAtLineStart && p == l.range.location) { r = max(base, r + d) }
                }
                break
            }
            return r
        }
        let start = moved(selection.location, stayAtLineStart: selection.length > 0)
        let end = selection.length > 0 ? moved(NSMaxRange(selection), stayAtLineStart: false) : start
        // lines are joined with the terminators they had, so only the indent changes
        var text = ""
        for (i, l) in lines.enumerated() { text += out[i] + (i < lines.count - 1 ? l.terminator : "") }
        let whole = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        return TextEdit(range: whole, text: text, selection: NSRange(location: start, length: max(0, end - start)))
    }
}

/// Cmd-B and Cmd-I: wrap the selection in a marker, or take the marker off.
public enum Formatting {
    public static func toggle(_ marker: String, in text: NSString, selection: NSRange) -> TextEdit {
        let n = (marker as NSString).length
        let before = NSRange(location: selection.location - n, length: n), after = NSRange(location: NSMaxRange(selection), length: n)
        let inner = text.substring(with: selection)
        if selection.location >= n, NSMaxRange(after) <= text.length,
           text.substring(with: before) == marker, text.substring(with: after) == marker {
            return TextEdit(range: NSRange(location: before.location, length: selection.length + 2 * n), text: inner,
                            selection: NSRange(location: before.location, length: selection.length))
        }
        return TextEdit(range: selection, text: marker + inner + marker, selection: NSRange(location: selection.location + n, length: selection.length))
    }
}
