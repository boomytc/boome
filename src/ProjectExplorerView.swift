import AppKit

private final class ProjectContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ProjectNode: NSObject {
    let entry: ProjectEntry?
    let message: String?
    var children: [ProjectNode] = []
    var loaded = false
    var loading = false

    init(entry: ProjectEntry) {
        self.entry = entry
        message = nil
        super.init()
        if entry.isDirectory { children = [ProjectNode(message: "Loading…")] }
    }

    init(message: String) {
        entry = nil
        self.message = message
        super.init()
    }
}

private final class ProjectOutlineView: NSOutlineView {
    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?
    var makeMenu: (() -> NSMenu)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?()
        } else if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { deselectAll(nil) }
        return makeMenu?()
    }
}

private final class ProjectRowView: NSTableRowView {
    var fill = BoomeChrome.selectionFill(on: BoomeChrome.fallbackBackground)

    override func drawSelection(in dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

final class ProjectExplorerView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onClose: (() -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onReturnToTerminal: (() -> Void)?
    private(set) var rootURL: URL?
    var followsActiveSession: Bool { pinnedDirectory == nil }
    var isFocused: Bool { (window?.firstResponder as? NSView)?.isDescendant(of: self) == true }

    private let defaults: UserDefaults
    private let content = ProjectContentView()
    private let title = NSTextField(labelWithString: "Project Explorer")
    private let options = NSButton()
    private let refresh = NSButton()
    private let close = NSButton()
    private let follow = NSButton()
    private let scroll = NSScrollView()
    private let outline = ProjectOutlineView()
    private let queue = DispatchQueue(label: "com.boom.boome.project-explorer", qos: .userInitiated)
    private var background = BoomeChrome.fallbackBackground
    private var active = false
    private var pinnedDirectory: URL?
    private var currentDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var showHidden: Bool
    private var root: ProjectNode?
    private var generation = 0
    private var expandedPaths: Set<URL> = []
    private var selectedURL: URL?
    private var restoring = false

    override var isFlipped: Bool { true }

    init(frame: NSRect, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showHidden = defaults.bool(forKey: ProjectExplorerMemory.hiddenFilesKey)
        if let path = defaults.string(forKey: ProjectExplorerMemory.directoryKey), path.hasPrefix("/") {
            pinnedDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Project Explorer")
        setAccessibilityIdentifier("ProjectExplorer")
        addSubview(content)
        for view in [title, options, refresh, close, follow, scroll] { content.addSubview(view) }
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        configure(options, symbol: "ellipsis", label: "Project Explorer options", action: #selector(showOptions(_:)))
        configure(refresh, symbol: "arrow.clockwise", label: "Refresh Project Explorer", action: #selector(refreshTree(_:)))
        configure(close, symbol: "xmark", label: "Close Project Explorer", action: #selector(closePanel(_:)))
        follow.isBordered = false
        follow.font = .systemFont(ofSize: 11)
        follow.alignment = .left
        follow.target = self
        follow.action = #selector(followSession(_:))
        follow.toolTip = "跟随当前会话的工作目录；选择文件夹后可点此恢复跟随"
        follow.setAccessibilityIdentifier("ProjectExplorerFollowSession")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("File"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 26
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(activateSelection(_:))
        outline.setAccessibilityIdentifier("ProjectExplorerTree")
        outline.setAccessibilityLabel("Project files")
        outline.onActivate = { [weak self] in self?.activateSelection(nil) }
        outline.onEscape = { [weak self] in self?.onReturnToTerminal?() }
        outline.makeMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        use(background: background)
        updateFollowButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Keep the tree's controls usable while its outer width animates to zero.
        let width = max(180, bounds.width)
        content.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        title.frame = NSRect(x: 12, y: 12, width: max(0, width - 94), height: 18)
        options.frame = NSRect(x: width - 78, y: 8, width: 24, height: 26)
        refresh.frame = NSRect(x: width - 54, y: 8, width: 24, height: 26)
        close.frame = NSRect(x: width - 30, y: 8, width: 24, height: 26)
        scroll.frame = NSRect(x: 0, y: 42, width: width, height: max(0, bounds.height - 72))
        follow.frame = NSRect(x: 12, y: max(42, bounds.height - 27), width: width - 24, height: 22)
        outline.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }

    func use(background: NSColor) {
        self.background = background
        layer?.backgroundColor = background.cgColor
        scroll.backgroundColor = background
        outline.backgroundColor = background
        title.textColor = BoomeChrome.text(selected: true, on: background)
        let secondary = BoomeChrome.secondaryText(selected: false, on: background)
        for button in [options, refresh, close, follow] { button.contentTintColor = secondary }
        outline.reloadData()
    }

    func setActive(_ visible: Bool) {
        active = visible
        isHidden = !visible
        if visible { displayDirectory() }
    }

    func focus() { window?.makeFirstResponder(outline) }

    func follow(directory: String?) {
        currentDirectory = directory.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        if active && followsActiveSession { displayDirectory() }
    }

    func useDirectory(_ directory: URL?) {
        pinnedDirectory = directory?.standardizedFileURL
        if let pinnedDirectory { defaults.set(pinnedDirectory.path, forKey: ProjectExplorerMemory.directoryKey) }
        else { defaults.removeObject(forKey: ProjectExplorerMemory.directoryKey) }
        updateFollowButton()
        if active { displayDirectory() }
    }

    private func displayDirectory() {
        let next = (pinnedDirectory ?? currentDirectory).standardizedFileURL
        guard rootURL != next else { return }
        rootURL = next
        expandedPaths = [next]
        selectedURL = nil
        reloadTree()
    }

    private func reloadTree() {
        guard let rootURL else { return }
        generation += 1
        let node = ProjectNode(entry: ProjectEntry(url: rootURL, isDirectory: true, isSymbolicLink: false))
        root = node
        restoring = true
        outline.reloadData()
        if expandedPaths.contains(rootURL) { outline.expandItem(node) }
        restoring = false
        toolTip = rootURL.path
        updateFollowButton()
    }

    private func load(_ node: ProjectNode) {
        guard let entry = node.entry, entry.isDirectory, !node.loaded, !node.loading else { return }
        node.loading = true
        let token = generation
        let includeHidden = showHidden
        queue.async { [weak self] in
            let result = Result { try ProjectFiles.children(of: entry.url, showHidden: includeHidden) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                node.loading = false
                node.loaded = true
                switch result {
                case .success(let entries):
                    node.children = entries.isEmpty ? [ProjectNode(message: "No visible files")] : entries.map(ProjectNode.init(entry:))
                case .failure(let error):
                    node.children = [ProjectNode(message: "Cannot read folder: \(error.localizedDescription)")]
                }
                self.restoring = true
                self.outline.reloadItem(node, reloadChildren: true)
                for child in node.children {
                    if let url = child.entry?.url, self.expandedPaths.contains(url) { self.outline.expandItem(child) }
                }
                self.restoreSelection(in: node)
                self.restoring = false
            }
        }
    }

    private func restoreSelection(in node: ProjectNode) {
        for child in [node] + node.children {
            if child.entry?.url == selectedURL {
                let row = outline.row(forItem: child)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
        }
    }

    private func updateFollowButton() {
        follow.title = followsActiveSession ? "Following current session" : "Use current session directory"
        follow.isEnabled = !followsActiveSession
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func showOptions(_ sender: NSButton) {
        optionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    private func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        add("Choose Project Folder…", to: menu, action: #selector(chooseFolder(_:)))
        let current = add("Follow Current Session", to: menu, action: #selector(followSession(_:)))
        current.state = followsActiveSession ? .on : .off
        menu.addItem(.separator())
        let hidden = add("Show Hidden Files", to: menu, action: #selector(toggleHidden(_:)))
        hidden.state = showHidden ? .on : .off
        add("Refresh", to: menu, action: #selector(refreshTree(_:)))
        if rootURL != nil { add("Reveal Project in Finder", to: menu, action: #selector(revealProject(_:))) }
        return menu
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if selectedEntry != nil {
            add("Open", to: menu, action: #selector(openSelection(_:)))
            add("Open Externally", to: menu, action: #selector(openExternally(_:)))
            add("Reveal in Finder", to: menu, action: #selector(revealSelection(_:)))
            add("Copy Path", to: menu, action: #selector(copyPath(_:)))
            menu.addItem(.separator())
        }
        for item in optionsMenu().items { menu.addItem(item.copy() as! NSMenuItem) }
        return menu
    }

    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose Project Folder"
        picker.prompt = "Open Folder"
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = rootURL
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = picker.url else { return }
            self?.useDirectory(url)
            self?.focus()
        }
    }

    @objc private func followSession(_ sender: Any?) { useDirectory(nil) }
    @objc private func closePanel(_ sender: Any?) { onClose?() }
    @objc private func refreshTree(_ sender: Any?) { reloadTree() }

    @objc private func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        defaults.set(showHidden, forKey: ProjectExplorerMemory.hiddenFilesKey)
        reloadTree()
    }

    private var selectedEntry: ProjectEntry? { (outline.item(atRow: outline.selectedRow) as? ProjectNode)?.entry }

    @objc private func activateSelection(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.selectedRow) as? ProjectNode, let entry = node.entry else { return }
        if entry.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { outline.expandItem(node) }
        } else {
            openSelection(sender)
        }
    }

    @objc private func openSelection(_ sender: Any?) {
        guard let entry = selectedEntry else { return }
        if !entry.isDirectory, let onOpenFile { onOpenFile(entry.url) }
        else { openExternally(sender) }
    }

    @objc private func openExternally(_ sender: Any?) {
        guard let url = selectedEntry?.url else { return }
        if !NSWorkspace.shared.open(url), let window {
            let alert = NSAlert()
            alert.messageText = "Could not open \(url.lastPathComponent)"
            alert.informativeText = "Choose an application for this file in Finder, then try again."
            alert.beginSheetModal(for: window)
        }
    }

    @objc private func revealSelection(_ sender: Any?) {
        if let url = selectedEntry?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func revealProject(_ sender: Any?) {
        if let rootURL { NSWorkspace.shared.activateFileViewerSelecting([rootURL]) }
    }

    @objc private func copyPath(_ sender: Any?) {
        guard let path = selectedEntry?.url.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? ProjectNode { return node.children.count }
        return root == nil ? 0 : 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? ProjectNode { return node.children[index] }
        return root!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ProjectNode)?.entry?.isDirectory == true
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? ProjectNode { load(node) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? ProjectNode, let url = node.entry?.url { expandedPaths.insert(url) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !restoring, let node = notification.userInfo?["NSObject"] as? ProjectNode, let url = node.entry?.url { expandedPaths.remove(url) }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !restoring { selectedURL = selectedEntry?.url }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? ProjectNode)?.entry != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ProjectNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.entry?.name ?? node.message ?? "")
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13, weight: node === root ? .semibold : .regular)
        label.textColor = node.entry == nil
            ? BoomeChrome.secondaryText(selected: false, on: background)
            : BoomeChrome.text(selected: true, on: background)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = cell.leadingAnchor
        var inset: CGFloat = 3
        if let entry = node.entry {
            let symbol = entry.isSymbolicLink ? "arrow.turn.up.right" : entry.isDirectory ? "folder" : "doc"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = BoomeChrome.secondaryText(selected: false, on: background)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.setAccessibilityElement(false)
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 15),
                icon.heightAnchor.constraint(equalToConstant: 15),
            ])
            leading = icon.trailingAnchor
            inset = 6
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: inset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = node.entry?.url.path ?? node.message
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = ProjectRowView()
        row.fill = BoomeChrome.selectionFill(on: background)
        return row
    }
}
