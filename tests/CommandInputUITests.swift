import AppKit

enum CommandInputUITests {
    static func until(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(6)
        while !predicate(), Date() < deadline {
            while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    static func run(workspace: SessionWindowManager, root: URL) throws {
        let previous = NSWorkspace.shared.frontmostApplication
        defer { previous?.activate(options: [.activateIgnoringOtherApps]) }
        try check("UI fixture can post real input events", CGPreflightPostEventAccess())
        NSApp.finishLaunching()
        let menu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu()
        menu.addItem(appItem)
        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = edit
        menu.addItem(editItem); NSApp.mainMenu = menu
        let controller = workspace.newWindow(empty: true)!
        controller.newTab()
        let window = controller.window!
        let tab = controller.tabs(with: Set(controller.arrangement.ids))[0]
        let input = tab.content.input!
        let text = input.textView
        window.setContentSize(NSSize(width: 900, height: 550))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try check("UI fixture becomes the foreground application", until { window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() })
        try check("UI native editor becomes ready", until { tab.view.surface.commandInput?.snapshot?.isReady == true && input.expanded })
        window.contentView?.layoutSubtreeIfNeeded()
        try check("UI command editor receives native focus automatically", until { window.firstResponder === text })

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            let items = saved.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
        func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
                event.flags = flags; event.post(tap: .cghidEventTap)
            }
        }
        func paste(_ value: String) {
            pasteboard.clearContents(); pasteboard.setString(value, forType: .string)
            key(9, flags: .maskCommand)
        }
        func screen(_ point: NSPoint, in view: NSView) -> CGPoint {
            let inWindow = view.convert(point, to: nil)
            let p = window.convertPoint(toScreen: inWindow)
            return CGPoint(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y)
        }
        func point(_ character: Int) -> CGPoint {
            let layout = text.layoutManager!
            let container = text.textContainer!
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: character)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return screen(NSPoint(x: rect.minX + text.textContainerInset.width + 0.5,
                                  y: rect.midY + text.textContainerInset.height), in: text)
        }
        func mouse(_ type: CGEventType, _ point: CGPoint, clicks: Int64 = 1, flags: CGEventFlags = []) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
            event.setIntegerValueField(.mouseEventClickState, value: clicks)
            event.flags = flags; event.post(tap: .cghidEventTap)
            usleep(5000)
        }
        func click(_ p: CGPoint, clicks: Int64 = 1, flags: CGEventFlags = []) {
            mouse(.leftMouseDown, p, clicks: clicks, flags: flags)
            mouse(.leftMouseUp, p, clicks: clicks, flags: flags)
        }
        paste("echo alpha beta gamma")
        try check("UI paste edits the command without executing", until { text.string == "echo alpha beta gamma" && tab.view.surface.commandInput?.pending == nil })
        click(point(5))
        try check("UI mouse click positions the caret", until { text.selectedRange() == NSRange(location: 5, length: 0) })
        mouse(.leftMouseDown, point(5))
        mouse(.leftMouseDragged, point(10))
        mouse(.leftMouseUp, point(10))
        try check("UI drag selects an exact text range", until { text.selectedRange() == NSRange(location: 5, length: 5) })
        paste("delta")
        try check("UI typing replaces selected command text", until { text.string == "echo delta beta gamma" })
        key(6, flags: .maskCommand)
        try check("UI undo restores the replaced selection", until { text.string == "echo alpha beta gamma" })
        click(point(7), clicks: 2)
        try check("UI double click selects a word", until { text.selectedRange() == NSRange(location: 5, length: 5) })
        click(point(5))
        _ = until { text.selectedRange().length == 0 }
        click(point(15), flags: .maskShift)
        try check("UI shift click extends from the existing anchor", until { text.selectedRange() == NSRange(location: 5, length: 10) })
        click(point(8), clicks: 3)
        try check("UI triple click selects the command line", until { text.selectedRange().location == 0 && text.selectedRange().length == (text.string as NSString).length })
        key(0, flags: .maskCommand)
        _ = until { text.selectedRange().length == (text.string as NSString).length }
        paste("echo '中文👩‍💻'")
        try check("UI native document accepts Unicode commands", until { text.string == "echo '中文👩‍💻'" })
        key(36, flags: .maskShift)
        try check("UI Shift Enter inserts a newline without execution", until { text.string.contains("\n") && tab.view.surface.commandInput?.pending == nil })
        key(0, flags: .maskCommand)
        _ = until { text.selectedRange().length == (text.string as NSString).length }
        let result = root.appendingPathComponent("ui-result.txt")
        let command = "printf 'clicked' > '" + result.path + "'"
        paste(command)
        try check("UI command replacement is ready", until { text.string == command })
        let run = descendants(input, NSButton.self).first { $0.accessibilityIdentifier() == "CommandRun" }!
        click(screen(NSPoint(x: run.bounds.midX, y: run.bounds.midY), in: run))
        try check("UI Run button executes only after confirmation", until { (try? String(contentsOf: result)) == "clicked" && tab.view.surface.commandInput?.pending == nil })
        try check("UI editor restores after command completion", until { input.expanded && text.string.isEmpty })
        print("OK command input real-event UI checks"); fflush(stdout)
    }
}
