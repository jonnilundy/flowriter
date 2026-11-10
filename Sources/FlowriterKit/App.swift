import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let documents = DocumentController()   // the first NSDocumentController made is the shared one

    public override init() { super.init() }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Launch with no file: the last document comes back. Without one, a new empty page.
    public func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if let last = documents.lastDocumentURL {
            documents.openDocument(withContentsOf: last, display: true) { [documents] document, _, _ in
                if document == nil { documents.newDocument(nil) }
            }
            return true
        }
        documents.newDocument(nil)
        return true
    }

    /// Files named on the command line (a build run without a bundle gets no open-file events).
    private var launchFiles: [URL] {
        if let files = Self.launchFiles { return files }
        return CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { launchFiles.isEmpty || !documents.documents.isEmpty }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        for url in launchFiles { documents.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
        if Self.offScreen, !Self.smoke { return }
        guard Self.smoke else { NSApp.activate(ignoringOtherApps: true); return }
        // --smoke: a real launch that takes no focus, reports what came up, and quits
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [documents] in
            let controllers = NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
            let menus = NSApp.mainMenu?.items.map(\.title).joined(separator: ",") ?? "none"
            print("SMOKE documents=\(documents.documents.count) windows=\(controllers.count) visible=\(controllers.filter { $0.window?.isVisible == true }.count) " +
                  "chars=\(controllers.first?.editor.string.utf16.count ?? -1) notesOpen=\(controllers.first?.notesOpen ?? false) menus=\(menus)")
            exit(controllers.isEmpty ? 1 : 0)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static var smoke = false
    /// Windows open far off every screen and the app never takes focus (the test driver).
    public static var offScreen = false
    /// The files to open at launch, in place of the ones named on the command line (the test driver).
    public static var launchFiles: [URL]?

    public static func run(smoke: Bool = false) {
        Self.smoke = smoke
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // off screen: the app may never become active, so it cannot take the keys from the app in use
        app.setActivationPolicy(offScreen || smoke ? .prohibited : .regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let name = "Flowriter"

        let app = submenu(main, name)
        app.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = RecentMenu.shared
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        item(file, "Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift])
        file.addItem(withTitle: "Rename…", action: #selector(NSDocument.rename(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Move To…", action: #selector(NSDocument.move(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Revert To Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")

        let edit = submenu(main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        item(edit, "Move Selection to Notes", #selector(DocumentWindowController.moveSelectionAcross(_:)), "m", [.command, .shift])
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        finder(find, "Find…", .showFindInterface, "f", [.command])
        finder(find, "Find and Replace…", .showReplaceInterface, "f", [.command, .option])
        finder(find, "Find Next", .nextMatch, "g", [.command])
        finder(find, "Find Previous", .previousMatch, "g", [.command, .shift])
        finder(find, "Use Selection for Find", .setSearchString, "e", [.command])
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        let spelling = NSMenu(title: "Spelling")
        spelling.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Spelling", action: nil, keyEquivalent: "").submenu = spelling

        let format = submenu(main, "Format")
        format.addItem(withTitle: "Bold", action: #selector(EditorTextView.toggleBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(EditorTextView.toggleItalic(_:)), keyEquivalent: "i")

        let view = submenu(main, "View")
        item(view, "Show Notes", #selector(DocumentWindowController.toggleNotes(_:)), "o", [.option])
        item(view, "Switch Between Page and Notes", #selector(DocumentWindowController.switchPageAndNotes(_:)), "o", [.option, .shift])
        view.addItem(.separator())
        item(view, "Focus Mode", #selector(DocumentWindowController.toggleFocusMode(_:)), "f", [.command, .shift])
        view.addItem(.separator())
        view.addItem(withTitle: "Bigger Text", action: #selector(DocumentWindowController.biggerText(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller Text", action: #selector(DocumentWindowController.smallerText(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(DocumentWindowController.actualSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu(main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private static func finder(_ menu: NSMenu, _ title: String, _ action: NSTextFinder.Action, _ key: String, _ mods: NSEvent.ModifierFlags) {
        let i = item(menu, title, #selector(NSTextView.performTextFinderAction(_:)), key, mods)
        i.tag = action.rawValue
    }
}

/// File > Open Recent, filled from the system's list each time it opens.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {
    static let shared = RecentMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
        }
        if menu.items.isEmpty == false { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}
