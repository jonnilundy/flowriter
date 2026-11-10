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

    public var columnWidth: CGFloat { (CGFloat(columns) * charWidth).rounded(.up) }

    public func font(for flags: StyleFlags) -> NSFont {
        switch (flags.contains(.bold), flags.contains(.italic)) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        case (false, false): return regular
        }
    }

    // MARK: colours (warm neutrals, one accent; each follows the window's light or dark appearance)

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    private static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
    }
    private static func ink(_ alpha: CGFloat) -> NSColor { dynamic(hex(0x1F1C18, alpha), hex(0xECE6DA, alpha)) }

    public static let background = dynamic(hex(0xF4F1EA), hex(0x1B1A18))
    public static let drawerBackground = dynamic(hex(0xEDE9E0), hex(0x211F1D))
    public static let hairline = ink(0.10)
    public static let text = ink(0.86)
    public static let heading = ink(1)
    public static let secondary = ink(0.58)
    public static let mark = ink(0.34)
    public static let accent = dynamic(hex(0xB4532A), hex(0xE08A5C))
    public static let codeText = ink(0.78)
    public static let codeBackground = ink(0.055)
    public static let selection = dynamic(hex(0xB4532A, 0.22), hex(0xE08A5C, 0.32))

    public func color(for flags: StyleFlags) -> NSColor {
        // a heading's hashes carry the accent: the one place where structure is loud
        if flags.contains(.headingMark) { return Theme.accent }
        if flags.contains(.meta) || flags.contains(.mark) { return Theme.mark }
        if flags.contains(.url) { return Theme.mark }
        if flags.contains(.listMarker) || flags.contains(.link) { return Theme.accent }
        if flags.contains(.code) { return Theme.codeText }
        if flags.contains(.done) || flags.contains(.strike) || flags.contains(.quote) { return Theme.secondary }
        if flags.contains(.heading) { return Theme.heading }
        return Theme.text
    }
}
