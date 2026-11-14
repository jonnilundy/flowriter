import XCTest
import AppKit
import PDFKit
@testable import FlowriterKit

@MainActor
final class PrintTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: "PrintTests")
        defaults.removePersistentDomain(forName: "PrintTests")
    }

    // MARK: pages

    func testWithoutBreaksTheTextIsOnePage() {
        XCTAssertEqual(PrintText.pages("a\n---\nb", breakAtRules: false), ["a\n---\nb"])
    }

    func testEachDashRuleStartsAPageAndIsLeftOut() {
        XCTAssertEqual(PrintText.pages("one\n\n---\n\ntwo\n- - -\nthree", breakAtRules: true), ["one", "two", "three"])
    }

    func testOtherRulesAndLongerDashLinesAndTextStay() {
        XCTAssertEqual(PrintText.pages("a\n***\nb\n___\nc", breakAtRules: true), ["a\n***\nb\n___\nc"])
        XCTAssertEqual(PrintText.pages("a\n------\nb", breakAtRules: true), ["a", "b"])
        XCTAssertEqual(PrintText.pages("a --- b\n--x", breakAtRules: true), ["a --- b\n--x"])
    }

    func testFrontMatterAndCodeFencesDoNotBreak() {
        let text = "---\ntitle: x\n---\nintro\n```\n---\n```\nend\n---\nlast"
        XCTAssertEqual(PrintText.pages(text, breakAtRules: true), ["---\ntitle: x\n---\nintro\n```\n---\n```\nend", "last"])
    }

    func testEmptyPagesAreLeftOut() {
        XCTAssertEqual(PrintText.pages("a\n---\n\n---\nb\n---\n", breakAtRules: true), ["a", "b"])
        XCTAssertEqual(PrintText.pages("\n---\n", breakAtRules: true), [""])
    }

    // MARK: options

    func testOptionsDefaultToPaperMonoAndNoBreaks() {
        let options = PrintOptions(defaults: defaults)
        XCTAssertNil(options.fontFamily)
        XCTAssertEqual(options.fontSize, PrintOptions.defaultFontSize)
        XCTAssertFalse(options.pageBreaks)
        XCTAssertEqual(options.font.pointSize, PrintOptions.defaultFontSize)
    }

    func testOptionsAreKept() {
        let options = PrintOptions(defaults: defaults)
        options.fontFamily = "Times New Roman"
        options.fontSize = 14
        options.pageBreaks = true
        let again = PrintOptions(defaults: defaults)
        XCTAssertEqual(again.fontFamily, "Times New Roman")
        XCTAssertEqual(again.fontSize, 14)
        XCTAssertTrue(again.pageBreaks)
        XCTAssertEqual(again.font.familyName, "Times New Roman")
        again.fontFamily = nil
        XCTAssertNil(defaults.object(forKey: PrintOptions.fontKey))
    }

    func testAMissingFontPrintsInPaperMono() {
        let options = PrintOptions(defaults: defaults)
        options.fontFamily = "No Such Font Family"
        XCTAssertEqual(options.font.fontName, Theme.mono(options.fontSize, .regular).fontName)
    }

    // MARK: layout and print

    private func info() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 72; info.bottomMargin = 72; info.leftMargin = 72; info.rightMargin = 72
        return info
    }

    func testEachRuleIsAPageWhenBreaksAreOn() {
        let options = PrintOptions(defaults: defaults)
        let view = PrintView(text: "one\n---\ntwo\n---\nthree", options: options)
        view.layout(for: info())
        XCTAssertEqual(view.pageCount, 1)
        options.pageBreaks = true
        view.layout(for: info())
        XCTAssertEqual(view.pageCount, 3)
    }

    func testLongTextRunsOnToMorePages() {
        let options = PrintOptions(defaults: defaults)
        let view = PrintView(text: Array(repeating: "line", count: 200).joined(separator: "\n"), options: options)
        view.layout(for: info())
        let small = view.pageCount
        XCTAssertGreaterThan(small, 1)
        options.fontSize = 20
        view.layout(for: info())
        XCTAssertGreaterThan(view.pageCount, small)
    }

    func testPrintingWritesThePagesInTheChosenFont() throws {
        let options = PrintOptions(defaults: defaults)
        options.pageBreaks = true
        options.fontFamily = "Times New Roman"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowriter-print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let printInfo = info()
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let view = PrintView(text: "# First\n\nhello\n---\n# Second\n\nworld", options: options)
        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        XCTAssertTrue(operation.run())
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(pdf.page(at: 0)?.string?.contains("First"), true)
        XCTAssertEqual(pdf.page(at: 1)?.string?.contains("world"), true)
        XCTAssertEqual(pdf.page(at: 1)?.string?.contains("---"), false)
        let font = pdf.page(at: 0)?.selection(for: NSRange(location: 2, length: 1))?.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.familyName, "Times New Roman")
    }

    func testTheFileMenuPrintsWithCommandP() {
        let file = MainMenu.build().items.first { $0.title == "File" }?.submenu
        let print = file?.items.first { $0.keyEquivalent == "p" && $0.keyEquivalentModifierMask == .command }
        XCTAssertEqual(print?.action, #selector(NSDocument.printDocument(_:)))
        let setup = file?.items.first { $0.keyEquivalent == "p" && $0.keyEquivalentModifierMask == [.command, .shift] }
        XCTAssertEqual(setup?.action, #selector(NSDocument.runPageLayout(_:)))
    }

    func testTheDocumentsPrintOperationHasTheFlowriterControls() throws {
        let document = Document()
        try document.read(from: Data("a\n---\nb".utf8), ofType: Document.markdownType)
        let operation = try document.printOperation(withSettings: [:])
        XCTAssertTrue(operation.view is PrintView)
        XCTAssertTrue(operation.printPanel.accessoryControllers.contains { $0 is PrintAccessory })
    }
}
