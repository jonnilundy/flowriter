import AppKit

/// Renders a document window's content to a PNG without showing a window. Used to check the look
/// from the command line and in tests.
@MainActor
public enum Snapshot {
    public struct Options {
        public var width: CGFloat = 980
        public var height: CGFloat = 760
        public var dark = false
        public var focus = false
        /// Notes to show in the open drawer; nil leaves the drawer closed.
        public var notes: String?
        public var caret: Int?
        public init() {}
    }

    public static func window(markdown: String, options: Options) -> DocumentWindowController {
        let document = Document()
        try? document.read(from: Data(markdown.utf8), ofType: Document.markdownType)
        if let notes = options.notes { document.setNotes(notes) }
        let controller = DocumentWindowController(document: document)
        document.addWindowController(controller)
        controller.keptDocument = document
        let window = controller.window!
        window.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        window.setFrame(NSRect(x: -20000, y: -20000, width: options.width, height: options.height), display: false)
        if options.notes != nil { controller.setNotesOpen(true) }
        controller.editor.focusMode = options.focus
        if let caret = options.caret {
            controller.editor.setSelectedRange(NSRange(location: min(caret, (markdown as NSString).length), length: 0))
            controller.editor.scrollRangeToVisible(controller.editor.selectedRange())
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    public static func png(markdown: String, options: Options = Options()) -> Data? {
        let controller = window(markdown: markdown, options: options)
        guard let view = controller.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        var data: Data?
        (controller.window?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        (controller.document as? Document)?.close()
        return data
    }
}
