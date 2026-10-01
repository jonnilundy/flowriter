import AppKit

/// Flowriter: caret follow scrolls only as far as the caret needs. TextKit 2's
/// NSTextView.scrollRangeToVisible centred the caret line when it left the view (arrow down or
/// Return on the last visible line moved the page by half a window); a code editor moves one line.
extension FloTextView {
    nonisolated(unsafe) public static var minimalCaretFollow = true

    public override func scrollRangeToVisible(_ range: NSRange) {
        guard Self.minimalCaretFollow, let r = rectForScroll(range), let clip = enclosingScrollView?.contentView else {
            super.scrollRangeToVisible(range); return
        }
        let vis = clip.bounds
        var y = vis.minY
        if r.maxY > vis.maxY { y = r.maxY - vis.height }
        if r.minY < y { y = r.minY }
        guard abs(y - vis.minY) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: vis.minX, y: max(0, y)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// The range's first line box in view coordinates, laid out first (no estimates), with a small margin.
    func rectForScroll(_ range: NSRange) -> CGRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let len = (string as NSString).length
        let p = max(0, min(range.location, len))
        guard let loc = tcm.location(tcm.documentRange.location, offsetBy: p) else { return nil }
        let end = tlm.textLayoutFragment(for: loc)?.rangeInElement.endLocation ?? loc
        tlm.ensureLayout(for: NSTextRange(location: tcm.documentRange.location, end: end) ?? tlm.documentRange)
        var rect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, r, _, _ in
            rect = r; return false
        }
        guard var r = rect else { return nil }
        r.origin.x += textContainerOrigin.x; r.origin.y += textContainerOrigin.y
        return r.insetBy(dx: 0, dy: -6)
    }
}
