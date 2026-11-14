import Foundation

/// Control-Command-Up and Down: the whole lines the selection touches swap places with the line
/// above or below. The selection moves with the text. nil at the top or bottom of the text.
public enum MoveLines {
    public static func move(in text: NSString, selection: NSRange, up: Bool) -> TextEdit? {
        let blockStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        // a selection that ends at the start of a line does not take that line along
        var last = NSMaxRange(selection)
        if selection.length > 0, last > blockStart, last <= text.length, isLineStart(text, last) { last -= 1 }
        let blockEnd = NSMaxRange(text.lineRange(for: NSRange(location: min(last, text.length), length: 0)))

        let above: NSRange, below: NSRange
        if up {
            guard blockStart > 0 else { return nil }
            above = text.lineRange(for: NSRange(location: blockStart - 1, length: 0))
            below = NSRange(location: blockStart, length: blockEnd - blockStart)
        } else {
            guard blockEnd < text.length else { return nil }
            above = NSRange(location: blockStart, length: blockEnd - blockStart)
            below = text.lineRange(for: NSRange(location: blockEnd, length: 0))
        }
        let (aText, aEnd) = split(text, above)
        let (bText, bEnd) = split(text, below)
        // the lower part may be the last line with no line break: the break stays at the end
        let out = bText + aEnd + aText + bEnd
        let region = NSRange(location: above.location, length: NSMaxRange(below) - above.location)
        let shift = up ? -above.length : bText.utf16.count + aEnd.utf16.count
        let location = above.location + (up ? 0 : shift) + (selection.location - blockStart)
        let length = min(selection.length, region.location + out.utf16.count - location)
        return TextEdit(range: region, text: out, selection: NSRange(location: location, length: max(0, length)))
    }

    private static func isLineStart(_ text: NSString, _ i: Int) -> Bool {
        i == 0 || text.lineRange(for: NSRange(location: i, length: 0)).location == i
    }

    /// The lines in `range` without their last line break, and that break ("" on the last line).
    private static func split(_ text: NSString, _ range: NSRange) -> (String, String) {
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
        let body = NSRange(location: range.location, length: contentsEnd - range.location)
        return (text.substring(with: body), text.substring(with: NSRange(location: contentsEnd, length: NSMaxRange(range) - contentsEnd)))
    }
}
