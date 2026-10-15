import AppKit

@main
enum BoomeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let workspace = SessionWindowManager()
    private var windowController: MainWindowController? { workspace.activeWindow }
    private var keyMonitor: Any?
    private var sidebarItem: NSMenuItem?
    private var explorerItem: NSMenuItem?
    private var editorItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyHost.shared.delegate = workspace
        GhosttyHost.shared.start()
        BoomeChrome.installApplicationIcon()
        installMenu()
        let controller = workspace.newWindow(restoreFrame: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        controller?.window?.orderFrontRegardless()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 48, event.modifierFlags.contains(.control) else {
                return event
            }
            let previous = event.modifierFlags.contains(.shift)
            self.windowController?.cycle(previous ? .previous : .next)
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        GhosttyHost.shared.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspace.controllers.isEmpty { return .terminateNow }
        let started = workspace.prepareToTerminate { allowed in sender.reply(toApplicationShouldTerminate: allowed) }
        return started ? .terminateLater : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyHost.shared.focusApp(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        GhosttyHost.shared.focusApp(false)
    }

    @objc private func newWindow(_ sender: Any?) { workspace.newWindow() }

    @objc private func newTab(_ sender: Any?) {
        windowController?.newTab()
    }

    @objc private func closeTab(_ sender: Any?) {
        if windowController?.isEditorFocused == true { windowController?.closeEditor() }
        else { windowController?.closeCurrentTab() }
    }

    @objc private func previousTab(_ sender: Any?) {
        windowController?.cycle(.previous)
    }

    @objc private func nextTab(_ sender: Any?) {
        windowController?.cycle(.next)
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        windowController?.toggleSidebar()
    }

    @objc private func toggleExplorer(_ sender: Any?) { windowController?.toggleProjectExplorer() }
    @objc private func toggleEditor(_ sender: Any?) { windowController?.toggleEditor() }
    @objc private func saveFile(_ sender: Any?) { windowController?.saveFile() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if workspace.isPreparingTermination { return false }
        if menuItem.action == #selector(newWindow(_:)) { return true }
        if menuItem.action == #selector(saveFile(_:)) { return windowController?.canSaveFile == true }
        return windowController != nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        sidebarItem?.title = windowController?.isSidebarCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
        explorerItem?.title = windowController?.isProjectExplorerVisible == true ? "Hide Project Explorer" : "Show Project Explorer"
        editorItem?.title = windowController?.isEditorVisible == true ? "Hide Editor" : "Show Editor"
    }

    private func installMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Boome", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Boome", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        appMenu.addItem(quit)

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        let newWindow = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindow.target = self
        file.addItem(newWindow)
        file.addItem(.separator())
        let save = NSMenuItem(title: "Save", action: #selector(saveFile(_:)), keyEquivalent: "s")
        save.target = self
        file.addItem(save)

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        edit.addItem(find)

        let tabItem = NSMenuItem()
        main.addItem(tabItem)
        let tab = NSMenu(title: "Tab")
        tabItem.submenu = tab
        let new = NSMenuItem(title: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        new.target = self
        tab.addItem(new)
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        close.target = self
        tab.addItem(close)
        tab.addItem(.separator())
        let previous = NSMenuItem(title: "Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command, .shift]
        previous.target = self
        tab.addItem(previous)
        let next = NSMenuItem(title: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]
        next.target = self
        tab.addItem(next)
        tab.addItem(.separator())
        let sidebar = NSMenuItem(title: "Hide Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        sidebar.target = self
        tab.addItem(sidebar)
        sidebarItem = sidebar
        let explorer = NSMenuItem(title: "Show Project Explorer", action: #selector(toggleExplorer(_:)), keyEquivalent: "e")
        explorer.keyEquivalentModifierMask = [.command, .option]
        explorer.target = self
        tab.addItem(explorer)
        explorerItem = explorer
        let editor = NSMenuItem(title: "Show Editor", action: #selector(toggleEditor(_:)), keyEquivalent: "")
        editor.target = self
        tab.addItem(editor)
        editorItem = editor
        tab.delegate = self

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        let closeWindow = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(closeWindow)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
