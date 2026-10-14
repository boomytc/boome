import AppKit

final class TerminalTab {
    let ordinal: Int
    let view: TerminalSurfaceView
    var terminalTitle = ""
    var tabTitle: String?
    var workingDirectory: String?

    init(ordinal: Int, view: TerminalSurfaceView) {
        self.ordinal = ordinal
        self.view = view
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

/// Keeps a short tab list under the header. The default clip view pins a
/// short document to the bottom of the sidebar.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class RowCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: padded(rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: padded(rect))
    }

    private func padded(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 8, y: rect.minY + 2, width: max(0, rect.width - 16), height: max(0, rect.height - 4))
    }
}

final class TabSidebar: NSView {
    var onSelect: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let headerIcon = NSImageView()
    private let headerTitle = NSTextField(labelWithString: "Boome")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let addButton = NSButton()
    private var rows: [NSButton] = []
    private var labels: [String] = []
    private var selected = 0
    private var surfaceBackground = BoomeChrome.fallbackBackground

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        headerIcon.imageScaling = .scaleNone
        headerIcon.image = BoomeChrome.icon(pointSize: 28)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerIcon)

        headerTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerTitle)

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let clip = TopClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        addButton.image = plusImage()
        addButton.imagePosition = .imageLeading
        addButton.imageHugsTitle = true
        addButton.imageScaling = .scaleNone
        addButton.alignment = .center
        addButton.isBordered = false
        addButton.wantsLayer = true
        addButton.layer?.cornerRadius = 8
        addButton.layer?.masksToBounds = true
        addButton.target = self
        addButton.action = #selector(addPressed)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setAccessibilityLabel("New Tab")
        addSubview(addButton)

        NSLayoutConstraint.activate([
            headerIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            headerIcon.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            headerIcon.widthAnchor.constraint(equalToConstant: 28),
            headerIcon.heightAnchor.constraint(equalToConstant: 28),
            headerTitle.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 8),
            headerTitle.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            addButton.heightAnchor.constraint(equalToConstant: 34),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func reload(labels: [String], selected index: Int) {
        self.labels = labels
        selected = index
        for row in rows { row.removeFromSuperview() }
        rows.removeAll()
        for (offset, label) in labels.enumerated() {
            let button = NSButton()
            button.cell = RowCell(textCell: "")
            button.image = BoomeChrome.icon(pointSize: 18)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleNone
            button.imageHugsTitle = true
            button.alignment = .left
            button.isBordered = false
            button.lineBreakMode = .byTruncatingTail
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.masksToBounds = true
            button.target = self
            button.action = #selector(rowPressed(_:))
            button.tag = offset
            button.refusesFirstResponder = true
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setAccessibilityLabel(label)
            style(button, label: label, selected: offset == index)
            stack.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            rows.append(button)
        }
    }

    func use(background: NSColor) {
        surfaceBackground = background
        refreshAppearance()
    }

    func refreshAppearance() {
        layer?.backgroundColor = surfaceBackground.cgColor
        headerTitle.textColor = BoomeChrome.text(selected: false, on: surfaceBackground)
        addButton.layer?.backgroundColor = BoomeChrome.quietFill(on: surfaceBackground).cgColor
        addButton.attributedTitle = styled("New Tab", selected: false, centered: true)
        for (offset, row) in rows.enumerated() where labels.indices.contains(offset) {
            style(row, label: labels[offset], selected: offset == selected)
        }
    }

    private func style(_ button: NSButton, label: String, selected: Bool) {
        button.attributedTitle = styled(label, selected: selected, centered: false)
        button.layer?.backgroundColor = (selected ? BoomeChrome.accent : NSColor.clear).cgColor
        button.setAccessibilitySelected(selected)
    }

    private func styled(_ text: String, selected: Bool, centered: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .left
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
            .foregroundColor: BoomeChrome.text(selected: selected, on: surfaceBackground),
            .paragraphStyle: style,
        ])
    }

    private func plusImage() -> NSImage? {
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        let palette = NSImage.SymbolConfiguration(paletteColors: [BoomeChrome.accent])
        let size = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        return symbol?.withSymbolConfiguration(size.applying(palette))
    }

    @objc private func rowPressed(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    @objc private func addPressed() {
        onNew?()
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, GhosttyHostDelegate {
    private let host = GhosttyHost.shared
    private let sidebar = TabSidebar()
    private let terminalHost = NSView()
    private let separator = NSView()
    private var tabs: [TerminalTab] = []
    private var selected = 0
    private var nextOrdinal = 1
    private var appearanceObserver: NSKeyValueObservation?

    init() {
        let window = NSWindow(
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
        super.init(window: window)
        window.delegate = self
        host.delegate = self
        buildChrome()
        applyTerminalChrome()
        openTab(replacingLast: false)
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
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        focusSelected()
    }

    func newTab() {
        openTab(replacingLast: false)
    }

    func closeCurrentTab() {
        guard tabs.indices.contains(selected) else { return }
        host.requestClose(tabs[selected].view.surface)
    }

    func cycle(_ cycle: GhosttyHost.Cycle) {
        guard !tabs.isEmpty else { return }
        let next: Int
        switch cycle {
        case .previous:
            next = (selected - 1 + tabs.count) % tabs.count
        case .next:
            next = (selected + 1) % tabs.count
        case .last:
            next = tabs.count - 1
        case .index(let number):
            let index = number - 1
            guard tabs.indices.contains(index) else { return }
            next = index
        }
        select(next)
    }

    private func buildChrome() {
        guard let content = window?.contentView else { return }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        content.addSubview(terminalHost)

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: content.topAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            terminalHost.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        sidebar.onSelect = { [weak self] index in self?.select(index) }
        sidebar.onNew = { [weak self] in self?.newTab() }
    }

    /// Sidebar and title bar use the terminal background, so the window is one surface.
    private func applyTerminalChrome() {
        let background = host.terminalBackground()
        window?.backgroundColor = background
        window?.appearance = NSAppearance(named: BoomeChrome.isDark(background) ? .darkAqua : .aqua)
        separator.layer?.backgroundColor = BoomeChrome.hairline(on: background).cgColor
        sidebar.use(background: background)
    }

    private func openTab(replacingLast: Bool) {
        let previous = tabs.indices.contains(selected) ? tabs[selected] : nil
        let directory = previous.flatMap { host.inheritedWorkingDirectory(from: $0.view.surface) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let view = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let surface = host.makeSurface(
            view: view,
            workingDirectory: directory,
            contextTab: !tabs.isEmpty && !replacingLast
        ) else { return }
        view.attach(surface)
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
        let tab = TerminalTab(ordinal: nextOrdinal, view: view)
        nextOrdinal += 1
        tab.workingDirectory = directory
        tabs.append(tab)
        select(tabs.count - 1)
    }

    private func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        selected = index
        for (offset, tab) in tabs.enumerated() {
            tab.view.showSurface(offset == index)
        }
        reloadSidebar()
        focusSelected()
    }

    private func focusSelected() {
        guard tabs.indices.contains(selected) else { return }
        window?.makeFirstResponder(tabs[selected].view)
        window?.title = tabs[selected].label
    }

    private func reloadSidebar() {
        sidebar.reload(labels: tabs.map(\.label), selected: selected)
        if tabs.indices.contains(selected) {
            window?.title = tabs[selected].label
        }
    }

    private func remove(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasLast = tabs.count == 1
        if wasLast {
            openTab(replacingLast: true)
        }
        tab.view.removeFromSuperview()
        host.destroy(tab.view.surface)
        tabs.removeAll { $0 === tab }
        if wasLast {
            if let replacement = tabs.indices.last {
                select(replacement)
            }
            return
        }
        let next = min(index, tabs.count - 1)
        select(next)
    }

    func ghosttyHostOpenNewTab(_ host: GhosttyHost) { newTab() }

    func ghosttyHostCloseCurrentTab(_ host: GhosttyHost) { closeCurrentTab() }

    func ghosttyHost(_ host: GhosttyHost, cycle: GhosttyHost.Cycle) { self.cycle(cycle) }

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
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, closeProcessAlive alive: Bool) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        if alive {
            let alert = NSAlert()
            alert.messageText = "Close this terminal?"
            alert.informativeText = "A program is still running in \(tab.label)."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window!) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.remove(tab)
                }
            }
            return
        }
        remove(tab)
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursor: GhosttyHost.CursorStyle) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        tab.view.noteCursor(cursor)
    }

    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursorHidden hidden: Bool) {
        guard let tab = tabs.first(where: { $0.view.surface === surface }) else { return }
        tab.view.noteCursorHidden(hidden)
    }

    func windowWillClose(_ notification: Notification) {
        host.shutdown()
    }
}
