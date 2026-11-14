import AppKit

/// What File > Print uses: the font, and whether each `---` rule starts a new page. Kept in the
/// user defaults, and set in the print panel (PrintAccessory).
@MainActor
public final class PrintOptions: NSObject {
    public static let fontKey = "FlowriterPrintFont"
    public static let fontSizeKey = "FlowriterPrintFontSize"
    public static let pageBreaksKey = "FlowriterPrintPageBreaks"
    public static let defaultFontSize: CGFloat = 11
    public static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24]
    /// The font family named in the menu for the page's own font.
    public static let pageFontTitle = "Paper Mono"

    /// A font family name, or nil for the page's own font (Paper Mono).
    @objc public dynamic var fontFamily: String? {
        didSet { store(fontFamily, Self.fontKey) }
    }
    @objc public dynamic var fontSize: CGFloat {
        didSet { store(fontSize, Self.fontSizeKey) }
    }
    @objc public dynamic var pageBreaks: Bool {
        didSet { store(pageBreaks, Self.pageBreaksKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontFamily = defaults.string(forKey: Self.fontKey)
        let size = defaults.double(forKey: Self.fontSizeKey)
        fontSize = size >= 4 && size <= 72 ? CGFloat(size) : Self.defaultFontSize
        pageBreaks = defaults.bool(forKey: Self.pageBreaksKey)
        super.init()
    }

    private func store(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// The chosen family at the chosen size. A family that is no longer installed prints in Paper Mono.
    public var font: NSFont {
        if let family = fontFamily,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: fontSize) { return font }
        return Theme.mono(fontSize, .regular)
    }
}

/// The text as it goes to paper.
public enum PrintText {
    /// Splits the text into pages at each `---` rule line (`- - -` too). The rule lines go. A
    /// `---` on the first line opens front matter and a `---` inside a code fence is code, so
    /// neither breaks the page. A page with only blank lines is left out.
    public static func pages(_ text: String, breakAtRules: Bool) -> [String] {
        guard breakAtRules else { return [text] }
        var pages: [String] = []
        var page: [String] = []
        var state = BlockState.normal
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let wasNormal = state == .normal
            state = MarkdownStyler.style(line, state: state, isFirstLine: i == 0).endState
            if wasNormal, state == .normal, isDashRule(line) {
                pages.append(page.joined(separator: "\n"))
                page = []
            } else {
                page.append(line)
            }
        }
        pages.append(page.joined(separator: "\n"))
        let kept = pages.map(trimBlankLines).filter { !$0.isEmpty }
        return kept.isEmpty ? [""] : kept
    }

    /// The text with a form feed between pages: NSLayoutManager moves to the next text container
    /// (page) at a form feed.
    public static func paged(_ text: String, breakAtRules: Bool) -> String {
        pages(text, breakAtRules: breakAtRules).joined(separator: "\u{0C}")
    }

    static func isDashRule(_ line: String) -> Bool {
        let leading = line.prefix { $0 == " " }.count
        guard leading <= 3 else { return false }
        var count = 0
        for c in line.dropFirst(leading) {
            if c == "-" { count += 1 } else if c != " " && c != "\t" { return false }
        }
        return count >= 3
    }

    private static func trimBlankLines(_ page: String) -> String {
        var lines = page.components(separatedBy: "\n")
        while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// The printed pages: one text container per page on one layout manager, stacked top to bottom.
/// The layout is made again each time AppKit asks for the page range, so the print panel's
/// preview follows the options.
@MainActor
public final class PrintView: NSView {
    private let text: String
    private let options: PrintOptions
    private var pageSize = NSSize(width: 468, height: 648)
    private var storage = NSTextStorage()
    public private(set) var pageCount = 1

    public init(text: String, options: PrintOptions) {
        self.text = text
        self.options = options
        super.init(frame: NSRect(origin: .zero, size: pageSize))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    /// Lay the text out on pages of the printable size of `info`.
    public func layout(for info: NSPrintInfo) {
        let bounds = info.imageablePageBounds
        let margins = NSSize(width: info.leftMargin + info.rightMargin, height: info.topMargin + info.bottomMargin)
        var size = NSSize(width: info.paperSize.width - margins.width, height: info.paperSize.height - margins.height)
        // the printer cannot reach the paper's edge: keep inside what it can print
        size.width = max(72, min(size.width, bounds.width))
        size.height = max(72, min(size.height, bounds.height))
        pageSize = size

        subviews.forEach { $0.removeFromSuperview() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        storage = NSTextStorage(string: PrintText.paged(text, breakAtRules: options.pageBreaks),
                                attributes: [.font: options.font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var page = 0
        repeat {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let view = NSTextView(frame: NSRect(x: 0, y: CGFloat(page) * pageSize.height, width: pageSize.width, height: pageSize.height),
                                  textContainer: container)
            view.drawsBackground = false
            view.isEditable = false
            view.isSelectable = false
            view.textContainerInset = .zero
            addSubview(view)
            layout.ensureLayout(for: container)
            page += 1
        } while NSMaxRange(layout.glyphRange(for: layout.textContainers.last!)) < layout.numberOfGlyphs && page < 5000
        pageCount = page
        setFrameSize(NSSize(width: pageSize.width, height: CGFloat(page) * pageSize.height))
    }

    public override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        layout(for: NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared)
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    public override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height, width: pageSize.width, height: pageSize.height)
    }
}

/// The print panel's own controls: the font, its size, and the page breaks at `---`.
@MainActor
final class PrintAccessory: NSViewController, NSPrintPanelAccessorizing {
    @objc let options: PrintOptions
    private let family = NSPopUpButton()
    private let size = NSPopUpButton()
    private let breaks = NSButton(checkboxWithTitle: "Start a new page at each ---", target: nil, action: nil)

    init(options: PrintOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
        title = "Flowriter"
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 96))
        let fontLabel = NSTextField(labelWithString: "Font:")
        let sizeLabel = NSTextField(labelWithString: "Size:")

        family.addItem(withTitle: PrintOptions.pageFontTitle)
        family.menu?.addItem(.separator())
        for name in NSFontManager.shared.availableFontFamilies where name != PrintOptions.pageFontTitle && !name.hasPrefix(".") {
            family.addItem(withTitle: name)
        }
        family.selectItem(withTitle: options.fontFamily ?? PrintOptions.pageFontTitle)
        if family.selectedItem == nil { family.selectItem(at: 0) }
        family.target = self
        family.action = #selector(chooseFamily)
        family.identifier = NSUserInterfaceItemIdentifier("print-font")

        for s in PrintOptions.sizes { size.addItem(withTitle: "\(Int(s)) pt") }
        size.selectItem(withTitle: "\(Int(options.fontSize)) pt")
        if size.selectedItem == nil { size.selectItem(withTitle: "\(Int(PrintOptions.defaultFontSize)) pt") }
        size.target = self
        size.action = #selector(chooseSize)
        size.identifier = NSUserInterfaceItemIdentifier("print-size")

        breaks.state = options.pageBreaks ? .on : .off
        breaks.target = self
        breaks.action = #selector(toggleBreaks)
        breaks.identifier = NSUserInterfaceItemIdentifier("print-page-breaks")

        fontLabel.frame = NSRect(x: 20, y: 62, width: 60, height: 18)
        family.frame = NSRect(x: 84, y: 56, width: 200, height: 26)
        sizeLabel.frame = NSRect(x: 296, y: 62, width: 40, height: 18)
        size.frame = NSRect(x: 336, y: 56, width: 76, height: 26)
        breaks.frame = NSRect(x: 82, y: 20, width: 320, height: 20)
        for label in [fontLabel, sizeLabel] { label.alignment = .right }
        [fontLabel, family, sizeLabel, size, breaks].forEach(view.addSubview)
        self.view = view
    }

    @objc private func chooseFamily() {
        let name = family.titleOfSelectedItem
        options.fontFamily = name == PrintOptions.pageFontTitle ? nil : name
    }

    @objc private func chooseSize() {
        options.fontSize = PrintOptions.sizes[max(0, size.indexOfSelectedItem)]
    }

    @objc private func toggleBreaks() { options.pageBreaks = breaks.state == .on }

    nonisolated func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        MainActor.assumeIsolated {
            [[.itemName: "Font", .itemDescription: "\(options.fontFamily ?? PrintOptions.pageFontTitle) \(Int(options.fontSize)) pt"],
             [.itemName: "New page at ---", .itemDescription: options.pageBreaks ? "On" : "Off"]]
        }
    }

    nonisolated func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["options.fontFamily", "options.fontSize", "options.pageBreaks"]
    }
}

extension Document {
    /// File > Print: the text in the print font, on pages of the paper size, with the font and
    /// page break controls in the print panel.
    func makePrintOperation(settings printSettings: [NSPrintInfo.AttributeKey: Any]) -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        let options = PrintOptions()
        let view = PrintView(text: currentText, options: options)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = displayName
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        operation.printPanel.addAccessoryController(PrintAccessory(options: options))
        return operation
    }
}
