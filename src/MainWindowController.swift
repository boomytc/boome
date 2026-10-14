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

/// Keeps a short tab list at the top. The default clip view pins a
/// short document to the bottom of the sidebar.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Sidebar drawing of one tab. The window title stays the full string.
/// A `user@host:path` title is split so the path is the line you scan;
/// tail truncation in a 200-point column was hiding it.
struct TabPresentation: Equatable {
    var primary: String
    var secondary: String?
    var accessibility: String

    static func make(label: String, customTitle: Bool) -> TabPresentation {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customTitle, let split = splitShellTitle(trimmed) ?? splitPath(trimmed) {
            return split
        }
        return TabPresentation(primary: label, secondary: nil, accessibility: label)
    }

    /// A title that is only a path still hides its last component when the
    /// line is tail-truncated. The parent path stays on the second line.
    private static func splitPath(_ title: String) -> TabPresentation? {
        guard title.hasPrefix("/") || title.hasPrefix("~") else { return nil }
        let name = directoryName(title)
        guard !name.isEmpty, name != title else { return nil }
        let parent = (title as NSString).deletingLastPathComponent
        let secondary = (parent.isEmpty || parent == "/" || parent == "~") ? nil : parent
        return TabPresentation(primary: name, secondary: secondary, accessibility: title)
    }

    private static func splitShellTitle(_ title: String) -> TabPresentation? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return nil }
        let afterAt = trimmed.index(after: at)
        guard afterAt < trimmed.endIndex,
              let colon = trimmed[afterAt...].firstIndex(of: ":") else { return nil }
        let userHost = String(trimmed[..<colon])
        let path = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let name = directoryName(path)
        guard !userHost.isEmpty, !name.isEmpty else { return nil }
        return TabPresentation(primary: name, secondary: userHost, accessibility: trimmed)
    }

    private static func directoryName(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path == "~" || path == "~/" { return "~" }
        if path == "/" { return "/" }
        let name = (path as NSString).lastPathComponent
        if name.isEmpty || name == "/" { return "~" }
        return name
    }
}

private func paintFill(_ layer: CALayer?, color: NSColor, animated: Bool) {
    guard let layer else { return }
    let next = color.cgColor
    let duration: CFTimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
    if animated, duration > 0 {
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        animation.toValue = next
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "fill")
    }
    layer.backgroundColor = next
}

