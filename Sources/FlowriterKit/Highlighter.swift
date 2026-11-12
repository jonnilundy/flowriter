import AppKit

extension NSAttributedString.Key {
    /// `BlockState.code` the line starts in and ends in, on every character of the line.
    static let fwStartState = NSAttributedString.Key("flowriter.startState")
    static let fwEndState = NSAttributedString.Key("flowriter.endState")
    /// On every character of a fenced code block line: the layout manager draws its band.
    static let fwCodeBlock = NSAttributedString.Key("flowriter.codeBlock")
    /// On an inline code span: the layout manager draws its pill.
    static let fwInlineCode = NSAttributedString.Key("flowriter.inlineCode")
}

/// The editor's text storage. After every change of characters it has the changed lines styled
/// again, as a second edit that touches attributes only.
///
/// The styling must not run inside the character edit (a storage delegate's will/didProcessEditing):
/// it would widen that edit's range to whole lines, and NSTextView puts the caret at the end of
/// the edited range, so every typed letter would throw the caret to the next line.
public final class MarkdownTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    var highlighter: MarkdownHighlighter?
    private var styling = false

    public override var string: String { backing.string }

    public override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    public override func replaceCharacters(in range: NSRange, with str: String) {
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
    }

    public override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }

    public override func processEditing() {
        let charactersChanged = editedMask.contains(.editedCharacters), range = editedRange
        super.processEditing()
        guard charactersChanged, !styling, let highlighter else { return }
        styling = true
        MainActor.assumeIsolated { highlighter.restyle(self, edited: range) }
        styling = false
    }
}

/// Colours text as Markdown, one line at a time. It only sets attributes; it never changes characters.
@MainActor
public final class MarkdownHighlighter {
    public var theme: Theme { didSet { paragraphStyles = [:] } }
    /// True while an input method is composing: its marked text keeps the attributes the text
    /// system gave it (underline, clause segments).
    public var isComposing: () -> Bool = { false }
    /// Lines styled by the last edit (tests).
    public private(set) var lastStyledLines = 0

    private var paragraphStyles: [Int: NSParagraphStyle] = [:]
    private var states: [Int: BlockState] = [BlockState.normal.code: .normal, BlockState.frontmatter.code: .frontmatter]

    public init(theme: Theme) { self.theme = theme }

    public func restyleAll(_ storage: NSTextStorage) {
        restyle(storage, edited: NSRange(location: 0, length: storage.length))
    }

    /// Attributes for text typed where there is no character to take them from (an empty
    /// document, the empty last line).
    public var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.regular, .foregroundColor: Theme.text, .paragraphStyle: paragraphStyle(hanging: 0)]
    }

    func paragraphStyle(hanging: Int) -> NSParagraphStyle {
        if let p = paragraphStyles[hanging] { return p }
        let p = NSMutableParagraphStyle()
        p.headIndent = CGFloat(hanging) * theme.charWidth
        p.lineBreakMode = .byWordWrapping
        p.tabStops = []
        p.defaultTabInterval = 4 * theme.charWidth
        paragraphStyles[hanging] = p
        return p
    }

    private func state(_ storage: NSTextStorage, _ key: NSAttributedString.Key, at index: Int) -> BlockState? {
        guard index >= 0, index < storage.length, let n = storage.attribute(key, at: index, effectiveRange: nil) as? Int else { return nil }
        return states[n]
    }

    func restyle(_ storage: NSTextStorage, edited: NSRange) {
        let text = storage.string as NSString
        let length = text.length
        lastStyledLines = 0
        guard length > 0 else { return }
        storage.beginEditing()
        defer { storage.endEditing() }
        let composing = isComposing()
        let stopAfter = NSMaxRange(edited)
        var location = text.lineRange(for: NSRange(location: min(edited.location, length), length: 0)).location
        // the line above is outside the edit: the state it ends in is still on its characters
        var current: BlockState = location == 0 ? .normal : (state(storage, .fwEndState, at: location - 1) ?? .normal)
        var units: [UInt16] = []
        while location < length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            // past the edit, a line that already starts in this state has the right colours, and so has all below it
            if start >= stopAfter, start > edited.location, state(storage, .fwStartState, at: start) == current { break }
            let lineRange = NSRange(location: start, length: end - start)
            units = [UInt16](repeating: 0, count: contentsEnd - start)
            if !units.isEmpty { text.getCharacters(&units, range: NSRange(location: start, length: contentsEnd - start)) }
            let styled = MarkdownStyler.style(units, state: current, isFirstLine: start == 0)
            states[styled.endState.code] = styled.endState
            apply(styled, startState: current, to: storage, line: lineRange, composing: composing)
            lastStyledLines += 1
            current = styled.endState
            location = end
        }
    }

    private func apply(_ styled: StyledLine, startState: BlockState, to storage: NSTextStorage, line: NSRange, composing: Bool) {
        var base: [NSAttributedString.Key: Any] = [
            .font: theme.regular, .foregroundColor: Theme.text,
            .paragraphStyle: paragraphStyle(hanging: styled.hangingColumns),
            .fwStartState: startState.code, .fwEndState: styled.endState.code,
        ]
        let inCode = styled.flags.first?.contains(.codeBlock) ?? (startState != .normal && startState != .frontmatter)
        if inCode { base[.fwCodeBlock] = true }
        if composing {
            storage.addAttributes(base, range: line)
            if !inCode { storage.removeAttribute(.fwCodeBlock, range: line) }
            storage.removeAttribute(.fwInlineCode, range: line)
        } else {
            storage.setAttributes(base, range: line)
        }
        // runs of equal flags
        var i = 0
        let flags = styled.flags
        while i < flags.count {
            var j = i + 1
            while j < flags.count, flags[j] == flags[i] { j += 1 }
            let f = flags[i]
            if !f.isEmpty {
                var attrs: [NSAttributedString.Key: Any] = [.font: theme.font(for: f), .foregroundColor: theme.color(for: f)]
                if f.contains(.strike) || f.contains(.done) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attrs[.strikethroughColor] = Theme.mark
                }
                if f.contains(.code), !f.contains(.codeBlock) { attrs[.fwInlineCode] = true }
                storage.addAttributes(attrs, range: NSRange(location: line.location + i, length: j - i))
            }
            i = j
        }
    }
}
