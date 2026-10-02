import AppKit
import FloCore
import FloKit

/// Flowriter: the editor's right-click menu holds only the writing actions, each with its shortcut.
///   on a misspelled word     the spelling guesses, Ignore Spelling, Learn Spelling (at the top, as macOS)
///   on ghost text            Revive                  ⌥G   (the whole ghost, and every ghost a selection
///                                                          around the click touches)
///   in a selection           Ghost it                ⌥G
///                            Add Alternative…        ⌥A
///                            Stash in Overflow
///   on text with versions    Show Alternatives
/// Nothing to offer: no menu at all. Cut, Copy, Paste, Select All and the formatting commands stay on
/// their shortcuts and in the menu bar. The upstream shell (FLO_SPACE=0) keeps the upstream menu.
@MainActor
enum WritingMenu {
    static let ghostTitle = "Ghost it"
    static let reviveTitle = "Revive"
    static let showAlternativesTitle = "Show Alternatives"
    static let ignoreSpellingTitle = "Ignore Spelling"
    static let learnSpellingTitle = "Learn Spelling"
    static let maxGuesses = 6

    static func attach(to c: EditorController, pane: EditorPaneView) {
        guard FlowriterSpace.enabled, !ShellSnapshot.active else { return }
        c.contextMenuProvider = { [weak c, weak pane] _, pos in
            guard let c = c, let pane = pane else { return nil }
            return menu(c, pane: pane, at: pos)
        }
    }

    /// The menu for a right click at document offset `pos` (NSNotFound: off the text), nil for none.
    static func menu(_ c: EditorController, pane: EditorPaneView, at pos: Int) -> NSMenu? {
        guard pos != NSNotFound else { return nil }
        var groups: [[NSMenuItem]] = []
        if let miss = misspelling(c, at: pos) { groups.append(spellingItems(c, miss)) }
        var writing: [NSMenuItem] = []
        let sel = c.state.selection.main
        let a = min(sel.anchor, sel.head), b = max(sel.anchor, sel.head)
        if let g = c.ghosts, g.menuTitle(at: pos) == reviveTitle {
            writing.append(ClosureMenuItem(reviveTitle, key: "g", modifiers: [.option]) { [weak g] in _ = g?.revive(at: pos) })
        } else if b > a && pos >= a && pos <= b {
            if let g = c.ghosts {
                writing.append(ClosureMenuItem(ghostTitle, key: "g", modifiers: [.option]) { [weak g] in _ = g?.toggle() })
            }
            if c.alternatives != nil {
                writing.append(ClosureMenuItem(AlternativesAttach.addTitle, key: "a", modifiers: [.option]) { [weak pane] in
                    AlternativesAttach.addAlternative(pane?.superview as? EditorAreaView)
                })
            }
            if pane.overflow != nil {
                writing.append(ClosureMenuItem(OverflowMenu.stashTitle) { [weak pane] in
                    pane?.overflow?.stashSelection()
                })
            }
        }
        if !writing.isEmpty { groups.append(writing) }
        if let l = c.alternatives, let set = l.session.innermost(at: pos) {
            let id = set.id
            groups.append([ClosureMenuItem(showAlternativesTitle) { [weak c, weak pane] in
                guard let c = c, let area = pane?.superview as? EditorAreaView, let l = c.alternatives, let s = l.set(id) else { return }
                if l.session.innermost(at: l.caret)?.id != id { c.textView.setSelectedRange(NSRange(location: s.from, length: 0)) }
                let p = AlternativesAttach.panel(area)
                if p.isOpen { p.refresh() } else { p.open() }
            }])
        }
        guard !groups.isEmpty else { return nil }
        let m = NSMenu(title: "Editor")
        m.autoenablesItems = false
        m.allowsContextMenuPlugIns = false   // no Services
        for (i, g) in groups.enumerated() {
            if i > 0 { m.addItem(.separator()) }
            g.forEach(m.addItem)
        }
        return m
    }

    // MARK: spelling

    struct Misspelling { var range: NSRange; var word: String }

    /// The misspelled word under `pos`, as the text view's underline marks it (the shared checker
    /// with the view's document tag, so Ignore Spelling holds for this document).
    static func misspelling(_ c: EditorController, at pos: Int) -> Misspelling? {
        guard c.textView.isContinuousSpellCheckingEnabled else { return nil }
        let s = c.state.doc.string as NSString
        guard s.length > 0, pos >= 0, pos <= s.length else { return nil }
        if c.touchesCode(NSRange(location: pos, length: 0)) { return nil }   // code is not spell checked
        let para = s.paragraphRange(for: NSRange(location: min(pos, s.length - 1), length: 0))
        let p = s.substring(with: para)
        let local = pos - para.location
        let checker = NSSpellChecker.shared, tag = c.textView.spellCheckerDocumentTag
        var start = 0
        let n = (p as NSString).length
        while start < n {
            let r = checker.checkSpelling(of: p, startingAt: start, language: nil, wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
            guard r.location != NSNotFound, r.length > 0, r.location >= start else { return nil }
            if local >= r.location && local <= NSMaxRange(r) {
                return Misspelling(range: NSRange(location: para.location + r.location, length: r.length), word: (p as NSString).substring(with: r))
            }
            if r.location > local { return nil }
            start = NSMaxRange(r)
        }
        return nil
    }

    static func guesses(_ c: EditorController, _ m: Misspelling) -> [String] {
        let s = c.state.doc.string as NSString
        let para = s.paragraphRange(for: m.range)
        let local = NSRange(location: m.range.location - para.location, length: m.range.length)
        let checker = NSSpellChecker.shared
        let g = checker.guesses(forWordRange: local, in: s.substring(with: para), language: checker.language(),
                                inSpellDocumentWithTag: c.textView.spellCheckerDocumentTag) ?? []
        return Array(g.prefix(maxGuesses))
    }

    static func spellingItems(_ c: EditorController, _ m: Misspelling) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let g = guesses(c, m)
        if g.isEmpty {
            let none = NSMenuItem(title: "No Guesses Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        for word in g {
            items.append(ClosureMenuItem(word, modifiers: []) { [weak c] in
                guard let c = c else { return }
                // only while the word is still there (the menu can outlive an edit)
                let s = c.state.doc.string as NSString
                guard NSMaxRange(m.range) <= s.length, s.substring(with: m.range) == m.word else { return }
                _ = c.run { t in
                    t.dispatch(TransactionSpec(changes: [Change(from: m.range.location, to: NSMaxRange(m.range), insert: word)],
                                               selection: .cursor(m.range.location + (word as NSString).length)))
                    return true
                }
            })
        }
        items.append(.separator())
        items.append(ClosureMenuItem(ignoreSpellingTitle, modifiers: []) { [weak c] in
            guard let c = c else { return }
            NSSpellChecker.shared.ignoreWord(m.word, inSpellDocumentWithTag: c.textView.spellCheckerDocumentTag)
            clearUnderline(c, m)
        })
        items.append(ClosureMenuItem(learnSpellingTitle, modifiers: []) { [weak c] in
            guard let c = c else { return }
            NSSpellChecker.shared.learnWord(m.word)
            clearUnderline(c, m)
        })
        return items
    }

    static func clearUnderline(_ c: EditorController, _ m: Misspelling) {
        let len = (c.textView.string as NSString).length
        guard NSMaxRange(m.range) <= len else { return }
        c.textView.setSpellingState(0, range: m.range)
    }
}
