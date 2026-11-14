import AppKit

/// Light, dark, or whatever the system is set to.
public enum Appearance: String, CaseIterable {
    case system, light, dark

    public static let key = "FlowriterAppearance"

    @MainActor public static var stored: Appearance {
        get { UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system }
        set {
            if newValue == .system { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
            newValue.apply()
        }
    }

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor public func apply() { NSApp.appearance = appearance }
}

/// A flat button for the Settings window. A chosen one has a quiet plate behind it.
final class ChoiceButton: NSButton {
    var isOn = false { didSet { needsDisplay = true } }
    var leftAligned = false
    private var pressed = false

    convenience init(_ title: String, id: String, width: CGFloat? = nil, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.identifier = NSUserInterfaceItemIdentifier(id)
        self.target = target
        self.action = action
        isBordered = false
        font = Theme.mono(12, .regular)
        let text = (title as NSString).size(withAttributes: [.font: font!])
        frame.size = NSSize(width: width ?? (text.width + 24).rounded(.up), height: 26)
        setAccessibilityLabel(title)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn && !leftAligned {
            let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            Theme.codeBackground.setFill(); plate.fill()
            Theme.hairline.setStroke(); plate.stroke()
        }
        let base = isOn ? Theme.heading : Theme.secondary
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(12, isOn ? .semibold : .regular),
            .foregroundColor: base.withAlphaComponent(pressed ? 0.55 : 1), .paragraphStyle: paragraph]
        let size = (title as NSString).size(withAttributes: attributes)
        var x = max(0, ((bounds.width - size.width) / 2).rounded())
        if leftAligned {
            x = 18
            if isOn {
                Theme.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: (bounds.height / 2 - 3).rounded(), width: 6, height: 6)).fill()
            }
        }
        (title as NSString).draw(with: NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width - x, height: size.height),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true; needsDisplay = true
        super.mouseDown(with: event)   // returns when the button is let go
        pressed = false; needsDisplay = true
    }
}

/// The Settings window stays where it is put off screen, like a document window.
final class SettingsWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        AppDelegate.offScreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(AppDelegate.parked(frameRect), display: flag)
    }
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(AppDelegate.parked(NSRect(origin: point, size: frame.size)).origin)
    }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Flowriter > Settings: every setting in one window. Each control writes its preference at once,
