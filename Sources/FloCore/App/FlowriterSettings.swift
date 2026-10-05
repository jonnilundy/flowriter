import Foundation

/// Flowriter: its writing-space defaults, layered under the user's config (a key the user set
/// still wins). Off unless the app turns it on at start (FlowriterDefaults.apply), so tests and
/// the web parity fixtures keep upstream Flo State defaults.
public enum FlowriterSettings {
    nonisolated(unsafe) public static var enabled = false
    /// The editor holds the whole file, frontmatter included (shown as dim raw text), instead of
    /// splitting the frontmatter into the properties table.
    nonisolated(unsafe) public static var rawFrontmatter = false

    /// Warm neutrals, not pure black or white; one accent (a muted terracotta).
    public static let defaults: [String: ConfigValue] = [
        "fonts.editor": .string("\"SF Mono\", ui-monospace, Menlo, monospace"),
        "editor.font-size": .number(15),
        "editor.line-height": .number(1.75),
        "editor.heading-space-before": .number(8),
        "editor.heading-space-after": .number(4),
        "editor.bullet-spacing": .number(4),
        "editor.show-outline": .bool(false),
        "editor.auto-insert-daily-heading": .bool(false),
        "editor.jump-to-bottom-after-minutes": .number(0),
        "appearance.sidebar-visible": .bool(false),
        "theme.light.accent": .string("#B4532A"),
        "theme.light.background": .string("#F4F1EA"),
        "theme.light.foreground": .string("#1F1C18"),
        "theme.light.heading-color": .string("#1F1C18"),
        "theme.light.translucent": .number(0),
        "theme.light.contrast": .number(20),
        "theme.dark.accent": .string("#E08A5C"),
        "theme.dark.background": .string("#1B1A18"),
        "theme.dark.foreground": .string("#ECE6DA"),
        "theme.dark.heading-color": .string("#F3EEE4"),
        "theme.dark.translucent": .number(0),
        "theme.dark.contrast": .number(16),
    ]

    static func defaultValue(_ key: String) -> ConfigValue? { enabled ? defaults[key] : nil }
}
