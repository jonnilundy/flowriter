import AppKit

/// The cursor of chrome that sits over the page.
///
/// The page's NSTextView registers an I-beam cursor rect over its whole frame. A view above it that
/// registers no cursor rect of its own does not stop that: the pointer shows the I-beam over a
/// button. A view that wants the arrow or the pointing hand says where in `pointerRects`, and its
/// `resetCursorRects` forwards to `PointerCursor.reset`. Views that can be created, moved, resized
/// or hidden after the window is up also call `PointerCursor.invalidate` on those changes, so the
/// rect follows the view.
@MainActor
protocol PointerCursorProviding: NSView {
    /// The cursor rects of this view, in its own coordinates. Empty: the view takes no cursor.
    var pointerRects: [PointerCursor.Rect] { get }
}

enum PointerCursor {
    struct Rect: Equatable {
        var rect: CGRect
        var cursor: NSCursor
    }

    /// The whole of `bounds`, as a pointing hand.
    static func hand(_ bounds: CGRect) -> [Rect] { [Rect(rect: bounds, cursor: .pointingHand)] }

    /// The whole of `bounds`, as the arrow (a label over the page: the page's I-beam must not show).
    static func arrow(_ bounds: CGRect) -> [Rect] { [Rect(rect: bounds, cursor: .arrow)] }

    /// `NSView.resetCursorRects` for a provider. `add` is the sink (tests record into it).
    @MainActor
    static func reset(_ view: some PointerCursorProviding, using add: ((CGRect, NSCursor) -> Void)? = nil) {
        for r in view.pointerRects where !r.rect.isEmpty {
            if let add { add(r.rect, r.cursor) } else { view.addCursorRect(r.rect, cursor: r.cursor) }
        }
    }

    /// The view's rects changed (it moved, resized, was hidden or shown, or its state changed).
    static func invalidate(_ view: NSView) { view.window?.invalidateCursorRects(for: view) }
}