/// and the window shows a change made anywhere else (a menu, a key) as it happens.
@MainActor
public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    private static let width: CGFloat = 440
    private static let inset: CGFloat = 28
    private static let controlsX: CGFloat = 180
    private static let rowHeight: CGFloat = 40

    private let root = RootView()
    private var appearanceButtons: [ChoiceButton] = []
    private var focusButtons: [ChoiceButton] = []
    private let textSize = NSTextField(labelWithString: "")
    private let notesSize = NSTextField(labelWithString: "")
    private var locationViews: [NSView] = []

    private init() {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.background
        window.isReleasedWhenClosed = false
        window.contentView = root
        super.init(window: window)
        build()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window?.isVisible == true { self?.refresh() } }
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc public func show(_ sender: Any?) {
        refresh()
        if window?.isVisible != true { window?.center() }
        if AppDelegate.offScreen { window?.orderFront(nil) } else { window?.makeKeyAndOrderFront(nil) }
    }

    // MARK: layout

    private func label(_ text: String, dim: Bool = true) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.mono(12, .regular)
        l.textColor = dim ? Theme.secondary : Theme.text
        l.sizeToFit()
        return l
    }

    private func place(_ view: NSView, x: CGFloat, row y: CGFloat) {
        view.setFrameOrigin(NSPoint(x: x, y: (y + (Self.rowHeight - view.frame.height) / 2).rounded()))
        root.addSubview(view)
    }

    /// A row of buttons side by side, from `controlsX`.
    private func placeRow(_ buttons: [NSView], row y: CGFloat) {
        var x = Self.controlsX
        for b in buttons { place(b, x: x, row: y); x += b.frame.width + 4 }
    }

    private func build() {
        var y: CGFloat = 44   // below the title bar, which the content runs under

        place(label("Appearance"), x: Self.inset, row: y)
        appearanceButtons = Appearance.allCases.map {
            ChoiceButton($0.title, id: "appearance-\($0.rawValue)", target: self, action: #selector(chooseAppearance(_:)))
        }
        placeRow(appearanceButtons, row: y)
        y += Self.rowHeight

        place(label("Text size"), x: Self.inset, row: y)
        placeStepper(textSize, id: "text", row: y, smaller: #selector(smallerText), bigger: #selector(biggerText))
        y += Self.rowHeight

        place(label("Notes text size"), x: Self.inset, row: y)
        placeStepper(notesSize, id: "notes", row: y, smaller: #selector(smallerNotes), bigger: #selector(biggerNotes))
        y += Self.rowHeight

        place(label("Focus mode"), x: Self.inset, row: y)
        focusButtons = [ChoiceButton("Off", id: "focus-off", target: self, action: #selector(chooseFocus(_:))),
                        ChoiceButton("On", id: "focus-on", target: self, action: #selector(chooseFocus(_:)))]
        placeRow(focusButtons, row: y)
        y += Self.rowHeight + 12

        let line = NSBox(frame: NSRect(x: Self.inset, y: y, width: Self.width - 2 * Self.inset, height: 1))
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = Theme.hairline
        root.addSubview(line)
        y += 12

        place(label("New notes go to"), x: Self.inset, row: y)
        locationsTop = y + Self.rowHeight
    }

    private var locationsTop: CGFloat = 0

    private func placeStepper(_ value: NSTextField, id: String, row y: CGFloat, smaller: Selector, bigger: Selector) {
        let minus = ChoiceButton("\u{2212}", id: "\(id)-smaller", width: 30, target: self, action: smaller)
        let plus = ChoiceButton("+", id: "\(id)-bigger", width: 30, target: self, action: bigger)
        minus.isOn = true; plus.isOn = true
        minus.setAccessibilityLabel("Smaller"); plus.setAccessibilityLabel("Bigger")
        value.font = Theme.mono(12, .regular)
        value.textColor = Theme.text
        value.alignment = .center
        value.frame.size = NSSize(width: 56, height: 16)
        place(minus, x: Self.controlsX, row: y)
        place(value, x: Self.controlsX + 34, row: y)
        place(plus, x: Self.controlsX + 94, row: y)
    }

    /// Show what the preferences hold, and lay the list of locations out again.
    func refresh() {
        let appearance = Appearance.stored
        for (button, value) in zip(appearanceButtons, Appearance.allCases) { button.isOn = value == appearance }
        let theme = Theme.stored
        textSize.stringValue = "\(Int(theme.fontSize)) pt"
        notesSize.stringValue = "\(Int(theme.notes.fontSize)) pt"
        let focus = DocumentWindowController.focusModeDefault
        focusButtons[0].isOn = !focus
        focusButtons[1].isOn = focus

        locationViews.forEach { $0.removeFromSuperview() }
        locationViews = []
        let locations = Locations.load()
        var y = locationsTop
        let rowHeight: CGFloat = 30
        for (i, folder) in locations.folders.enumerated() {
            let remove = ChoiceButton("Remove", id: "location-remove-\(i)", target: self, action: #selector(removeLocation(_:)))
            let row = ChoiceButton(Locations.abbreviated(folder), id: "location-\(i)", width: Self.width - 2 * Self.inset - remove.frame.width - 8,
                                   target: self, action: #selector(chooseLocation(_:)))
            row.leftAligned = true
            row.lineBreakMode = .byTruncatingMiddle
            row.isOn = folder == locations.defaultFolder
            row.toolTip = folder == locations.defaultFolder ? "New notes are saved here." : "Click to save new notes here."
            row.setFrameOrigin(NSPoint(x: Self.inset, y: y + 2))
            remove.setFrameOrigin(NSPoint(x: Self.width - Self.inset - remove.frame.width, y: y + 2))
            locationViews += [row, remove]
            y += rowHeight
        }
        if locations.folders.isEmpty {
            let none = label("No folder yet. A new note asks where to go.")
            none.textColor = Theme.mark
            none.setFrameOrigin(NSPoint(x: Self.inset, y: y + 7))
            locationViews.append(none)
            y += rowHeight
        }
        let add = ChoiceButton("Add Folder\u{2026}", id: "location-add", target: self, action: #selector(addLocation))
        add.isOn = true
        add.setFrameOrigin(NSPoint(x: Self.inset, y: y + 10))
        locationViews.append(add)
        y += 10 + add.frame.height + Self.inset
        locationViews.forEach(root.addSubview)

        guard let window, abs(root.frame.height - y) > 0.5 else { return }
        // grow and shrink downwards: the top edge stays where it is
        var frame = window.frame
        let height = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: y)).height
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
    }

    // MARK: actions

    @objc private func chooseAppearance(_ sender: ChoiceButton) {
        guard let i = appearanceButtons.firstIndex(of: sender) else { return }
        Appearance.stored = Appearance.allCases[i]
    }

    @objc private func biggerText() { DocumentWindowController.setFontSize(Theme.stored.fontSize + 1) }
    @objc private func smallerText() { DocumentWindowController.setFontSize(Theme.stored.fontSize - 1) }
    @objc private func biggerNotes() { DocumentWindowController.setNotesDelta(Theme.notesDelta + 1) }
    @objc private func smallerNotes() { DocumentWindowController.setNotesDelta(Theme.notesDelta - 1) }

    @objc private func chooseFocus(_ sender: ChoiceButton) { DocumentWindowController.setFocusMode(sender === focusButtons[1]) }

    private func folder(of sender: ChoiceButton, prefix: String) -> String? {
        guard let id = sender.identifier?.rawValue, id.hasPrefix(prefix), let i = Int(id.dropFirst(prefix.count)) else { return nil }
        let folders = Locations.load().folders
        return folders.indices.contains(i) ? folders[i] : nil
    }

    @objc private func chooseLocation(_ sender: ChoiceButton) {
        guard let path = folder(of: sender, prefix: "location-") else { return }
        var locations = Locations.load()
        locations.setDefault(path)
        locations.save()
    }

    @objc private func removeLocation(_ sender: ChoiceButton) {
        guard let path = folder(of: sender, prefix: "location-remove-") else { return }
        var locations = Locations.load()
        locations.remove(path)
        locations.save()
    }

    @objc private func addLocation() {
        (NSDocumentController.shared as? DocumentController)?.addLocation(nil)
    }
}
