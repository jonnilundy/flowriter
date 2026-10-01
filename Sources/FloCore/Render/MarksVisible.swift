import Foundation

/// Flowriter: "marks always visible" mode. Markdown syntax marks (`**`, `_`, backticks, `#`, `>`,
/// link brackets and URLs, escapes, setext underlines) stay visible in their dim colour on every
/// line instead of hiding off the caret line, and widgets that unfold when the caret touches them
/// (dashes, emoji, rules, tables, math, HTML blocks, images, wiki links) stay as source. The plan then
/// no longer depends on the selection, so moving the caret never reflows text. Off by default
/// (upstream Flo State behaviour, and what the web parity fixtures record); the app turns it on.
///
/// Setext headings (a line of `=` or `-` under a paragraph) render as plain text in this mode: the
/// underline restyles the lines above it, so a single "-" typed under a paragraph (the start of a
/// list, most of the time) turned the whole paragraph into a heading at once, and deleting it flipped
/// it back. ATX `#` headings, whose mark sits on the heading line itself, are the headings here,
/// once a character follows the marks: a line of only `#` and spaces is plain text.
extension RenderPlanner {
    nonisolated(unsafe) public static var marksAlwaysVisible = false
}

extension Planner {
    /// Highlight rule in marks mode: a setext heading highlights as a paragraph, its underline as
    /// text; an ATX heading with no text yet highlights as a paragraph (its `#` stays dim).
    func plainSetextRule(_ n: SyntaxNode) -> (HTag, Bool)? {
        if n.name.hasPrefix("SetextHeading") { return NodeTags.rules["Paragraph"] }
        if n.name.hasPrefix("ATXHeading"), emptyATXHeading(n) { return NodeTags.rules["Paragraph"] }
        if n.name == "HeaderMark", n.parent?.name.hasPrefix("SetextHeading") == true { return nil }
        return NodeTags.rules[n.name]
    }

    /// An ATX heading with no text yet (`#`, `## `, `# #`): only marks and spaces. In marks mode it
    /// renders as plain text until a non-space character follows the marks, so typing `#` on an
    /// empty line does not give the line the heading's size and space before (it moved 24 pt).
    func emptyATXHeading(_ n: SyntaxNode) -> Bool {
        let marks = n.children.filter { $0.name == "HeaderMark" }
        guard let open = marks.first else { return false }
        let end = marks.count > 1 ? marks[marks.count - 1].from : n.to
        guard end > open.to else { return true }
        return doc.slice(open.to, end).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Marks of the node [from, to) are shown: always in marks mode, else when the caret shares a line.
    func marksShown(_ from: Int, _ to: Int) -> Bool {
        !marksHidden && (marksVisible || selectionSharesLine(from, to))   // reading view: never (ReadingView.swift)
    }

    /// Widgets over [from, to) unfold to source: always in marks mode, else when the selection touches.
    func unfolded(_ from: Int, _ to: Int) -> Bool {
        !marksHidden && (marksVisible || selectionTouches(from, to))   // reading view: never (ReadingView.swift)
    }

    /// Marks mode: frontmatter reads as dim raw text (no code box, no YAML colours).
    mutating func dimFrontmatter(_ n: SyntaxNode) {
        apply(n.from, n.to) { $0.color = .muted; $0.mono = true }
    }

    /// Marks mode: link text keeps the link colour, the URL is dim.
    mutating func markLink(_ n: SyntaxNode) {
        guard marksVisible, !marksHidden else { return }
        let marks = children(n, named: ["LinkMark"])
        if marks.count >= 2 {
            apply(marks[0].to, marks[1].from) { st in if st.color == .text { st.color = .link } }
        }
        for u in children(n, named: ["URL"]) { apply(u.from, u.to) { $0.color = .muted } }
    }
}
