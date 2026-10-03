import AppKit
import FloCore

/// Flowriter: the view toggle at the top of a document window (ViewTogglesBar.swift draws it,
/// the View menu has it):
///   - tracking: the caret line stays on the vertical centre of the view, like a typewriter
///     (CaretFollow.swift scrolls, EditorController.layoutColumn pads). Off = the page moves only
///     as far as the caret needs.
///   - readingView: Markdown marks hidden on every line, the caret line included
///     (RenderPlanner.readingView, ReadingView.swift). Off = the writing view, marks visible.
/// App wide and persisted in UserDefaults (FLO_VIEW_DEFAULTS=<suite> picks another domain: the VM
/// tests use their own, so a run never leaves a view switched for the next suite). The
/// alternatives decorations (squiggle, dots, margin line) have no toggle: they show whenever the
/// writing tools are on.
@MainActor
public enum ViewToggles {
    public static let didChange = Notification.Name("FlowriterViewTogglesDidChange")
    /// The old dots toggle's stored value: `restore()` drops it (decorations are always shown now).
    public static let retiredAlternativesKey = "FlowriterShowAlternatives"
    public static let readingKey = "FlowriterReadingView"
    public static let trackingKey = "FlowriterTrackingMode"

    public static var defaults: UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["FLO_VIEW_DEFAULTS"], let d = UserDefaults(suiteName: suite) { return d }
        return .standard
    }

    /// The reading view (default off: the writing view, marks visible).
    public static var readingView: Bool {
        get { defaults.bool(forKey: readingKey) }
        set {
            guard newValue != readingView || newValue != RenderPlanner.readingView else { return }
            defaults.set(newValue, forKey: readingKey)
            RenderPlanner.readingView = newValue
            for c in editors() { c.viewModeChanged() }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Tracking mode (default off).
    public static var tracking: Bool {
        get { defaults.bool(forKey: trackingKey) }
        set {
            guard newValue != tracking || newValue != FloTextView.trackingMode else { return }
            defaults.set(newValue, forKey: trackingKey)
            FloTextView.trackingMode = newValue
            for c in editors() { c.trackingChanged() }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// At process start, before any editor renders: the persisted view.
    nonisolated public static func restore() {
        MainActor.assumeIsolated {
            FloTextView.trackingMode = defaults.bool(forKey: trackingKey)
            defaults.removeObject(forKey: retiredAlternativesKey)   // a stored "hidden" must not outlive the toggle
            RenderPlanner.readingView = defaults.bool(forKey: readingKey)
        }
    }

    /// Every editor in the app's windows.
    static func editors() -> [EditorController] {
        var out: [EditorController] = []
        func walk(_ v: NSView) {
            if let tv = v as? FloTextView, let c = tv.controller { out.append(c); return }
            v.subviews.forEach(walk)
        }
        for w in NSApp?.windows ?? [] { if let v = w.contentView { walk(v) } }
        return out
    }
}

extension EditorController {
    /// Tracking mode switched: pad the page for it, then put the caret line on the centre (on) or
    /// leave the page where it is (off, padding back to normal).
    public func trackingChanged() {
        layoutColumn()
        textView.refreshDocumentHeight()
        if FloTextView.trackingMode { textView.scrollRangeToVisible(NSRange(location: state.selection.main.head, length: 0)) }
        textView.needsDisplay = true
    }

    /// The reading view switched: render every line again (one reflow), keeping the visual line
    /// that was at the top of the viewport at the same height on screen.
    public func viewModeChanged() {
        let anchor = topAnchor()
        render(force: true)
        layoutColumn()
        ensureFullLayout()
        textView.refreshDocumentHeight()
        if let a = anchor { scrollToAnchor(a) }
        textView.needsDisplay = true
    }

    /// The first visual line at the top of the viewport: its first character and how far its top
    /// sits from the top of the view (text container points; negative when below it).
    public func topAnchor() -> (pos: Int, offset: CGFloat)? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let clipY = scrollView.contentView.bounds.minY - textView.textContainerOrigin.y
        var found: (Int, CGFloat)?
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { f in
            let fr = f.layoutFragmentFrame
            guard fr.maxY > clipY else { return true }
            let start = tcm.offset(from: tcm.documentRange.location, to: f.rangeInElement.location)
            for lf in f.textLineFragments {
                let top = fr.minY + lf.typographicBounds.minY
                if top + lf.typographicBounds.height > clipY || lf === f.textLineFragments.last {
                    found = (start + lf.characterRange.location, top - clipY)
                    return false
                }
            }
            return false
        }
        return found
    }

    /// Top of the visual line holding `pos` (text container points).
    public func lineTop(at pos: Int) -> CGFloat? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: max(0, min(pos, state.doc.length))),
              let f = tlm.textLayoutFragment(for: loc) else { return nil }
        let start = tcm.offset(from: tcm.documentRange.location, to: f.rangeInElement.location)
        let fr = f.layoutFragmentFrame
        let rel = pos - start
        let lines = f.textLineFragments
        guard let lf = lines.last(where: { $0.characterRange.location <= rel && $0.characterRange.length > 0 }) ?? lines.first else { return fr.minY }
        return fr.minY + lf.typographicBounds.minY
    }

    /// Scroll so the line holding `a.pos` sits `a.offset` below the top of the view again.
    public func scrollToAnchor(_ a: (pos: Int, offset: CGFloat)) {
        guard let top = lineTop(at: a.pos) else { return }
        let clip = scrollView.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let y = min(maxY, max(0, top - a.offset + textView.textContainerOrigin.y))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}
