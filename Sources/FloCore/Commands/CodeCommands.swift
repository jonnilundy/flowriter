import Foundation

/// Flowriter: typing in fenced code blocks.
public enum CodeCommands {
    /// Whether `pos` is in a fenced code block. Not indented code: a line with 4 leading spaces is as
    /// often an over-indented list item ("    * foo"), where Tab keeps indenting the line (the
    /// upstream keys parity cases).
    static func inCodeBlock(_ state: EditorState, _ pos: Int) -> Bool {
        var found = false
        state.tree.iterate(from: pos, to: pos, enter: { n, _ in
            if found { return false }
            if n.name == "FencedCode" && n.from <= pos && pos <= n.to { found = true; return false }
            return true
        })
        return found
    }

    /// Tab in a fenced code block with no selection: the indent unit at the caret, as in a code editor
    /// (CM's indentMore put it at the line start, also with the caret mid line). A selection still
    /// indents its lines (indentMore); Shift Tab is unchanged.
    public static let tabInCode: Command = { t in
        let state = t.state
        guard state.selection.ranges.allSatisfy({ $0.empty && inCodeBlock(state, $0.head) }) else { return false }
        let unit = state.indentUnit
        var spec = state.changeByRange { r in
            ([Change(from: r.head, insert: unit)], .cursor(r.head + unit.utf16.count))
        }
        spec.userEvent = "input.indent"
        t.dispatch(spec)
        return true
    }

    /// Multi-line text pasted at `pos` in a fenced block inside a list item: every line after the
    /// first gets the block's content indent (the fence's column) on top of its own indent, or a line
    /// with less indent ends the list item and the block with it. Empty lines stay empty. Anywhere
    /// else (a top-level block, a block in a quote, prose) the text is unchanged.
    public static func indentPaste(_ text: String, state: EditorState, at pos: Int) -> String {
        guard text.contains("\n") else { return text }
        var fence: SyntaxNode?
        state.tree.iterate(from: pos, to: pos, enter: { n, _ in
            if fence != nil { return false }
            if n.name == "FencedCode" && n.from <= pos && pos <= n.to { fence = n; return false }
            return true
        })
        guard let f = fence else { return text }
        var inItem = false, inQuote = false
        var p = f.parent
        while let q = p { if q.name == "ListItem" { inItem = true }; if q.name == "Blockquote" { inQuote = true }; p = q.parent }
        let column = f.from - state.doc.lineAt(f.from).from
        guard inItem, !inQuote, column > 0 else { return text }
        let indent = String(repeating: " ", count: column)
        let lines = text.components(separatedBy: "\n")
        return lines.enumerated().map { i, l in i == 0 || l.isEmpty ? l : indent + l }.joined(separator: "\n")
    }
}
