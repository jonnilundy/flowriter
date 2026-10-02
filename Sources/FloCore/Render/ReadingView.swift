import Foundation

/// Flowriter: the reading view (the Markdown view toggle, ViewToggles.swift). Markdown marks hide
/// on every line, the caret line included, and widgets (dashes, emoji, rules, tables, images, wiki
/// links) stay folded wherever the caret is. Moving the caret never reflows, as in marks mode: the
/// plan never depends on the selection, except the fences of the code block the selection is in,
/// which show in place of their transparent (same advance) hidden form, so a fence being typed is
/// visible. The structural rules of marks mode stay (setext
/// underlines and a line of only `#` are plain text, frontmatter is dim raw text), so typing reflows
/// no more than it does in the writing view. Off by default; switching re-renders once.
extension RenderPlanner {
    nonisolated(unsafe) public static var readingView = false

    /// Quotes get upstream's bar and 1em padding: their `>` marks are hidden (or upstream mode).
    public static var quoteBars: Bool { !marksAlwaysVisible || readingView }
}

extension Planner {
    /// Reading view: marks hidden and widgets folded whatever the selection.
    var marksHidden: Bool { RenderPlanner.readingView }
}
