import AppKit
import FloCore
import FloKit

/// Flowriter: the writing space. One document per window (the compact window: no sidebar, no
/// tabs, no properties table), a narrow centred monospace column, a quiet word and character
/// count at the top. The app reopens the last document.
/// Hooks: FloApp (startup, menus), ShellRootView (count view), EditorPaneView (theme,
/// frontmatter), ShellModel (Cmd-O). FLO_SPACE=0 runs the upstream shell.
@MainActor
enum FlowriterSpace {
    static var enabled: Bool { FlowriterSettings.enabled }

    /// Column width in characters of the body font (monospace: every character is one `ch`).
    static let columnChars: CGFloat = 66
    /// Top of the first line: below the window buttons and the count, about four lines of air.
    static let topInset: CGFloat = 104

    /// Theme tweaks on top of EditorTheme.from(settings:mode:).
    static func tune(_ t: EditorTheme, values: SettingsValues, mode: ThemeMode) {
        guard enabled else { return }
        // one accent: the theme's (links, selection), not the system blue
        let accent = ThemeTokens(settings: values, mode: mode).accent.ns
        t.accent = accent
        t.selectionOverride = accent.withAlphaComponent(mode == .dark ? 0.32 : 0.22)
        t.maxTextWidth = (columnChars * t.ch).rounded()
        // H2/H3 in the text colour (upstream: one fixed grey for light and dark)
        t.subheadingColor = t.headingColor
    }

    // MARK: launch

    /// The document to open at launch: a file passed in (Finder, `open`), else the last document
    /// that still exists. nil: a folder was passed in, or there is no last document (upstream plan).
    static func startupFile(launchPaths: [String], dataDir: AppDataDirectory, settings: AppSettings) -> String? {
        guard enabled else { return nil }
        let pending = launchPaths.compactMap { PendingOpen.resolve($0, extensions: settings.supportedExtensions) }
        if let first = pending.first { return first.file }
        return RecentFilesStore(appData: dataDir).load().map(\.path).first { WorkspaceFS.isFile($0) }
    }

    // MARK: Cmd-O

    /// Cmd-O in a document window: an Open panel; the chosen file replaces the window's document.
    static func openPanel(_ model: ShellModel) -> Bool {
        guard enabled, model.root == nil else { return false }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = ["md", "markdown", "mdx", "txt"].compactMap { UTTypeShim.type($0) }
        if let current = model.editor.activeFilePath { p.directoryURL = URL(fileURLWithPath: (current as NSString).deletingLastPathComponent) }
        let open = { (url: URL?) in
            guard let path = url?.path else { return }
            model.flushDirtyFiles()
            Task { await model.editor.openCompactFile(path) }
        }
        if let w = NSApp.keyWindow {
            p.beginSheetModal(for: w) { r in if r == .OK { open(p.url) } }
        } else if p.runModal() == .OK {
            open(p.url)
        }
        return true
    }

    // MARK: menus

    /// View > Appearance (System / Light / Dark); File "Go to File…" becomes "Open…" (Cmd-O).
    static func installMenus(in main: NSMenu, focused: @escaping () -> ShellModel?,
                             recents: RecentFilesStore? = nil, openWithoutWindow: @escaping (String) -> Void = { _ in }) {
        guard enabled else { return }
        if let file = main.items.first(where: { $0.title == L("File") })?.submenu,
           let go = file.items.first(where: { $0.title == L("Go to File…") }) {
            go.title = L("Open…")
            if let recents {   // File > Open Recent, right under Open… (OpenRecentMenu.swift)
                OpenRecentMenu.install(in: file, after: go, store: recents, focused: focused, openWithoutWindow: openWithoutWindow)
            }
        }
        if let view = main.items.first(where: { $0.title == L("View") })?.submenu {
            let sub = NSMenu(title: "Appearance")
            for (title, value) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
                let item = ClosureMenuItem(title) {
                    focused()?.setSetting("appearance.theme", .string(value))
                }
                item.representedObject = value
                sub.addItem(item)
            }
            sub.delegate = AppearanceMenuDelegate.shared
            AppearanceMenuDelegate.shared.current = { focused()?.values.raw["appearance.theme"]?.stringValue ?? "system" }
            let top = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
            top.submenu = sub
            view.insertItem(.separator(), at: 0)
            ShortcutHintsView.installMenu(in: view, at: 0)
            view.insertItem(top, at: 0)
        }
    }

    final class AppearanceMenuDelegate: NSObject, NSMenuDelegate {
        static let shared = AppearanceMenuDelegate()
        var current: () -> String = { "system" }
        func menuNeedsUpdate(_ menu: NSMenu) {
            let v = current()
            for i in menu.items { i.state = (i.representedObject as? String) == v ? .on : .off }
        }
    }
}

