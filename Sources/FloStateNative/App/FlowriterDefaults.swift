import Foundation
import FloCore
import FloKit

/// Flowriter: where its defaults differ from upstream Flo State. Applied once at process start
/// (main.swift), so the GUI, the VM self tests and --perf all run the same editor.
///   FLO_MARKS=hide       upstream live preview (marks hide off the caret line), for baselines
///   FLO_BLANK=short      upstream blank lines (1em tall instead of one text line), for baselines
///   FLO_TYPEWRITER=1     upstream typewriter scrolling (caret kept at 70% of the window)
///   FLO_SPACE=0          upstream shell and settings defaults (sidebar, tabs, properties table)
///   FLO_CARET_FOLLOW=native   NSTextView's own scroll to caret (centres the caret line), for baselines
enum FlowriterDefaults {
    static let env = ProcessInfo.processInfo.environment

    static func apply() {
        // the bundled app takes over the defaults of builds made before the bundle id changed
        if Bundle.main.bundleIdentifier == ForkIdentity.bundleID { DefaultsMigration.run() }
        // marks stay visible on every line: moving the caret never reflows text (integrity suite)
        RenderPlanner.marksAlwaysVisible = env["FLO_MARKS"] != "hide"
        // the reading view (Markdown view toggle) as the user left it (ViewToggles.swift)
        ViewToggles.restore()
        // one line grid: a blank line is as tall as a text line, so typing into it moves nothing
        EditorController.fullHeightBlankLines = env["FLO_BLANK"] != "short"
        // the writing space: one document per window, narrow monospace column, raw frontmatter (FlowriterSpace.swift)
        FlowriterSettings.enabled = env["FLO_SPACE"] != "0"
        FlowriterSettings.rawFrontmatter = FlowriterSettings.enabled
        // caret follow scrolls one line, not half a window (CaretFollow.swift)
        MainActor.assumeIsolated {
            FloTextView.minimalCaretFollow = env["FLO_CARET_FOLLOW"] != "native"
            NoWritingTools.install()   // no AI: Writing Tools off in field editors and menus
        }
    }

    /// Off: recentring on every key moved the whole page under the caret (a new visual line,
    /// a heading's taller line, the first key after a click). The View menu toggle still works.
    static var typewriterScrolling: Bool { env["FLO_TYPEWRITER"] == "1" }
}
