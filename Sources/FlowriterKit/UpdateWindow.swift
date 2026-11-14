import AppKit

/// Flowriter > Check for Updates: one small window that checks the release feed, shows what is
/// new, and on "Install and Relaunch" downloads the new version, checks it, quits the normal way
/// (unsaved notes are kept as drafts) and lets a helper swap the app and reopen it.
@MainActor
public final class UpdateWindowController: NSWindowController {
    public static let shared = UpdateWindowController()

    enum State: Equatable {
        case checking
        case upToDate
        case available(Release)
        case working(String)
        case failed(String, Release?)
    }

    private static let width: CGFloat = 460
    private static let inset: CGFloat = 28
    private(set) var state: State = .checking { didSet { render(); report() } }
    private var task: Task<Void, Never>?
    /// Install as soon as a newer version is found, without asking (`--update-now`).
    public static var installRightAway = false

    private init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
                                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Software Update"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.background
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc public func checkForUpdates(_ sender: Any?) {
        show()
        if case .working = state, task != nil { return }
        check()
    }

    private func show() {
        if window?.isVisible != true { render(); window?.center() }
        if AppDelegate.offScreen { window?.orderFront(nil) } else { window?.makeKeyAndOrderFront(nil) }
    }

    private func check() {
        task?.cancel()
        state = .checking
        task = Task { [weak self] in
            do {
                let release = try await Updates.latest()
                guard let self, !Task.isCancelled else { return }
                if Updates.isNewer(release.version, than: Updates.currentVersion) {
                    self.state = .available(release)
                    if Self.installRightAway { self.install(release) }
                } else {
                    self.state = .upToDate
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(String(describing: error), nil)
            }
        }
    }

    private func install(_ release: Release) {
        guard case let .installable(destination) = Updates.place(of: Bundle.main.bundleURL) else {
            state = .failed(Self.cannotInstall(Updates.place(of: Bundle.main.bundleURL)), release)
            return
        }
        state = .working("Downloading and checking \(Updates.display(release.version))…")
        task?.cancel()
        task = Task { [weak self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flowriter-update-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let app = try await Updates.stage(release, current: destination, in: folder)
                guard let self, !Task.isCancelled else { try? FileManager.default.removeItem(at: folder); return }
                self.state = .working("Quitting to install…")
                try Updates.swapAfterQuit(new: app, into: destination, folder: folder, pid: getpid(), relaunch: true,
                                          arguments: AppDelegate.offScreen ? ["--offscreen"] : [])
                NSApp.terminate(nil)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                guard let self, !Task.isCancelled else { return }
                self.state = .failed(String(describing: error), release)
            }
        }
    }

    static func cannotInstall(_ place: Updates.Place) -> String {
        switch place {
        case .installable: return ""
        case .notAnApp: return "This build does not run from Flowriter.app, so it cannot replace itself."
        case let .readOnly(url): return "Flowriter cannot write to \(url.deletingLastPathComponent().path). Download the new version and move it there yourself."
        case .translocated: return "macOS runs this copy from a read-only place because it was never moved. Move Flowriter.app to Applications, open it from there, and check again."
        }
    }

    // MARK: actions

    @objc private func installPressed() { if case let .available(release) = state { install(release) } }
    @objc private func openPage() {
        switch state {
        case let .available(release), let .failed(_, release?): NSWorkspace.shared.open(release.page)
        default: NSWorkspace.shared.open(URL(string: "https://github.com/jonnilundy/flowriter/releases")!)
        }
        close()
    }
    @objc private func cancelPressed() {
        task?.cancel()
        task = nil
        close()
    }

    public override func close() {
        if case .working = state { task?.cancel(); task = nil }
        super.close()
    }

    // MARK: layout

    private func render() {
        guard let window else { return }
        let width = Self.width, inset = Self.inset, textWidth = width - 2 * inset
        var title = "", message = "", notes: String?
        var buttons: [SheetButton] = []
        switch state {
        case .checking:
            title = "Checking for updates…"
            message = "You have Flowriter \(Updates.display(Updates.currentVersion))."
            buttons = [SheetButton("Cancel", primary: false, target: self, action: #selector(cancelPressed))]
        case .upToDate:
            title = "Flowriter is up to date"
            message = "\(Updates.display(Updates.currentVersion)) is the newest version."
            buttons = [SheetButton("OK", primary: true, target: self, action: #selector(cancelPressed))]
        case let .available(release):
            title = "Flowriter \(Updates.display(release.version)) is available"
            notes = release.notes.isEmpty ? nil : release.notes
            let place = Updates.place(of: Bundle.main.bundleURL)
            if case .installable = place, release.zip != nil {
                message = "You have \(Updates.display(Updates.currentVersion)). Installing quits Flowriter and opens it again. Unsaved notes come back."
                buttons = [SheetButton("Later", primary: false, target: self, action: #selector(cancelPressed)),
                           SheetButton("Install and Relaunch", primary: true, target: self, action: #selector(installPressed))]
            } else {
                message = release.zip == nil ? "The release has no app to download." : Self.cannotInstall(place)
                buttons = [SheetButton("Later", primary: false, target: self, action: #selector(cancelPressed)),
                           SheetButton("Open Download Page", primary: true, target: self, action: #selector(openPage))]
            }
        case let .working(what):
            title = what
            message = "Flowriter quits and opens again when the new version is ready."
            buttons = [SheetButton("Cancel", primary: false, target: self, action: #selector(cancelPressed))]
        case let .failed(why, _):
            title = "Could not update"
            message = why
            buttons = [SheetButton("OK", primary: false, target: self, action: #selector(cancelPressed)),
                       SheetButton("Open Download Page", primary: true, target: self, action: #selector(openPage))]
        }

        var views: [NSView] = []
        var y: CGFloat = 20   // laid out bottom up
        var x = width - inset + SheetButton.pad
        for button in buttons.reversed() {
            x -= button.frame.width
            button.frame.origin = NSPoint(x: x, y: y)
            x -= 6
            views.append(button)
        }
        if let last = buttons.last { last.keyEquivalent = "\r" }
        if buttons.count > 1 { buttons[0].keyEquivalent = "\u{1B}" }
        y += 28 + 20

        if let notes {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets()
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: 10))
            text.isEditable = false
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 0, height: 0)
            text.textContainer?.lineFragmentPadding = 0
            text.textContainer?.widthTracksTextView = true
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 8
            let lines = notes.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            text.textStorage?.setAttributedString(NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
                .font: Theme.mono(12, .regular), .foregroundColor: Theme.text, .paragraphStyle: style]))
            text.layoutManager?.ensureLayout(for: text.textContainer!)
            let needed = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0).rounded(.up)
            let height = min(220, max(20, needed))
            text.frame.size.height = max(height, needed)
            text.isVerticallyResizable = true
            scroll.documentView = text
            scroll.frame = NSRect(x: inset, y: y, width: textWidth, height: height)
            views.append(scroll)
            y += height + 16
        }

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Theme.mono(12, .regular)
        messageLabel.textColor = Theme.secondary
        messageLabel.preferredMaxLayoutWidth = textWidth
        let messageHeight = messageLabel.sizeThatFits(NSSize(width: textWidth, height: 1000)).height.rounded(.up)
        messageLabel.frame = NSRect(x: inset, y: y, width: textWidth, height: messageHeight)
        messageLabel.identifier = NSUserInterfaceItemIdentifier("update-message")
        views.append(messageLabel)
        y += messageHeight + 10

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.mono(13, .semibold)
        titleLabel.textColor = Theme.heading
        titleLabel.frame = NSRect(x: inset, y: y, width: textWidth, height: 18)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("update-title")
        views.append(titleLabel)
        y += 18 + 44   // room for the title bar

        let size = NSRect(x: 0, y: 0, width: width, height: y)
        let content = NSView(frame: size)
        views.forEach(content.addSubview)
        // the window keeps its top edge; the new content size is read before contentView takes the old one
        let top = window.frame.maxY
        var frame = window.frameRect(forContentRect: size)
        frame.origin = NSPoint(x: window.frame.minX, y: top - frame.height)
        window.contentView = content
        window.setFrame(frame, display: true)
    }

    /// `--update-now` runs from a script: each step is printed.
    private func report() {
        guard Self.installRightAway else { return }
        switch state {
        case .checking: print("UPDATE checking")
        case .upToDate: print("UPDATE up-to-date \(Updates.display(Updates.currentVersion))")
        case let .available(r): print("UPDATE available \(Updates.display(r.version))")
        case let .working(what): print("UPDATE \(what)")
        case let .failed(why, _): print("UPDATE failed: \(why)")
        }
        fflush(stdout)
    }
}
