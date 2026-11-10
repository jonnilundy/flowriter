import AppKit

/// Fonts, colours and the line grid. One monospaced family at one size: regular, bold and italic
/// have the same advance, so no style can change where a line wraps.
public struct Theme {
    public static let fontSizeKey = "FlowriterFontSize"
    public static let defaultFontSize: CGFloat = 15

    public let fontSize: CGFloat
    public let regular: NSFont
    public let bold: NSFont
    public let italic: NSFont
    public let boldItalic: NSFont
    /// Advance of one character.
    public let charWidth: CGFloat
    /// Height of every line: text, blank, heading, code.
    public let lineHeight: CGFloat
    /// From the top of a line to the text baseline.
    public let baseline: CGFloat
    /// Text column width in characters.
    public var columns = 66

    public init(fontSize: CGFloat = Theme.defaultFontSize) {
        self.fontSize = fontSize
        regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let manager = NSFontManager.shared
        let slanted = manager.convert(regular, toHaveTrait: .italicFontMask)
        let boldSlanted = manager.convert(bold, toHaveTrait: .italicFontMask)
        let width = ("0" as NSString).size(withAttributes: [.font: regular]).width
        func sameWidth(_ f: NSFont) -> Bool { abs(("0" as NSString).size(withAttributes: [.font: f]).width - width) < 0.01 }
        italic = sameWidth(slanted) ? slanted : regular
        boldItalic = sameWidth(boldSlanted) ? boldSlanted : bold
        charWidth = width
        lineHeight = (fontSize * 1.75).rounded()
        let box = regular.ascender - regular.descender
        baseline = ((lineHeight - box) / 2 + regular.ascender).rounded()
    }

    public static var stored: Theme {
        let size = UserDefaults.standard.double(forKey: fontSizeKey)
        return Theme(fontSize: size >= 9 && size <= 40 ? CGFloat(size) : defaultFontSize)
    }

    /// The notes drawer's theme for a page at this size: the same face, a step smaller.
    public var notes: Theme { Theme(fontSize: max(9, (fontSize * 0.87).rounded())) }

    public var columnWidth: CGFloat { (CGFloat(columns) * charWidth).rounded(.up) }
    /// The least room between the text and an edge of its area (the window, the drawer). It grows
    /// with the text size, so bigger text never runs up against an edge.
    public var margin: CGFloat { max(32, (3 * charWidth).rounded()) }
    /// Room above the first line.
    public var topMargin: CGFloat { max(48, (1.8 * lineHeight).rounded()) }

    public func font(for flags: StyleFlags) -> NSFont {
        switch (flags.contains(.bold), flags.contains(.italic)) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        case (false, false): return regular
        }
    }

    // MARK: colours

    // A candlelit palette on a near-black page: bone text, dust for what is quiet, and a few
    // colours with a job each. Every text colour is at least 7:1 on the dark page (marks, which
    // are meant to recede, are 3.6:1). Each colour follows the window's light or dark appearance.

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    private static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    public static let background = dynamic(hex(0xF4F1EA), hex(0x181A1C))
    public static let hairline = dynamic(hex(0x302A24, 0.10), hex(0xD8D0C2, 0.09))
    /// Bone: running text.
    public static let text = dynamic(hex(0x302A24), hex(0xD8D0C2))
    /// Headings and bold: the same bone, brighter.
    public static let heading = dynamic(hex(0x1D1915), hex(0xEEEAE0))
    /// Dust: quotes, finished tasks, struck text, the status in the top bar.
    public static let secondary = dynamic(hex(0x6D6359), hex(0xABA398))
    /// Markdown's own characters, frontmatter, link addresses.
    public static let mark = dynamic(hex(0x978D7F), hex(0x787166))
    /// Candle flame: heading hashes, list markers, the caret, the selection.
    public static let accent = dynamic(hex(0xA35026), hex(0xED954D))
    /// Lantern: italic text.
    public static let emphasis = dynamic(hex(0x7F5816), hex(0xEDCA70))
    /// Moss: code.
    public static let codeText = dynamic(hex(0x4B632A), hex(0xBECFA2))
    /// Moonlight: links.
    public static let link = dynamic(hex(0x2A677D), hex(0x7FABBA))
    public static let codeBackground = dynamic(hex(0x302A24, 0.055), hex(0xD8D0C2, 0.05))
    public static let selection = dynamic(hex(0xA35026, 0.22), hex(0xED954D, 0.28))

    public func color(for flags: StyleFlags) -> NSColor {
        if flags.contains(.headingMark) || flags.contains(.listMarker) { return Theme.accent }
        if flags.contains(.meta) || flags.contains(.mark) || flags.contains(.url) { return Theme.mark }
        if flags.contains(.link) { return Theme.link }
        if flags.contains(.code) { return Theme.codeText }
        if flags.contains(.done) || flags.contains(.strike) || flags.contains(.quote) { return Theme.secondary }
        if flags.contains(.heading) { return Theme.heading }
        if flags.contains(.italic) { return Theme.emphasis }
        if flags.contains(.bold) { return Theme.heading }
        return Theme.text
    }
}
