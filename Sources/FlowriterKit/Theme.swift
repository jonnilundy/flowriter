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
        regular = Theme.mono(fontSize, .regular)
        bold = Theme.mono(fontSize, .semibold)
        let slanted = Theme.slanted(regular)
        let boldSlanted = Theme.slanted(bold)
        let width = ("0" as NSString).size(withAttributes: [.font: regular]).width
        func sameWidth(_ f: NSFont) -> Bool { abs(("0" as NSString).size(withAttributes: [.font: f]).width - width) < 0.01 }
        italic = sameWidth(slanted) ? slanted : regular
        boldItalic = sameWidth(boldSlanted) ? boldSlanted : bold
        charWidth = width
        lineHeight = (fontSize * 1.75).rounded()
        let box = regular.ascender - regular.descender
        baseline = ((lineHeight - box) / 2 + regular.ascender).rounded()
    }

    /// Paper Mono (Resources/Fonts, SIL OFL 1.1) at a size and weight, for the page and every
    /// piece of the app's own chrome. Falls back to the system monospaced font when the files
    /// are missing.
    public static func mono(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let face = weight >= .semibold ? "SemiBold" : weight >= .medium ? "Medium" : "Regular"
        if fontsRegistered, let font = NSFont(name: "PaperMono-\(face)", size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Paper Mono has no italic. A sheared copy of the upright face slants without changing
    /// the advance, so the line grid holds.
    static func slanted(_ font: NSFont) -> NSFont {
        let real = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        if real.fontDescriptor.symbolicTraits.contains(.italic) { return real }
        let size = font.pointSize
        let shear = AffineTransform(m11: size, m12: 0, m21: 0.2 * size, m22: size, tX: 0, tY: 0)
        return NSFont(descriptor: font.fontDescriptor, textTransform: shear) ?? font
    }

    /// The bundled fonts are registered for this process only. The .app carries them in
    /// Contents/Resources/Fonts (scripts/bundle.sh); `swift run`, the tests and the drive tool
    /// read them from the repo's Resources/Fonts.
    private static let fontsRegistered: Bool = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Fonts").standardized
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), repo].compactMap { $0 }
        guard let dir = dirs.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("PaperMono-Regular.ttf").path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return false }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: "PaperMono-Regular", size: 12) != nil
    }()

    public static var stored: Theme {
        let size = UserDefaults.standard.double(forKey: fontSizeKey)
        return Theme(fontSize: size >= 9 && size <= 40 ? CGFloat(size) : defaultFontSize)
    }

    public static let notesDeltaKey = "FlowriterNotesSizeDelta"
    /// How many points the notes' text differs from the page's (View > Smaller Notes Text).
    public static var notesDelta: Int {
        get { UserDefaults.standard.object(forKey: notesDeltaKey) == nil ? -4 : min(4, max(-10, UserDefaults.standard.integer(forKey: notesDeltaKey))) }
        set { UserDefaults.standard.set(min(4, max(-10, newValue)), forKey: notesDeltaKey) }
    }

    /// The notes drawer's theme for a page at this size: the same face, smaller by `notesDelta`.
    public var notes: Theme { Theme(fontSize: max(9, fontSize + CGFloat(Theme.notesDelta))) }

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
    /// Headings: the same bone, brighter.
    public static let heading = dynamic(hex(0x1D1915), hex(0xEEEAE0))
    /// Dust: quotes, finished tasks, struck text, the status in the top bar.
    public static let secondary = dynamic(hex(0x6D6359), hex(0xABA398))
    /// Markdown's own characters, frontmatter, link addresses.
    public static let mark = dynamic(hex(0x978D7F), hex(0x787166))
    /// Candle flame: heading hashes, list markers, the caret, the selection.
    public static let accent = dynamic(hex(0xA35026), hex(0xED954D))
    /// Rose: italic text.
    public static let emphasis = dynamic(hex(0x85303F), hex(0xE9A6B0))
    /// Lantern: bold text.
    public static let strong = dynamic(hex(0x7F5816), hex(0xEDCA70))
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
        if flags.contains(.bold) { return Theme.strong }
        return Theme.text
    }
}