/// One sidebar row. The same ghost on every row carried no information and
/// ate the title, so the row is type only. Orange is the selected fill.
private final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private var model = TabPresentation(primary: "", secondary: nil, accessibility: "")
    private var surfaceBackground = BoomeChrome.fallbackBackground
    private var selected = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityRole(.button)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
                self?.onClose?()
                return true
            },
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ model: TabPresentation, selected: Bool, background: NSColor, animated: Bool) {
        let selectionChanged = self.selected != selected
        self.model = model
        self.selected = selected
        surfaceBackground = background
        toolTip = model.accessibility
        setAccessibilityLabel(model.accessibility)
        setAccessibilitySelected(selected)
        applyChrome(animated: animated && selectionChanged)
    }

    func use(background: NSColor) {
        surfaceBackground = background
        applyChrome(animated: false)
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
        hovered = true
        applyChrome(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyChrome(animated: true)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if showsClose, closeHitRect.contains(point) {
            onClose?()
            return
        }
        onSelect?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Close Tab", action: #selector(closePressed(_:)), keyEquivalent: "w")
        item.keyEquivalentModifierMask = .command
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let showClose = selected || hovered
        let left: CGFloat = 12
        let right: CGFloat = showClose ? 30 : 12
        let width = max(0, bounds.width - left - right)
        let primaryFont = NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium)
        let primaryStyle = NSMutableParagraphStyle()
        primaryStyle.lineBreakMode = .byTruncatingTail
        let primaryAttrs: [NSAttributedString.Key: Any] = [
            .font: primaryFont,
            .foregroundColor: BoomeChrome.text(selected: selected, on: surfaceBackground),
            .paragraphStyle: primaryStyle,
        ]
        let hasSecondary = model.secondary != nil
        let primaryHeight: CGFloat = 18
        let secondaryHeight: CGFloat = hasSecondary ? 14 : 0
        let gap: CGFloat = hasSecondary ? 2 : 0
        let block = primaryHeight + gap + secondaryHeight
        let top = ((bounds.height - block) / 2).rounded()
        (model.primary as NSString).draw(
            with: NSRect(x: left, y: top, width: width, height: primaryHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: primaryAttrs
        )
        if let secondary = model.secondary {
            let secondaryStyle = NSMutableParagraphStyle()
            secondaryStyle.lineBreakMode = .byTruncatingMiddle
            let secondaryAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: BoomeChrome.secondaryText(selected: selected, on: surfaceBackground),
                .paragraphStyle: secondaryStyle,
            ]
            (secondary as NSString).draw(
                with: NSRect(x: left, y: top + primaryHeight + gap, width: width, height: secondaryHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: secondaryAttrs
            )
        }
        guard showsClose, let symbol = TabRowView.closeImage(BoomeChrome.text(selected: selected, on: surfaceBackground)) else {
            return
        }
        let side: CGFloat = 11
        symbol.draw(
            in: NSRect(
                x: bounds.width - 14 - side,
                y: ((bounds.height - side) / 2).rounded(),
                width: side,
                height: side
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private var showsClose: Bool { selected || hovered }

    /// Wider than the glyph so the close affordance is the trailing edge, not a 10-point mark.
    private var closeHitRect: NSRect {
        NSRect(x: bounds.width - 36, y: 0, width: 36, height: bounds.height)
    }

    private func applyChrome(animated: Bool) {
        let fill: NSColor
        if selected {
            fill = BoomeChrome.accent
        } else if hovered {
            fill = BoomeChrome.quietFill(on: surfaceBackground)
        } else {
            fill = .clear
        }
        paintFill(layer, color: fill, animated: animated)
        needsDisplay = true
    }

    private static func closeImage(_ color: NSColor) -> NSImage? {
        let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        let size = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return symbol?.withSymbolConfiguration(size.applying(palette))
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose?()
    }
}

/// Weak action: no resting fill, so the selected tab is the only solid shape.
private final class QuietAddButton: NSView {
    var onPress: (() -> Void)?

    private var surfaceBackground = BoomeChrome.fallbackBackground
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = "New Tab (⌘T)"
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func use(background: NSColor) {
        surfaceBackground = background
        paint(animated: false)
        needsDisplay = true
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
        hovered = true
        paint(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        paint(animated: true)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside { onPress?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = BoomeChrome.text(selected: false, on: surfaceBackground)
        let iconSide: CGFloat = 12
        let iconY = ((bounds.height - iconSide) / 2).rounded()
        if let symbol = Self.plusImage(color) {
            symbol.draw(
                in: NSRect(x: 12, y: iconY, width: iconSide, height: iconSide),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let titleHeight: CGFloat = 16
        let titleY = ((bounds.height - titleHeight) / 2).rounded()
        ("New Tab" as NSString).draw(
            with: NSRect(x: 12 + iconSide + 6, y: titleY, width: max(0, bounds.width - 42), height: titleHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
        )
    }

    private func paint(animated: Bool) {
        let fill = hovered ? BoomeChrome.quietFill(on: surfaceBackground) : .clear
        paintFill(layer, color: fill, animated: animated)
    }

    private static func plusImage(_ color: NSColor) -> NSImage? {
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        let size = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return symbol?.withSymbolConfiguration(size.applying(palette))
    }
}

final class TabSidebar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let addButton = QuietAddButton()
    private var rowViews: [TabRowView] = []
    private var selected = 0
    private var surfaceBackground = BoomeChrome.fallbackBackground

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        stack.setHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        let clip = TopClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.onPress = { [weak self] in self?.onNew?() }
        addSubview(addButton)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            addButton.heightAnchor.constraint(equalToConstant: 36),
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

    func reload(rows: [TabPresentation], selected index: Int) {
        let animateSelection = !rowViews.isEmpty && index != selected
        selected = index
        if rowViews.count != rows.count {
            for row in rowViews { row.removeFromSuperview() }
            rowViews.removeAll()
            for (offset, model) in rows.enumerated() {
                let row = TabRowView()
                row.onSelect = { [weak self] in self?.onSelect?(offset) }
                row.onClose = { [weak self] in self?.onClose?(offset) }
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                row.heightAnchor.constraint(equalToConstant: 46).isActive = true
                row.show(model, selected: offset == index, background: surfaceBackground, animated: false)
                rowViews.append(row)
            }
            return
        }
        for (offset, model) in rows.enumerated() {
            rowViews[offset].show(model, selected: offset == index, background: surfaceBackground, animated: animateSelection)
        }
    }

    func use(background: NSColor) {
        surfaceBackground = background
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.backgroundColor = surfaceBackground.cgColor
        addButton.use(background: surfaceBackground)
        for row in rowViews {
            row.use(background: surfaceBackground)
        }
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
        closeTab(at: selected)
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        host.requestClose(tabs[index].view.surface)
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
        sidebar.onClose = { [weak self] index in self?.closeTab(at: index) }
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
        sidebar.reload(
            rows: tabs.map { TabPresentation.make(label: $0.label, customTitle: $0.tabTitle != nil) },
            selected: selected
        )
        if tabs.indices.contains(selected) {
            window?.title = tabs[selected].label
        }
    }

    private func remove(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasLast = tabs.count == 1
        let closingSelected = index == selected
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
        if closingSelected {
            select(min(index, tabs.count - 1))
            return
        }
        // A background tab closed under the visible one. Keep that shell.
        if index < selected {
            selected -= 1
        }
        reloadSidebar()
        focusSelected()
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
