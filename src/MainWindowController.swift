import AppKit

/// A window that has approved application termination must not accept new work
/// while another window is still showing its save/close confirmation.
private final class SessionWindow: NSWindow {
    var isInputLocked = false

    override func sendEvent(_ event: NSEvent) {
        if isInputLocked {
            switch event.type {
            case .keyDown, .keyUp, .flagsChanged,
                 .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                 .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                 .scrollWheel, .tabletPoint, .tabletProximity,
                 .gesture, .magnify, .swipe, .rotate, .beginGesture, .endGesture, .pressure:
                return
            default:
                // AppKit still needs activation and window-management events
                // so the user can return to another window's pending sheet.
                break
            }
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard !isInputLocked || responder == nil else { return false }
        return super.makeFirstResponder(responder)
    }
}

private final class SessionMenuAction {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}

final class TerminalTab {
    let id: TabID
    var ordinal: Int { id.raw }
    let view: TerminalSurfaceView
    let content: TerminalSessionView
    var terminalTitle = ""
    var tabTitle: String?
    var workingDirectory: String?
    var groupID: UUID?
    private static var nextIdentity = 1

    static func allocateID() -> TabID {
        defer { nextIdentity += 1 }
        return TabID(raw: nextIdentity)
    }

    init(id: TabID, view: TerminalSurfaceView) {
        self.id = id
        self.view = view
        self.content = TerminalSessionView(terminal: view)
    }

    var label: String {
        if let tabTitle, !tabTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return tabTitle
        }
        let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let workingDirectory, !workingDirectory.isEmpty {
            let name = (workingDirectory as NSString).lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        return "Terminal \(ordinal)"
    }
}

/// Title-bar control for the sidebar. The glyph stays `sidebar.left`.
/// The label follows the window's existing collapsed bit.
private final class SidebarToggleButton: NSView {
    var onPress: (() -> Void)?