import UniformTypeIdentifiers
enum UTTypeShim {
    static func type(_ ext: String) -> UTType? { UTType(filenameExtension: ext) }
}

/// The quiet count at the top of a document window: "512 words   3,104 chars". Counts the body
/// (frontmatter left out), once per content change, off the typing path (coalesced flush).
/// Pinned to the window's centre line: the gap between the two counts sits on it, "512 words"
/// ends at its left edge and "3,104 chars" starts at its right edge, so a new digit grows the text
/// outward and nothing already on screen moves when a count gains or loses a digit.
/// It is also the writing tools switch (WritingToolsSwitch.swift): a click flips WritingTools.isOn.
@MainActor
final class FlowriterCountView: FlippedView {
    let model: ShellModel
    private(set) var text = ""
    private(set) var words = "", chars = ""
    private var countedPath: String?
    private var countedContent: String?

    /// The pointer is on the count (brighter text, pointing hand).
    var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    init(model: ShellModel) {
        self.model = model
        super.init(frame: .zero)
        WritingToolsSwitch.install()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Writing tools")
    }
    required init?(coder: NSCoder) { fatalError() }

    // Only the count takes clicks: the rest of the strip stays the window's drag area.
    override func hitTest(_ point: NSPoint) -> NSView? { WritingToolsSwitch.hitTest(self, point) }
    override func mouseDown(with event: NSEvent) {}   // no window drag from the count
    override func mouseUp(with event: NSEvent) { WritingToolsSwitch.clicked(self, event) }
    override func mouseMoved(with event: NSEvent) { hovering = clickRect.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { if !text.isEmpty { addCursorRect(clickRect, cursor: .pointingHand) } }
    override func accessibilityValue() -> Any? { WritingTools.isOn ? "on" : "off" }
    override func accessibilityPerformPress() -> Bool { WritingTools.isOn.toggle(); return true }

    func refresh() {
        guard let p = model.editor.activeFilePath, let f = model.editor.file(p) else { text = ""; needsDisplay = true; return }
        guard p != countedPath || f.content != countedContent else { return }
        countedPath = p; countedContent = f.content
        let body = FlowriterSettings.rawFrontmatter ? Frontmatter.parseDocument(f.content).body : f.content
        let s = DocumentStatsCalculator.stats(body)
        words = "\(FooterMetrics.format(s.words)) \(s.words == 1 ? "word" : "words")"
        chars = "\(FooterMetrics.format(s.characters)) chars"
        text = words + Self.gap + chars
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    var style: TextStyle {
        let size: CGFloat = 11
        return TextStyle(font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular), color: hovering ? WritingToolsSwitch.hoverColor(model.palette_) : model.palette_.textIconMuted)
    }

    static let gap = "   "

    /// Where the two counts start: the gap centred on the view, whatever the digits.
    var origins: (words: CGFloat, chars: CGFloat) {
        let s = style
        let half = (s.width(Self.gap) / 2).rounded()
        let mid = (bounds.width / 2).rounded()
        return (mid - half - s.width(words), mid + half)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !text.isEmpty else { return }
        let s = style
        let lh: CGFloat = 16
        let o = origins, top = (bounds.height - lh) / 2
        s.draw(words, x: o.words, lineTop: top, lineHeight: lh, in: ctx)
        s.draw(chars, x: o.chars, lineTop: top, lineHeight: lh, in: ctx)
    }
}
