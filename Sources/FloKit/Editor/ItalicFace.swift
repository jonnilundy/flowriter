import AppKit

extension EditorTheme {
    /// Flowriter: the italic face of `font` when its family has one (upstream drew italic upright
    /// when the family had an italic face and only slanted families without one).
    func italicFont(_ font: NSFont) -> NSFont? {
        let conv = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        return conv.fontDescriptor.symbolicTraits.contains(.italic) ? conv : nil
    }
}
