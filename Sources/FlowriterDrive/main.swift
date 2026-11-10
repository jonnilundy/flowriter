import AppKit
import FlowriterKit

// FlowriterDrive --script=<file> --out=<dir> [--file=<file.md>]
// (key=value arguments: AppKit opens a bare path on the command line as a document)
//
// Runs the real app with its window parked far off every screen, and never activates it, so it
// takes no focus and shows nothing. Each line of the script is one step; key and mouse steps go
// through NSApplication.sendEvent like events from the keyboard and the pointer.
//
//   type <text>                 one key event per character
//   key <chord>                 Return, Tab, Shift-Tab, Backspace, Left, Right, Up, Down, Escape,
//                               or modifiers and a character: Cmd-b, Cmd-Shift-z, Opt-o, Opt-Shift-o
//   click page|notes <index>    click at that character
//   select page|notes <from> <length>
//   drag-drawer <dx>            drag the drawer's edge (negative: wider)
//   menu <Menu > Item>          choose a menu item
//   size <w> <h>                resize the window
//   dark | light
//   wait <seconds>
//   shot <name>                 save <out-dir>/<name>.png (the whole window, title bar included)
//   expect page|notes <text>    fail unless that side's text is exactly this (\n for a line break)
//   default <key> <value>       set a preference
//   location <folder>           add a saved location for new notes ($TMP is a folder made for the run;
//                               $STATE is one that outlives the run, for a script and its --keep-state sequel)
//   remove <path>               delete a file or folder under $TMP or $STATE
//   expect-title <name>         fail unless the top bar shows this name
//   expect-drafts <n>           fail unless this many unsaved notes are kept on disk
//   expect-windows <n>          fail unless this many note windows are open
//   quit                        quit the app the way Command-Q does (the last step of a script)
//   expect-path <file>          fail unless the newest document is this file
//   expect-file <file> <text>   fail unless the file on disk holds exactly this
//   log                         print the caret, the scroll place and the first responder

func argument(_ name: String) -> String? {
    CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
}
guard let scriptPath = argument("script"), let outPath = argument("out"), let script = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
    print("usage: FlowriterDrive --script=<file> --out=<dir> [--file=<file.md>]")
    exit(2)
}
let outDir = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let steps = script.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.hasPrefix("#") }

@MainActor
final class Driver {
    var failures = 0
    var index = 0
    /// An app that is not active has no key window for NSApplication to send keys to: the driver
    /// then does NSApplication's two steps itself (menu key equivalents, then the window).
    var direct = false

    /// The view the last mouse-down went to: it gets the drags and the mouse-up that follow.
    var mouseTarget: NSView?

    func send(_ e: NSEvent, _ window: NSWindow) {
        guard direct else { NSApp.sendEvent(e); return }
        // A window that is not key takes a mouse-down to become key and does not pass it on. Hit
        // test as the window would, and hand the event to the view.
        switch e.type {
        case .leftMouseDown:
            mouseTarget = (window.contentView?.superview ?? window.contentView)?.hitTest(e.locationInWindow)
            mouseTarget?.mouseDown(with: e)
            return
        case .leftMouseDragged:
            mouseTarget?.mouseDragged(with: e)
            return
        case .leftMouseUp:
            mouseTarget?.mouseUp(with: e)
            mouseTarget = nil
            return
        default: break
        }
        if e.type == .keyDown, e.modifierFlags.contains(.command) {
            if let item = menuItem(for: e, in: NSApp.mainMenu) { perform(item, window); return }
        }
        window.sendEvent(e)
    }

    /// The menu item whose key equivalent is this event.
    func menuItem(for e: NSEvent, in menu: NSMenu?) -> NSMenuItem? {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        for item in menu?.items ?? [] {
            if let found = menuItem(for: e, in: item.submenu) { return found }
            if !item.keyEquivalent.isEmpty, item.keyEquivalent == e.charactersIgnoringModifiers, item.keyEquivalentModifierMask == mods { return item }
        }
        return nil
    }

    /// Send a menu item's action the way the menu does: to its target, or up the responder chain
    /// from the window's first responder (window, window controller, document, then the app).
    @discardableResult
    func perform(_ item: NSMenuItem, _ window: NSWindow) -> Bool {
        guard let action = item.action else { return false }
        if let target = item.target { return NSApp.sendAction(action, to: target, from: item) }
        var responder: NSResponder? = window.firstResponder
        while let r = responder {
            if r.responds(to: action) {
                if let v = r as? NSMenuItemValidation, !v.validateMenuItem(item) { return false }
                r.perform(action, with: item)
                return true
            }
            responder = r.nextResponder
        }
        for candidate in [window.windowController?.document as AnyObject?, NSDocumentController.shared, NSApp, NSApp.delegate as AnyObject?] {
            if let c = candidate, c.responds(to: action) { _ = c.perform(action, with: item); return true }
        }
        return false
    }

