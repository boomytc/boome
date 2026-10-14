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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowController: MainWindowController?
    private var keyMonitor: Any?
    private var horizontalItem: NSMenuItem?
    private var sidebarItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GhosttyHost.shared.start()
        BoomeChrome.installApplicationIcon()
        installMenu()
        let controller = MainWindowController()
        windowController = controller
        controller.show()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        controller.window?.orderFrontRegardless()
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
        guard let windowController else { return .terminateNow }
        if windowController.approveTermination() { return .terminateNow }
        windowController.requestQuit()
        if windowController.approveTermination() { return .terminateNow }
        return .terminateCancel
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

    @objc private func newTab(_ sender: Any?) {
        windowController?.newTab()
    }

    @objc private func closeTab(_ sender: Any?) {
        windowController?.closeCurrentTab()
    }

    @objc private func previousTab(_ sender: Any?) {
        windowController?.cycle(.previous)
    }

    @objc private func nextTab(_ sender: Any?) {
        windowController?.cycle(.next)
    }

    @objc private func toggleTabPlacement(_ sender: Any?) {
        windowController?.toggleTabPlacement()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        windowController?.toggleSidebar()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let horizontal = windowController?.isHorizontal == true
        horizontalItem?.state = horizontal ? .on : .off
        sidebarItem?.title = windowController?.isSidebarCollapsed == true ? "Show Sidebar" : "Hide Sidebar"
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

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

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
        let horizontal = NSMenuItem(title: "Use Horizontal Tabs", action: #selector(toggleTabPlacement(_:)), keyEquivalent: "t")
        horizontal.keyEquivalentModifierMask = [.command, .option]
        horizontal.target = self
        tab.addItem(horizontal)
        horizontalItem = horizontal
        let sidebar = NSMenuItem(title: "Hide Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        sidebar.target = self
        tab.addItem(sidebar)
        sidebarItem = sidebar
        tab.delegate = self

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
