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
}