    /// The note window in front.
    var controller: DocumentWindowController? {
        NSApp.orderedWindows.compactMap { $0.windowController as? DocumentWindowController }.first
            ?? NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }.first
    }

    /// A folder for the files a script makes: "$TMP" in a step stands for it.
    let temp: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flowriter-drive-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }()

    func start() {
        guard let c = controller, let window = c.window else { print("DRIVE no document window"); exit(1) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(c.editor)
        direct = NSApp.keyWindow !== window
        print("DRIVE window key=\(NSApp.keyWindow === window) active=\(NSApp.isActive) onScreen=\(window.screen != nil) " +
              "frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") direct=\(direct)")
        if NSApp.isActive { print("DRIVE FAIL the driver became the active app"); exit(3) }
        next()
    }

    func next() {
        guard index < steps.count else {
            try? FileManager.default.removeItem(at: temp)
            print(failures == 0 ? "DRIVE PASS \(steps.count) steps" : "DRIVE FAIL \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
        let line = steps[index].replacingOccurrences(of: "$TMP", with: temp.path).replacingOccurrences(of: "$STATE", with: Drafts.directory.deletingLastPathComponent().path)
        index += 1
        let delay = run(line)
        // AppKit closes the undo group of an event when its event loop takes the next event. The
        // steps here come from a timer, so give the loop an event to take.
        if let tick = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(tick, atStart: false)
        }
        // one run loop turn per step, as one per event in real use
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.next() }
    }

    func view(_ name: Substring) -> EditorTextView? { name == "notes" ? controller?.notesView : controller?.editor }

    func run(_ line: String) -> TimeInterval {
        guard let c = controller, let window = c.window else { return 0 }
        let parts = line.split(separator: " ", maxSplits: 1)
        let command = parts[0], rest = parts.count > 1 ? String(parts[1]) : ""
        let words = rest.split(separator: " ")
        switch command {
        case "type":
            // a sheet on the window takes the keys, as on screen
            for ch in rest { key(String(ch), keyCode: 0, flags: [], window.attachedSheet ?? window) }
        case "key":
            chord(rest, window.attachedSheet ?? window)
        case "default":
            UserDefaults.standard.set(String(rest.dropFirst(words[0].count + 1)), forKey: String(words[0]))
        case "location":
            var locations = Locations.load()
            locations.add(rest)
            locations.save()
        case "remove":
            // only inside the run's own folders
            let state = Drafts.directory.deletingLastPathComponent().path
            if rest.hasPrefix(temp.path + "/") || rest.hasPrefix(state + "/") { try? FileManager.default.removeItem(atPath: rest) }
            else { fail("remove is for $TMP and $STATE only: \(rest)") }
        case "expect-title":
            if c.titleText != rest { fail("the title is \(c.titleText.debugDescription), expected \(rest.debugDescription)") }
        case "expect-drafts":
            let n = Drafts.all().count
            if n != Int(rest) { fail("\(n) drafts on disk, expected \(rest)") }
        case "expect-windows":
            let n = NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }.count
            if n != Int(rest) { fail("\(n) note windows, expected \(rest)") }
        case "quit":
            // the real Quit: the app's own code decides what happens to unsaved notes
            print(failures == 0 ? "DRIVE PASS \(index) steps, then quit" : "DRIVE FAIL \(failures) failed")
            if failures > 0 { exit(1) }
            NSApp.terminate(nil)
        case "expect-path":
            let path = (c.document as? Document)?.fileURL?.resolvingSymlinksInPath().path ?? "none"
            if path != rest { fail("the document is \(path), expected \(rest)") }
        case "expect-file":
            let want = String(rest.dropFirst(words[0].count + 1)).replacingOccurrences(of: "\\n", with: "\n")
            let got = (try? String(contentsOfFile: String(words[0]), encoding: .utf8)) ?? "<no file>"
            if got != want { fail("\(words[0]) holds \(got.debugDescription), expected \(want.debugDescription)") }
        case "click":
            if let v = view(words[0]), let i = Int(words[1]) { click(v, at: i, window) }
        case "select":
            if let v = view(words[0]), let a = Int(words[1]), let n = Int(words[2]) {
                window.makeFirstResponder(v)
                v.setSelectedRange(NSRange(location: a, length: n))
            }
        case "drag-drawer":
            dragDrawer(by: CGFloat(Double(rest) ?? 0), c, window)
        case "menu":
            if !chooseMenu(rest) { fail("menu item not found or disabled: \(rest)") }
        case "size":
            if let w = Double(words[0]), let h = Double(words[1]) {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: w, height: h), display: true)
            }
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "wait":
            return Double(rest) ?? 0.2
        case "shot":
            shot(rest, window)
        case "expect":
            if let v = view(words[0]) {
                let want = String(rest.dropFirst(words[0].count + 1)).replacingOccurrences(of: "\\n", with: "\n")
                if v.string != want { fail("\(words[0]) is \(v.string.debugDescription), expected \(want.debugDescription)") }
            }
        case "log":
            let r = window.firstResponder
            let who = r === c.editor ? "page" : r === c.notesView ? "notes" : String(describing: type(of: r))
            print("DRIVE log notesWidth=\(Int(c.notesFrame.width)) caret=\(c.editor.selectedRange()) scrollY=\(c.editor.enclosingScrollView?.contentView.bounds.minY ?? -1) first=\(who) notesOpen=\(c.notesOpen) column=\(c.editor.textContainerOrigin.x)")
        default:
            fail("unknown step: \(line)")
        }
        return 0.03
    }

    func fail(_ message: String) {
        failures += 1
        print("DRIVE FAIL step \(index): \(message)")
    }

    // MARK: events

    static let named: [String: (UInt16, String)] = [
        "Return": (36, "\r"), "Tab": (48, "\t"), "Backspace": (51, "\u{7F}"), "Escape": (53, "\u{1B}"),
        "Left": (123, "\u{F702}"), "Right": (124, "\u{F703}"), "Down": (125, "\u{F701}"), "Up": (126, "\u{F700}"),
    ]

    func chord(_ spec: String, _ window: NSWindow) {
        var parts = spec.split(separator: "-").map(String.init)
        guard var name = parts.popLast() else { return }
        var flags: NSEvent.ModifierFlags = []
        for p in parts {
            switch p {
            case "Cmd": flags.insert(.command)
            case "Opt": flags.insert(.option)
            case "Shift": flags.insert(.shift)
            case "Ctrl": flags.insert(.control)
            default: break
            }
        }
        if let (code, chars) = Self.named[name] {
            var c = chars
            if name == "Tab", flags.contains(.shift) { c = "\u{19}" }
            if code >= 123 { flags.insert([.function, .numericPad]) }
            key(c, keyCode: code, flags: flags, window)
        } else {
            if flags.contains(.shift), !flags.contains(.command) { name = name.uppercased() }
            key(name, keyCode: 0, flags: flags, window)
        }
    }

    func key(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, _ window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: keyCode) else { continue }
            send(e, window)
        }
    }

    func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    func click(_ v: EditorTextView, at index: Int, _ window: NSWindow) {
        guard let lm = v.layoutManager, let container = v.textContainer else { return }
        let length = (v.string as NSString).length
        var rect: NSRect
        if index >= length {
            rect = lm.extraLineFragmentTextContainer != nil ? lm.extraLineFragmentRect : lm.boundingRect(forGlyphRange: NSRange(location: max(0, lm.numberOfGlyphs - 1), length: 1), in: container)
            if lm.extraLineFragmentTextContainer == nil { rect.origin.x = rect.maxX - 1 }
        } else {
            rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil), in: container)
        }
        let origin = v.textContainerOrigin
        let inView = NSPoint(x: rect.minX + origin.x + 1, y: rect.midY + origin.y)
        guard v.visibleRect.contains(inView) else { fail("character \(index) is scrolled out of view"); return }
        let p = v.convert(inView, to: nil)
        // NSTextView tracks the mouse in its own loop: the mouse-up must already wait in the queue
        NSApp.postEvent(mouse(.leftMouseUp, p, window), atStart: false)
        send(mouse(.leftMouseDown, p, window), window)
    }

    func dragDrawer(by dx: CGFloat, _ c: DocumentWindowController, _ window: NSWindow) {
        let f = c.notesFrame
        let start = NSPoint(x: f.minX + 2, y: f.midY)
        send(mouse(.leftMouseDown, start, window), window)
        for step in 1...4 { send(mouse(.leftMouseDragged, NSPoint(x: start.x + dx * CGFloat(step) / 4, y: start.y), window), window) }
        send(mouse(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y), window), window)
    }

    func chooseMenu(_ path: String) -> Bool {
        guard let window = controller?.window else { return false }
        var menu = NSApp.mainMenu
        let names = path.components(separatedBy: " > ")
        for (i, name) in names.enumerated() {
            guard let m = menu, let item = m.items.first(where: { $0.title == name }) ?? m.items.first(where: { $0.title.hasPrefix(name) }) else { return false }
            if i == names.count - 1 { return perform(item, window) }
            menu = item.submenu
        }
        return false
    }

    func shot(_ name: String, _ window: NSWindow) {
        // a sheet is its own window: it gets its own picture
        if let sheet = window.attachedSheet { capture(name + "-sheet", sheet) }
        capture(name, window)
    }

    func capture(_ name: String, _ window: NSWindow) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name + ".png"))
    }
}

MainActor.assumeIsolated {
    AppDelegate.offScreen = true
    AppDelegate.launchFiles = argument("file").map { [URL(fileURLWithPath: $0)] } ?? []
    // A clean slate each run, in this tool's own preferences and drafts folder (never the app's).
    // --keep-state leaves both, to see what a second launch brings back.
    if !CommandLine.arguments.contains("--keep-state") {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        Drafts.removeAll()
    }
    let driver = Driver()
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { driver.start() } }
    }
    AppDelegate.run()
}