    private var surfaceBackground = BoomeChrome.fallbackBackground
    private var hovered = false
    private var collapsed = true
    private var tracking: NSTrackingArea?
    enum Panel { case tabs, explorer, editor }
    private let panel: Panel

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    init(frame frameRect: NSRect, panel: Panel = .tabs) {
        self.panel = panel
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
        setAccessibilityIdentifier(panel == .explorer ? "ProjectExplorerToggle" : panel == .editor ? "EditorToggle" : "SidebarToggle")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func use(background: NSColor) {
        surfaceBackground = background
        paint(animated: false)
        needsDisplay = true
    }

    func note(collapsed: Bool) {
        self.collapsed = collapsed
        let name = panel == .explorer ? "项目浏览器" : panel == .editor ? "编辑器" : "侧栏"
        let title = "\(collapsed ? "展开" : "收起")\(name)"
        let shortcut = panel == .explorer ? " (⌥⌘E)" : panel == .tabs ? " (⌥⌘S)" : ""
        toolTip = title + shortcut
        setAccessibilityLabel(title)
        setAccessibilityHelp(toolTip)
        setAccessibilityValue(collapsed ? 0 : 1)
        paint(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovered = true
        paint(animated: true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = false
        paint(animated: true)
        needsDisplay = true
    }

    /// The title bar does not always deliver mouseUp. One mouseDown is the click.
    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = BoomeChrome.text(selected: hovered, on: surfaceBackground)
        let side: CGFloat = 15
        let icon = NSRect(
            x: ((bounds.width - side) / 2).rounded(),
            y: ((bounds.height - side) / 2).rounded(),
            width: side,
            height: side
        )
        Self.symbol(color, name: panel == .explorer ? "folder" : panel == .editor ? "sidebar.right" : "sidebar.left")?.draw(
            in: icon,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func paint(animated: Bool) {
        let fill = !collapsed
            ? BoomeChrome.selectionFill(on: surfaceBackground)
            : BoomeChrome.newTabFill(hovered: hovered, on: surfaceBackground)
        paintFill(layer, color: fill, animated: animated)
    }

    private static func symbol(_ color: NSColor, name: String) -> NSImage? {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let size = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return symbol?.withSymbolConfiguration(size.applying(palette))
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private enum WindowFollowUp {
        case closeWindow
        case quit
    }

    private struct WindowProbe {
        var remaining: Set<TabID>
        var live: [TabID]
    }

    private let host = GhosttyHost.shared
    private let sidebar = TabSidebar()
    private let sidebarToggle = SidebarToggleButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    private let explorerToggle = SidebarToggleButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28), panel: .explorer)
    private let editorToggle = SidebarToggleButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28), panel: .editor)
    private let projectExplorer = ProjectExplorerView(frame: .zero)
    private let fileEditor = FileEditorView(frame: .zero)
    private let terminalHost = NSView()
    private let separator = NSView()
    private let explorerSeparator = NSView()
    private let editorSeparator = NSView()
    private var editorWidth: NSLayoutConstraint!
    private var editorSeparatorWidth: NSLayoutConstraint!
    private var sidebarWidth: NSLayoutConstraint!
    private var separatorWidth: NSLayoutConstraint!
    private var explorerWidth: NSLayoutConstraint!
    private var explorerSeparatorWidth: NSLayoutConstraint!
    private var tabs: [TerminalTab] = []
    private var selected = 0
    private var groups: [UUID: SessionGroup] = [:]
    private weak var workspace: SessionWindowManager?
    private let restoresFrame: Bool
    private var quitCompletion: ((Bool) -> Void)?
    private var sidebarCollapsed = false
    private var explorerVisible = false
    private var editorVisible = false
    private var adjustingLayout = false
    private var appearanceObserver: NSKeyValueObservation?
    private var closePolicy = ClosePolicy()
    private var windowProbe: WindowProbe?
    private var windowFollowUp: WindowFollowUp?
    private var allowWindowClose = false
    private weak var terminationFirstResponder: NSResponder?
    private var confirmAlert: NSAlert?

    var isSidebarCollapsed: Bool { sidebarCollapsed }
    var isProjectExplorerVisible: Bool { explorerVisible }
    var isEditorVisible: Bool { editorVisible }
    var isEditorFocused: Bool { editorVisible && fileEditor.isFocused }
    var canSaveFile: Bool { fileEditor.document != nil && fileEditor.hasUnsavedChanges && !fileEditor.isBusy }

    func requestQuit(_ completion: @escaping (Bool) -> Void) {
        if allowWindowClose { completion(true); return }
        quitCompletion = completion
        requestWindowClose(followUp: .quit)
    }

    var arrangement: SessionArrangement {
        SessionArrangement(items: tabs.map { SessionItem(id: $0.id, groupID: $0.groupID) }, groups: groups)
    }
    var selectedTabID: TabID? { tabs.indices.contains(selected) ? tabs[selected].id : nil }
    var canMoveSessions: Bool {
        !allowWindowClose && !closePolicy.isBusy && windowProbe == nil && windowFollowUp == nil
            && window?.attachedSheet == nil && !fileEditor.isBusy
    }

    func contains(surface: GhosttyHost.Surface) -> Bool { tabs.contains { $0.view.surface === surface } }
    func tabs(with ids: Set<TabID>) -> [TerminalTab] { tabs.filter { ids.contains($0.id) } }
    func close(surface: GhosttyHost.Surface) {
        if let index = tabs.firstIndex(where: { $0.view.surface === surface }) { closeTab(at: index) }
    }

    func applyArrangement(_ next: SessionArrangement, adding incoming: [TerminalTab], selecting id: TabID?, focus: Bool) {
        let previous = selectedTabID
        let nativeFocus = fileEditor.isFocused || projectExplorer.isFocused ? window?.firstResponder : nil
        let ids = Set(next.ids)
        let pool = Dictionary(uniqueKeysWithValues: (tabs + incoming).map { ($0.id, $0) })
        for tab in tabs where !ids.contains(tab.id) {
            tab.content.isHidden = true
            tab.view.showSurface(false)
            tab.content.removeFromSuperview()
        }
        for tab in incoming { install(tab) }
        tabs = next.ids.compactMap { pool[$0] }
        for (index, item) in next.items.enumerated() { tabs[index].groupID = item.groupID }
        groups = next.groups
        selected = id.flatMap { next.ids.firstIndex(of: $0) } ?? 0
        if previous != selectedTabID || !incoming.isEmpty {
            updateSurfaceVisibility()
        } else { syncProjectExplorer() }
        reloadSidebar()
        if focus { focusSelected() }
        else if let nativeFocus { window?.makeFirstResponder(nativeFocus) }
    }

    func finishTransferOut() {
        guard tabs.isEmpty else { return }
        if fileEditor.hasUnsavedChanges {
            showEditor()
            fileEditor.focus()
        } else { closeEmptyWindow() }
    }

    func closeEmptyWindow() {
        guard tabs.isEmpty, !fileEditor.hasUnsavedChanges, !fileEditor.isBusy else { return }
        allowWindowClose = true
        window?.close()
    }

    func position(at point: NSPoint?, relativeTo source: NSWindow? = nil) {
        guard let window else { return }
        var frame = window.frame
        if let source { frame.size = source.frame.size }
        if let point { frame.origin = NSPoint(x: point.x - 100, y: point.y - frame.height + 24) }
        else if let source { frame.origin = NSPoint(x: source.frame.minX + 28, y: source.frame.minY - 28) }
        let screen = point.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } } ?? source?.screen ?? window.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: false)
    }

    func showAfterTransfer() {
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        applySidebarWidth(animated: false)
        focusSelected()
    }

    func rememberWindowFrame() {
        window?.setFrameAutosaveName(ChromeMemory.frameAutosaveName)
        window?.saveFrame(usingName: ChromeMemory.frameAutosaveName)
    }

    func resetTerminationApproval() {
        allowWindowClose = false
        (window as? SessionWindow)?.isInputLocked = false
        fileEditor.setInteractionLocked(false)
        for tab in tabs { tab.content.input?.setInteractionLocked(false) }
        if let terminationFirstResponder { window?.makeFirstResponder(terminationFirstResponder) }
        terminationFirstResponder = nil
    }

    private func lockApprovedWindow() {
        terminationFirstResponder = window?.firstResponder
        fileEditor.setInteractionLocked(true)
        for tab in tabs { tab.content.input?.setInteractionLocked(true) }
        (window as? SessionWindow)?.isInputLocked = true
        window?.makeFirstResponder(nil)
    }

    private func completeQuit(_ allowed: Bool) {
        let completion = quitCompletion
        quitCompletion = nil
        completion?(allowed)
    }

    init(workspace: SessionWindowManager, initialTab: Bool = true, restoreFrame: Bool = false) {
        self.workspace = workspace
        restoresFrame = restoreFrame
        let window = SessionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Boome"
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.contentView = SessionDropView(frame: window.contentView?.frame ?? .zero)
        super.init(window: window)
        window.delegate = self
        buildChrome()
        restoreChrome()
        if initialTab { newTab() }
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                GhosttyHost.shared.applySystemColorScheme()
                self?.applyTerminalChrome()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show() {
        guard let window else { return }
        let saved = UserDefaults.standard.string(forKey: ChromeMemory.frameDefaultsKey)
        if restoresFrame && ChromeMemory.hasSavedFrame(saved) {
            window.setFrameUsingName(ChromeMemory.frameAutosaveName)
        } else {
            window.center()
        }
        if restoresFrame { window.setFrameAutosaveName(ChromeMemory.frameAutosaveName) }
        applySidebarWidth(animated: false)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        placeSidebarToggle()
        focusSelected()
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
        applySidebarWidth(animated: true)
        rememberChrome()
        if !fileEditor.isFocused && !projectExplorer.isFocused { focusSelected() }
    }

    func toggleProjectExplorer() {
        let wasFocused = projectExplorer.isFocused
        explorerVisible.toggle()
        syncProjectExplorer()
        projectExplorer.setActive(explorerVisible)
        applySidebarWidth(animated: true)
        rememberChrome()
        if explorerVisible { projectExplorer.focus() }
        else if wasFocused { focusSelected() }
    }

    func toggleEditor() {
        if editorVisible { closeEditor() }
        else { showEditor(); fileEditor.focus() }
    }

    func closeEditor() {
        fileEditor.prepareToLeave { [weak self] allowed in
            guard allowed, let self else { return }
            self.editorVisible = false
            self.fileEditor.isHidden = true
            self.applySidebarWidth(animated: true)
            self.focusSelected()
        }
    }

    func saveFile() { fileEditor.save() }

    private func showEditor() {
        editorVisible = true
        fileEditor.isHidden = false
        applySidebarWidth(animated: true)
    }

    /// The system tab command stays in this window.
    @objc override func newWindowForTab(_ sender: Any?) {
        newTab()
    }

    func newTab() {
        guard workspace?.isPreparingTermination != true, canMoveSessions,
              let tab = createTab(replacingLast: false) else { return }
        install(tab)
        if tabs.indices.contains(selected), let group = tabs[selected].groupID,
           let last = tabs.lastIndex(where: { $0.groupID == group }) {
            tab.groupID = group
            groups[group]?.collapsed = false
            tabs.insert(tab, at: last + 1)
            selected = last + 1
        } else {
            tabs.append(tab)
            selected = tabs.count - 1
        }
        updateSurfaceVisibility()
        reloadSidebar()
        focusSelected()
    }

    func closeCurrentTab() {
        closeTab(at: selected)
    }

    func cycle(_ cycle: GhosttyHost.Cycle) {
        guard workspace?.isPreparingTermination != true else { return }
        let move: TabNavigation.Move
        switch cycle {
        case .previous: move = .previous
        case .next: move = .next
        case .last: move = .last
        case .index(let number): move = .index(number)
        }
        guard let landing = TabNavigation.landing(count: tabs.count, selected: selected, move: move) else { return }
        let pulse = SelectionPulse.plays(
            marked: landing.markKeyboardLanding,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        select(landing.index, pulse: pulse)
    }

    private func requestWindowClose(followUp: WindowFollowUp) {
        if allowWindowClose {
            performWindowClose(followUp)
            return
        }
        if closePolicy.isBusy {
            _ = closePolicy.reportWindow(live: [])
            return
        }
        if windowProbe != nil { return }
        let ids = tabs.map(\.id)
        if ids.isEmpty {
            performWindowClose(followUp)
            return
        }
        windowFollowUp = followUp
        windowProbe = WindowProbe(remaining: Set(ids), live: [])
        for tab in tabs {
            host.requestClose(tab.view.surface)
        }
    }

    private func buildChrome() {
        guard let content = window?.contentView else { return }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        projectExplorer.translatesAutoresizingMaskIntoConstraints = false
        fileEditor.translatesAutoresizingMaskIntoConstraints = false
        fileEditor.isHidden = true
        content.addSubview(sidebar)
        content.addSubview(projectExplorer)
        content.addSubview(terminalHost)
        content.addSubview(fileEditor)

        for line in [separator, explorerSeparator, editorSeparator] {
            line.wantsLayer = true
            line.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(line)
        }

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 200)
        separatorWidth = separator.widthAnchor.constraint(equalToConstant: 1)
        explorerWidth = projectExplorer.widthAnchor.constraint(equalToConstant: 0)
        explorerSeparatorWidth = explorerSeparator.widthAnchor.constraint(equalToConstant: 0)
        editorWidth = fileEditor.widthAnchor.constraint(equalToConstant: 0)
        editorSeparatorWidth = editorSeparator.widthAnchor.constraint(equalToConstant: 0)
        let safe = content.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: safe.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarWidth,
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: safe.topAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            separatorWidth,
            projectExplorer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            projectExplorer.topAnchor.constraint(equalTo: safe.topAnchor),
            projectExplorer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            explorerWidth,
            explorerSeparator.leadingAnchor.constraint(equalTo: projectExplorer.trailingAnchor),
            explorerSeparator.topAnchor.constraint(equalTo: safe.topAnchor),
            explorerSeparator.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            explorerSeparatorWidth,
            terminalHost.leadingAnchor.constraint(equalTo: explorerSeparator.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: safe.topAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editorSeparator.leadingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            editorSeparator.topAnchor.constraint(equalTo: safe.topAnchor),
            editorSeparator.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editorSeparatorWidth,
            fileEditor.leadingAnchor.constraint(equalTo: editorSeparator.trailingAnchor),
            fileEditor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            fileEditor.topAnchor.constraint(equalTo: safe.topAnchor),
            fileEditor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editorWidth,
        ])

        sidebar.onSelect = { [weak self] id in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.select(index)
        }
        sidebar.onClose = { [weak self] id in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.closeTab(at: index)
        }
        sidebar.onNew = { [weak self] in self?.newTab() }
        sidebar.onMenu = { [weak self] id, event in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.showTabMenu(at: index, event: event)
        }
        sidebar.onToggleGroup = { [weak self] id in
            guard let self, self.canMoveSessions, self.workspace?.isPreparingTermination != true else { return }
            self.groups[id]?.collapsed.toggle()
            self.reloadSidebar()
        }
        sidebar.onGroupMenu = { [weak self] id, event in self?.showGroupMenu(id, event: event) }
        sidebar.onBeginDrag = { [weak self] item in
            guard let self else { return nil }
            return self.workspace?.beginDrag(item, from: self)
        }
        sidebar.onDragItem = { [weak self] token in self?.workspace?.dragItem(for: token) }
        sidebar.onCanDrop = { [weak self] token, target in
            guard let self else { return false }
            return self.workspace?.canDrop(token, into: self, at: target) == true
        }
        sidebar.onDrop = { [weak self] token, target in
            guard let self else { return false }
            return self.workspace?.drop(token, into: self, at: target) == true
        }
        sidebar.onDragEnded = { [weak self] token, point, operation in
            self?.workspace?.endDrag(token, at: point, operation: operation)
        }
        if let content = content as? SessionDropView {
            content.onCanDrop = { [weak self] token in
                guard let self else { return false }
                return self.workspace?.canDrop(token, into: self, at: .end, background: true) == true
            }
            content.onDrop = { [weak self] token in
                guard let self else { return false }
                return self.workspace?.drop(token, into: self, at: .end) == true
            }
        }
        projectExplorer.onClose = { [weak self] in self?.toggleProjectExplorer() }
        projectExplorer.onReturnToTerminal = { [weak self] in self?.focusSelected() }
        projectExplorer.onOpenFile = { [weak self] url in self?.fileEditor.open(url) }
        fileEditor.onShow = { [weak self] in self?.showEditor() }
        fileEditor.onClose = { [weak self] in self?.closeEditor() }
        installSidebarToggle()
    }

    /// Left title-bar control, in the same view as the traffic lights so a
    /// click reaches it. Collapsing the sidebar does not remove it.
    private func installSidebarToggle() {
        guard let window,
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = zoom.superview else { return }
        sidebarToggle.onPress = { [weak self] in
            self?.toggleSidebar()
        }
        explorerToggle.onPress = { [weak self] in self?.toggleProjectExplorer() }
        titlebar.addSubview(sidebarToggle)
        titlebar.addSubview(explorerToggle)
        editorToggle.onPress = { [weak self] in self?.toggleEditor() }
        titlebar.addSubview(editorToggle)
        editorToggle.autoresizingMask = [.minXMargin]
        zoom.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(placeSidebarToggle),
            name: NSView.frameDidChangeNotification,
            object: zoom
        )
        placeSidebarToggle()
        syncSidebarToggle()
    }

    @objc private func placeSidebarToggle() {
        guard let zoom = window?.standardWindowButton(.zoomButton) else { return }
        guard let titlebar = sidebarToggle.superview else { return }
        let z = titlebar.convert(zoom.frame, from: zoom.superview)
        let side: CGFloat = 28
        sidebarToggle.frame = NSRect(
            x: (z.maxX + 8).rounded(),
            y: (z.midY - side / 2).rounded(),
            width: side,
            height: side
        )
        explorerToggle.frame = sidebarToggle.frame.offsetBy(dx: side + 4, dy: 0)
        editorToggle.frame = NSRect(x: max(explorerToggle.frame.maxX + 8, titlebar.bounds.width - side - 8), y: sidebarToggle.frame.minY, width: side, height: side)
    }

    /// Open on first launch. A saved collapse is restored. The frame is AppKit's autosave.
    private func restoreChrome() {
        let stored = UserDefaults.standard
        let placement = stored.string(forKey: "BoomeTabPlacement")
        sidebarCollapsed = ChromeMemory.sidebarCollapsed(
            stored: stored.object(forKey: ChromeMemory.collapsedKey) as? Bool,
            obsoletePlacement: placement
        )
        stored.removeObject(forKey: "BoomeTabPlacement")
        stored.set(sidebarCollapsed, forKey: ChromeMemory.collapsedKey)
        explorerVisible = stored.bool(forKey: ProjectExplorerMemory.visibleKey)
        projectExplorer.setActive(explorerVisible)
        applySidebarWidth(animated: false)
        applyTerminalChrome()
    }

    private func rememberChrome() {
        UserDefaults.standard.set(sidebarCollapsed, forKey: ChromeMemory.collapsedKey)
        UserDefaults.standard.set(explorerVisible, forKey: ProjectExplorerMemory.visibleKey)
    }

    private func syncSidebarToggle() {
        sidebarToggle.note(collapsed: isSidebarCollapsed)
        explorerToggle.note(collapsed: !explorerVisible)
        editorToggle.note(collapsed: !editorVisible)
    }

    /// Sidebar and title bar use the terminal background, so the window is one surface.
    private func applyTerminalChrome() {
        let background = host.terminalBackground()
        (window?.contentView as? SessionDropView)?.use(background: background)
        let appearance = NSAppearance(named: BoomeChrome.isDark(background) ? .darkAqua : .aqua)
        window?.backgroundColor = background
        window?.appearance = appearance
        separator.layer?.backgroundColor = BoomeChrome.hairline(on: background).cgColor
        explorerSeparator.layer?.backgroundColor = BoomeChrome.hairline(on: background).cgColor
        editorSeparator.layer?.backgroundColor = BoomeChrome.hairline(on: background).cgColor
        fileEditor.use(background: background)
        for tab in tabs { tab.content.input?.use(background: background) }
        sidebar.use(background: background)
        projectExplorer.use(background: background)
        sidebarToggle.use(background: background)
        explorerToggle.use(background: background)
        editorToggle.use(background: background)
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
        window?.tabbingMode = .disallowed
    }

    private func createTab(replacingLast: Bool) -> TerminalTab? {
        let previous = tabs.indices.contains(selected) ? tabs[selected] : nil
        let inherited = previous.flatMap { host.inheritedWorkingDirectory(from: $0.view.surface) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = TabDirectory.choose(inherited: inherited, home: home)
        let view = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let surface = host.makeSurface(
            view: view,
            workingDirectory: directory,
            contextTab: !tabs.isEmpty && !replacingLast
        ) else { return nil }
        view.attach(surface)
        let tab = TerminalTab(id: TerminalTab.allocateID(), view: view)
        tab.workingDirectory = directory
        return tab
    }

    private func install(_ tab: TerminalTab) {
        let view = tab.content
        view.input?.use(background: host.terminalBackground())
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
    }

    private func select(_ index: Int, pulse: Bool = false) {
        guard workspace?.isPreparingTermination != true, tabs.indices.contains(index) else { return }
        selected = index
        if let group = tabs[index].groupID { groups[group]?.collapsed = false }
        updateSurfaceVisibility()
        reloadSidebar(pulse: pulse)
        focusSelected()
    }

    private func focusSelected() {
        guard !allowWindowClose, tabs.indices.contains(selected), let window else { return }
        tabs[selected].content.focus()
        tabs[selected].view.focusSurface(window.isKeyWindow && window.firstResponder === tabs[selected].view)
        syncWindowTitles()
    }

    private func reloadSidebar(pulse: Bool = false) {
        let rows = TabPresentation.disambiguate(
            tabs.map { TabPresentation.make(label: $0.label, customTitle: $0.tabTitle != nil) }
        )
        sidebar.reload(arrangement: arrangement, rows: rows, selected: selectedTabID, pulse: pulse)
        syncWindowTitles()
    }

    private func remove(_ tab: TerminalTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        let created = tabs.count == 1 ? createTab(replacingLast: true) : nil
        if tabs.count == 1, created == nil { return }
        var list = TabList(ids: tabs.map(\.id), selected: selected)
        guard list.close(tab.id, replacement: created?.id ?? tab.id) != nil else { return }
        if let created { install(created) }
        tab.content.removeFromSuperview()
        tab.view.releaseSurface()
        var pool = tabs
        if let created { pool.append(created) }
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        tabs = list.ids.compactMap { byID[$0] }
        selected = list.selected
        var order = arrangement
        order.pruneEmptyGroups()
        groups = order.groups
        updateSurfaceVisibility()
        reloadSidebar()
        focusSelected()
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setTitle title: String) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        tab.terminalTitle = title
        reloadSidebar()
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setTabTitle title: String) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        tab.tabTitle = title.isEmpty ? nil : title
        reloadSidebar()
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setWorkingDirectory path: String) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        tab.workingDirectory = path
        reloadSidebar()
        syncProjectExplorer()
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, closeProcessAlive alive: Bool) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        if var probe = windowProbe {
            guard probe.remaining.contains(tab.id) else { return }
            probe.remaining.remove(tab.id)
            if alive { probe.live.append(tab.id) }
            if !probe.remaining.isEmpty {
                windowProbe = probe
                return
            }
            windowProbe = nil
            let live = probe.live
            switch closePolicy.reportWindow(live: live) {
            case .ask(let subject):
                presentConfirm(subject)
            case .closeWindowNow:
                performWindowClose(windowFollowUp ?? .closeWindow)
            case .refused, .hold, .destroy(_), .destroyBatch(_):
                break
            }
            return
        }
        switch closePolicy.reportTab(tab.id, alive: alive) {
        case .destroy(let id):
            destroyTabs([id])
        case .destroyBatch(let ids):
            destroyTabs(ids)
        case .ask(let subject):
            presentConfirm(subject)
        case .refused, .closeWindowNow, .hold:
            break
        }
    }

    private func destroyTabs(_ ids: [TabID]) {
        for id in ids {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            remove(tab)
        }
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursor: GhosttyHost.CursorStyle) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        tab.view.noteCursor(cursor)
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursorHidden hidden: Bool) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        tab.view.noteCursorHidden(hidden)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if workspace?.isPreparingTermination == true { return false }
        if allowWindowClose { return true }
        requestWindowClose(followUp: .closeWindow)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !fileEditor.isFocused && !projectExplorer.isFocused { focusSelected() }
    }

    func windowDidResignKey(_ notification: Notification) {
        for tab in tabs { tab.view.focusSurface(false) }
    }

    func windowDidResize(_ notification: Notification) {
        applySidebarWidth(animated: false)
        sidebar.revealSelection()
    }

    func windowWillClose(_ notification: Notification) {
        for tab in tabs {
            tab.content.removeFromSuperview()
            tab.view.releaseSurface()
        }
        tabs.removeAll()
        groups.removeAll()
        workspace?.didClose(self)
    }


    private func showTabMenu(at index: Int, event: NSEvent) {
        guard tabs.indices.contains(index), canMoveSessions, workspace?.isPreparingTermination != true else { return }
        let id = tabs[index].id
        let menu = NSMenu()
        menu.autoenablesItems = false
        addAction("New Tab", to: menu) { [weak self] in self?.newTab() }
        addAction("Close Tab", to: menu) { [weak self] in self?.requestClose(ids: [id]) }
        addAction("Close Other Tabs", to: menu, enabled: tabs.count > 1) { [weak self] in
            guard let self else { return }
            self.requestClose(ids: self.tabs.map(\.id).filter { $0 != id })
        }
        addAction("Close Tabs to the Right", to: menu, enabled: index < tabs.count - 1) { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.requestClose(ids: Array(self.tabs.dropFirst(index + 1).map(\.id)))
        }
        menu.addItem(.separator())
        addAction("New Group", to: menu) { [weak self] in
            guard let self else { return }
            var next = self.arrangement
            next.removeFromGroup(id)
            guard let index = next.items.firstIndex(where: { $0.id == id }) else { return }
            let group = SessionGroup(id: UUID(), name: next.nextGroupName)
            next.groups[group.id] = group
            next.items[index].groupID = group.id
            self.applyArrangement(next, adding: [], selecting: self.selectedTabID, focus: false)
        }
        if let active = selectedTabID, active != id, tabs[index].groupID == nil || tabs[index].groupID != tabs[selected].groupID {
            addAction("Group with Active Tab", to: menu) { [weak self] in
                guard let self else { return }
                self.workspace?.transfer(.tab(id), from: self, to: self, at: .intoTab(active))
            }
        }
        if tabs[index].groupID != nil {
            addAction("Remove from Group", to: menu) { [weak self] in
                guard let self else { return }
                var next = self.arrangement
                next.removeFromGroup(id)
                self.applyArrangement(next, adding: [], selecting: self.selectedTabID, focus: false)
            }
        }
        var seen: Set<UUID> = []
        let destinations = tabs.compactMap(\.groupID).filter { seen.insert($0).inserted && $0 != tabs[index].groupID }
        if !destinations.isEmpty {
            let parent = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for group in destinations {
                addAction(groups[group]?.name ?? "Group", to: submenu) { [weak self] in
                    guard let self else { return }
                    self.workspace?.transfer(.tab(id), from: self, to: self, at: .intoGroup(group))
                }
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        addWindowActions(for: .tab(id), to: menu)
        NSMenu.popUpContextMenu(menu, with: event, for: sidebar)
    }

    private func showGroupMenu(_ id: UUID, event: NSEvent) {
        guard groups[id] != nil, canMoveSessions, workspace?.isPreparingTermination != true else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        addAction("Rename Group…", to: menu) { [weak self] in self?.renameGroup(id) }
        addAction("Ungroup", to: menu) { [weak self] in
            guard let self else { return }
            var next = self.arrangement
            next.ungroup(id)
            self.applyArrangement(next, adding: [], selecting: self.selectedTabID, focus: false)
        }
        addWindowActions(for: .group(id), to: menu)
        menu.addItem(.separator())
        addAction("Close Group", to: menu) { [weak self] in
            guard let self else { return }
            self.requestClose(ids: self.arrangement.ids(for: .group(id)))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: sidebar)
    }

    private func addWindowActions(for item: SessionDragItem, to menu: NSMenu) {
        addAction("Move to New Window", to: menu, enabled: arrangement.ids(for: item).count < tabs.count) { [weak self] in
            guard let self else { return }
            self.workspace?.moveToNewWindow(item, from: self)
        }
        let destinations = workspace?.controllers.filter { $0 !== self && $0.canMoveSessions } ?? []
        guard !destinations.isEmpty else { return }
        let parent = NSMenuItem(title: "Move to Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, destination) in destinations.enumerated() {
            addAction("\(index + 1). \(destination.window?.title ?? "Boome")", to: submenu) { [weak self, weak destination] in
                guard let self, let destination else { return }
                self.workspace?.transfer(item, from: self, to: destination)
            }
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func renameGroup(_ id: UUID) {
        guard let window, let group = groups[id] else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        let field = NSTextField(string: group.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.groups[id] != nil else { return }
            let name = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !name.isEmpty else { return }
            self.groups[id]?.name = name
            self.reloadSidebar()
        }
    }

    @discardableResult
    private func addAction(_ title: String, to menu: NSMenu, enabled: Bool = true, perform: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = SessionMenuAction(perform)
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard canMoveSessions, workspace?.isPreparingTermination != true else { return }
        (sender.representedObject as? SessionMenuAction)?.perform()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        requestClose(ids: [tabs[index].id])
    }

    private func requestClose(ids: [TabID]) {
        guard workspace?.isPreparingTermination != true else { return }
        if closePolicy.isBusy || windowProbe != nil { return }
        let targets = ids.filter { id in tabs.contains { $0.id == id } }
        if targets.count > 1, !closePolicy.beginBatch(targets) { return }
        for id in targets {
            guard let tab = tabs.first(where: { $0.id == id }) else { continue }
            host.requestClose(tab.view.surface)
        }
    }

    private func presentConfirm(_ subject: ClosePolicy.Subject) {
        guard let window else {
            _ = closePolicy.resolve(confirmed: false)
            return
        }
        guard confirmAlert == nil else { return }
        let alert = NSAlert()
        switch subject {
        case .tab(let id):
            let label = tabs.first(where: { $0.id == id })?.label ?? "this terminal"
            alert.messageText = "Close this terminal?"
            alert.informativeText = "Closing \(label) may stop a running program or discard unsubmitted command input."
        case .tabs(let ids):
            alert.messageText = "Close these terminals?"
            alert.informativeText = "This closes all \(ids.count) tabs and may stop running programs or discard unsubmitted command input."
        case .window:
            alert.messageText = "Close this window?"
            alert.informativeText = "Closing may stop running programs or discard unsubmitted command input."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        confirmAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.confirmAlert = nil
            let confirmed = response == .alertFirstButtonReturn
            switch self.closePolicy.resolve(confirmed: confirmed) {
            case .destroy(let ids):
                for id in ids {
                    guard let tab = self.tabs.first(where: { $0.id == id }) else { continue }
                    self.remove(tab)
                }
            case .closeWindow:
                self.performWindowClose(self.windowFollowUp ?? .closeWindow)
            case .keep, .none:
                self.windowFollowUp = nil
                self.completeQuit(false)
            }
        }
    }

    private func performWindowClose(_ followUp: WindowFollowUp) {
        fileEditor.prepareToLeave { [weak self] allowed in
            guard let self else { return }
            self.windowFollowUp = nil
            guard allowed else { self.completeQuit(false); return }
            self.allowWindowClose = true
            switch followUp {
            case .closeWindow: self.window?.close()
            case .quit:
                self.lockApprovedWindow()
                self.completeQuit(true)
            }
        }
    }

    private func applySidebarWidth(animated: Bool) {
        guard !adjustingLayout else { return }
        adjustingLayout = true
        defer { adjustingLayout = false }
        let width: CGFloat = sidebarCollapsed ? 0 : 200
        let minimum = WorkspaceLayout.minimumWidth(tabSidebarWidth: width, explorer: explorerVisible, editor: editorVisible)
        if let window {
            window.minSize.width = minimum
            if window.frame.width < minimum {
                var frame = window.frame
                frame.size.width = minimum
                if let visible = window.screen?.visibleFrame { frame.origin.x = min(frame.origin.x, visible.maxX - minimum) }
                window.setFrame(frame, display: true)
            }
        }
        syncSidebarToggle()
        placeSidebarToggle()
        let hairline: CGFloat = sidebarCollapsed ? 0 : 1
        let panels = WorkspaceLayout.widths(windowWidth: window?.contentView?.bounds.width ?? 1100, tabSidebarWidth: width, explorer: explorerVisible, editor: editorVisible)
        let projectWidth = panels.explorer
        let projectHairline: CGFloat = explorerVisible ? 1 : 0
        let editWidth = panels.editor
        let editHairline: CGFloat = editorVisible ? 1 : 0
        let changes = {
            self.sidebarWidth.constant = width
            self.separatorWidth.constant = hairline
            self.explorerWidth.constant = projectWidth
            self.explorerSeparatorWidth.constant = projectHairline
            self.editorWidth.constant = editWidth
            self.editorSeparatorWidth.constant = editHairline
        }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                changes()
                self.sidebarWidth.animator().constant = width
                self.separatorWidth.animator().constant = hairline
                self.explorerWidth.animator().constant = projectWidth
                self.explorerSeparatorWidth.animator().constant = projectHairline
                self.editorWidth.animator().constant = editWidth
                self.editorSeparatorWidth.animator().constant = editHairline
            }
        } else {
            changes()
        }
    }

    private func updateSurfaceVisibility() {
        for (offset, tab) in tabs.enumerated() {
            tab.content.isHidden = offset != selected
            tab.view.showSurface(offset == selected)
        }
        syncProjectExplorer()
    }

    private func syncProjectExplorer() {
        let directory = tabs.indices.contains(selected) ? tabs[selected].workingDirectory : nil
        projectExplorer.follow(directory: directory)
    }

    private func syncWindowTitles() {
        window?.title = tabs.indices.contains(selected) ? tabs[selected].label : "Boome"
    }
}
