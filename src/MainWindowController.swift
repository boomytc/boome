import AppKit

final class TerminalTab {
    let id: TabID
    var ordinal: Int { id.raw }
    let view: TerminalSurfaceView
    var terminalTitle = ""
    var tabTitle: String?
    var workingDirectory: String?

    init(id: TabID, view: TerminalSurfaceView) {
        self.id = id
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

private func paintFill(_ layer: CALayer?, color: NSColor, animated: Bool, duration requested: CFTimeInterval = 0.14) {
    guard let layer else { return }
    let next = color.cgColor
    let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : requested
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
/// ate the title, so the row is type only. Selection is a lighter pass of
/// the terminal background, not a second color.
private final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private var model = TabPresentation(primary: "", secondary: nil, accessibility: "")
    private var surfaceBackground = BoomeChrome.fallbackBackground
    private var selected = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var heightConstraint: NSLayoutConstraint?
    private var pulseToken = 0

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
        heightConstraint?.constant = TabPresentation.rowHeight(hasSecondary: model.secondary != nil)
        applyChrome(animated: animated && selectionChanged)
    }

    func pinHeight() {
        let constraint = heightAnchor.constraint(equalToConstant: TabPresentation.rowHeight(hasSecondary: model.secondary != nil))
        constraint.isActive = true
        heightConstraint = constraint
    }

    /// Keyboard landing. A brief lift, then back to the selection fill.
    func pulse() {
        guard SelectionPulse.plays(
            marked: selected,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) else { return }
        pulseToken += 1
        let token = pulseToken
        let flash = BoomeChrome.isDark(surfaceBackground)
            ? NSColor(white: 1, alpha: 0.22)
            : NSColor(white: 0, alpha: 0.12)
        paintFill(layer, color: flash, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, self.pulseToken == token, self.selected else { return }
            paintFill(self.layer, color: BoomeChrome.selectionFill(on: self.surfaceBackground), animated: true, duration: 0.28)
        }
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
        onMenu?(event)
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

    private var showsClose: Bool { TabChrome.showsClose(selected: selected, hovered: hovered) }

    /// Wider than the glyph so the close affordance is the trailing edge, not a 10-point mark.
    private var closeHitRect: NSRect {
        NSRect(x: bounds.width - 36, y: 0, width: 36, height: bounds.height)
    }

    private func applyChrome(animated: Bool) {
        let role: BoomeChrome.RowRole
        if selected {
            role = .selected
        } else if hovered {
            role = .hover
        } else {
            role = .rest
        }
        paintFill(layer, color: BoomeChrome.rowFill(role, on: surfaceBackground), animated: animated)
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
        let iconX: CGFloat = 12
        let iconY = ((bounds.height - iconSide) / 2).rounded()
        if let symbol = Self.plusImage(color) {
            symbol.draw(
                in: NSRect(x: iconX, y: iconY, width: iconSide, height: iconSide),
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
        paintFill(layer, color: BoomeChrome.newTabFill(hovered: hovered, on: surfaceBackground), animated: animated)
    }

    private static func plusImage(_ color: NSColor) -> NSImage? {
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        let size = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return symbol?.withSymbolConfiguration(size.applying(palette))
    }
}

/// Title-bar control for the sidebar. The glyph stays `sidebar.left`.
/// The label follows the window's existing collapsed bit.
private final class SidebarToggleButton: NSView {
    var onPress: (() -> Void)?

    private var surfaceBackground = BoomeChrome.fallbackBackground
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("SidebarToggle")
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
        let title = collapsed ? "展开侧栏" : "收起侧栏"
        toolTip = "\(title) (⌥⌘S)"
        setAccessibilityLabel(title)
        setAccessibilityHelp(toolTip)
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

    override func draw(_ dirtyRect: NSRect) {
        let color = BoomeChrome.text(selected: hovered, on: surfaceBackground)
        let side: CGFloat = 15
        let icon = NSRect(
            x: ((bounds.width - side) / 2).rounded(),
            y: ((bounds.height - side) / 2).rounded(),
            width: side,
            height: side
        )
        Self.symbol(color)?.draw(
            in: icon,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func paint(animated: Bool) {
        paintFill(layer, color: BoomeChrome.newTabFill(hovered: hovered, on: surfaceBackground), animated: animated)
    }

    private static func symbol(_ color: NSColor) -> NSImage? {
        let symbol = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        let size = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return symbol?.withSymbolConfiguration(size.applying(palette))
    }
}

final class TabSidebar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onMenu: ((Int, NSEvent) -> Void)?

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
        stack.setHuggingPriority(.required, for: .horizontal)
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
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            addButton.heightAnchor.constraint(equalToConstant: 36),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
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

    func reload(rows: [TabPresentation], selected index: Int, pulse: Bool = false) {
        let reveal = rowViews.count != rows.count || index != selected
        let animateSelection = !rowViews.isEmpty && index != selected
        selected = index
        if rowViews.count != rows.count {
            for row in rowViews { row.removeFromSuperview() }
            rowViews.removeAll()
            for (offset, model) in rows.enumerated() {
                let row = TabRowView()
                row.onSelect = { [weak self] in self?.onSelect?(offset) }
                row.onClose = { [weak self] in self?.onClose?(offset) }
                row.onMenu = { [weak self] event in self?.onMenu?(offset, event) }
                row.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(row)
                row.show(model, selected: offset == index, background: surfaceBackground, animated: false)
                row.pinHeight()
                rowViews.append(row)
            }
            if pulse, rowViews.indices.contains(index) {
                rowViews[index].pulse()
            }
            if reveal { revealSelected() }
            return
        }
        for (offset, model) in rows.enumerated() {
            rowViews[offset].show(model, selected: offset == index, background: surfaceBackground, animated: animateSelection && !pulse)
        }
        if pulse, rowViews.indices.contains(index) {
            rowViews[index].pulse()
        }
        if reveal { revealSelected() }
    }

    /// Switch, insert, remove, and layout changes. A title refresh uses
    /// `reload` with the same selection and does not come through here.
    func revealSelection() {
        revealSelected()
    }

    /// The selected row stays in the clip.
    private func revealSelected() {
        guard rowViews.indices.contains(selected) else { return }
        layoutSubtreeIfNeeded()
        let row = rowViews[selected]
        let rect = row.convert(row.bounds, to: scroll.contentView)
        scroll.contentView.scrollToVisible(rect)
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
    private let terminalHost = NSView()
    private let separator = NSView()
    private var sidebarWidth: NSLayoutConstraint!
    private var separatorWidth: NSLayoutConstraint!
    private var tabs: [TerminalTab] = []
    private var selected = 0
    private var nextOrdinal = 1
    private var sidebarCollapsed = false
    private var appearanceObserver: NSKeyValueObservation?
    private var closePolicy = ClosePolicy()
    private var windowProbe: WindowProbe?
    private var windowFollowUp: WindowFollowUp?
    private var allowWindowClose = false
    private var confirmAlert: NSAlert?

    var isSidebarCollapsed: Bool { sidebarCollapsed }

    /// Quit may proceed. A live process still has to be confirmed first.
    func approveTermination() -> Bool { allowWindowClose }

    func requestQuit() {
        requestWindowClose(followUp: .quit)
    }

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
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        host.delegate = self
        buildChrome()
        restoreChrome()
        newTab()
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
        if ChromeMemory.hasSavedFrame(saved) {
            window.setFrameUsingName(ChromeMemory.frameAutosaveName)
        } else {
            window.center()
        }
        window.setFrameAutosaveName(ChromeMemory.frameAutosaveName)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        placeSidebarToggle()
        focusSelected()
    }

    func toggleSidebar() {
        sidebarCollapsed.toggle()
        applySidebarWidth(animated: true)
        rememberChrome()
        focusSelected()
    }

    /// The system tab command stays in this window.
    @objc override func newWindowForTab(_ sender: Any?) {
        newTab()
    }

    func newTab() {
        guard let tab = createTab(replacingLast: false) else { return }
        install(tab)
        var list = TabList(ids: tabs.map(\.id), selected: tabs.isEmpty ? 0 : selected)
        list.append(tab.id)
        tabs.append(tab)
        selected = list.selected
        updateSurfaceVisibility()
        reloadSidebar()
        focusSelected()
    }

    func closeCurrentTab() {
        closeTab(at: selected)
    }

    func cycle(_ cycle: GhosttyHost.Cycle) {
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
            allowWindowClose = true
            if followUp == .closeWindow {
                window?.close()
            }
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
        content.addSubview(sidebar)
        content.addSubview(terminalHost)

        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)

        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 200)
        separatorWidth = separator.widthAnchor.constraint(equalToConstant: 1)
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
            terminalHost.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: safe.topAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        sidebar.onSelect = { [weak self] index in self?.select(index) }
        sidebar.onClose = { [weak self] index in self?.closeTab(at: index) }
        sidebar.onNew = { [weak self] in self?.newTab() }
        sidebar.onMenu = { [weak self] index, event in self?.showTabMenu(at: index, event: event) }
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
        titlebar.addSubview(sidebarToggle)
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
        applySidebarWidth(animated: false)
        applyTerminalChrome()
    }

    private func rememberChrome() {
        UserDefaults.standard.set(sidebarCollapsed, forKey: ChromeMemory.collapsedKey)
    }

    private func syncSidebarToggle() {
        sidebarToggle.note(collapsed: isSidebarCollapsed)
    }

    /// Sidebar and title bar use the terminal background, so the window is one surface.
    private func applyTerminalChrome() {
        let background = host.terminalBackground()
        let appearance = NSAppearance(named: BoomeChrome.isDark(background) ? .darkAqua : .aqua)
        window?.backgroundColor = background
        window?.appearance = appearance
        separator.layer?.backgroundColor = BoomeChrome.hairline(on: background).cgColor
        sidebar.use(background: background)
        sidebarToggle.use(background: background)
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
        let tab = TerminalTab(id: TabID(raw: nextOrdinal), view: view)
        nextOrdinal += 1
        tab.workingDirectory = directory
        return tab
    }

    private func install(_ tab: TerminalTab) {
        let view = tab.view
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
        guard tabs.indices.contains(index) else { return }
        selected = index
        updateSurfaceVisibility()
        reloadSidebar(pulse: pulse)
        focusSelected()
    }

    private func focusSelected() {
        guard tabs.indices.contains(selected), let window else { return }
        window.makeFirstResponder(tabs[selected].view)
        syncWindowTitles()
    }

    private func reloadSidebar(pulse: Bool = false) {
        let rows = TabPresentation.disambiguate(
            tabs.map { TabPresentation.make(label: $0.label, customTitle: $0.tabTitle != nil) }
        )
        sidebar.reload(rows: rows, selected: selected, pulse: pulse)
        syncWindowTitles()
    }

    private func remove(_ tab: TerminalTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        let created = tabs.count == 1 ? createTab(replacingLast: true) : nil
        if tabs.count == 1, created == nil { return }
        var list = TabList(ids: tabs.map(\.id), selected: selected)
        guard list.close(tab.id, replacement: created?.id ?? tab.id) != nil else { return }
        if let created { install(created) }
        tab.view.removeFromSuperview()
        host.destroy(tab.view.surface)
        var pool = tabs
        if let created { pool.append(created) }
        let byID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })
        tabs = list.ids.compactMap { byID[$0] }
        selected = list.selected
        updateSurfaceVisibility()
        reloadSidebar()
        focusSelected()
    }

    func ghosttyHostOpenNewTab(_ host: GhosttyHost) { newTab() }

    func ghosttyHostCloseCurrentTab(_ host: GhosttyHost) { closeCurrentTab() }

    func ghosttyHostCloseWindow(_ host: GhosttyHost) {
        requestWindowClose(followUp: .closeWindow)
    }

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
        if allowWindowClose || tabs.isEmpty { return true }
        requestWindowClose(followUp: .closeWindow)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusSelected()
    }

    func windowDidResize(_ notification: Notification) {
        placeSidebarToggle()
        sidebar.revealSelection()
    }

    func windowWillClose(_ notification: Notification) {
        host.shutdown()
    }

    private func showTabMenu(at index: Int, event: NSEvent) {
        guard tabs.indices.contains(index) else { return }
        let menu = NSMenu()
        let newItem = NSMenuItem(title: "New Tab", action: #selector(newTabFromMenu(_:)), keyEquivalent: "t")
        newItem.keyEquivalentModifierMask = .command
        newItem.target = self
        menu.addItem(newItem)
        menu.addItem(.separator())
        let closeItem = NSMenuItem(title: "Close Tab", action: #selector(closeFromMenu(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        closeItem.target = self
        closeItem.representedObject = index
        menu.addItem(closeItem)
        let others = NSMenuItem(title: "Close Other Tabs", action: #selector(closeOthersFromMenu(_:)), keyEquivalent: "")
        others.target = self
        others.representedObject = index
        others.isEnabled = tabs.count > 1
        menu.addItem(others)
        let right = NSMenuItem(title: "Close Tabs to the Right", action: #selector(closeRightFromMenu(_:)), keyEquivalent: "")
        right.target = self
        right.representedObject = index
        right.isEnabled = index < tabs.count - 1
        menu.addItem(right)
        NSMenu.popUpContextMenu(menu, with: event, for: sidebar)
    }

    @objc private func newTabFromMenu(_ sender: Any?) {
        newTab()
    }

    @objc private func closeFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        closeTab(at: index)
    }

    @objc private func closeOthersFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let ids = TabList(ids: tabs.map(\.id), selected: selected).requestingCloseOthers(keeping: index)
        requestClose(ids: ids)
    }

    @objc private func closeRightFromMenu(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let ids = TabList(ids: tabs.map(\.id), selected: selected).requestingCloseRight(of: index)
        requestClose(ids: ids)
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        requestClose(ids: [tabs[index].id])
    }

    private func requestClose(ids: [TabID]) {
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
            alert.informativeText = "A program is still running in \(label)."
        case .tabs(let ids):
            alert.messageText = "Close these terminals?"
            alert.informativeText = "A program is still running. This closes all \(ids.count) tabs."
        case .window:
            alert.messageText = "Close this window?"
            alert.informativeText = "A program is still running."
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
            }
        }
    }

    private func performWindowClose(_ followUp: WindowFollowUp) {
        windowFollowUp = nil
        allowWindowClose = true
        switch followUp {
        case .closeWindow:
            window?.close()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func applySidebarWidth(animated: Bool) {
        syncSidebarToggle()
        placeSidebarToggle()
        let width: CGFloat = sidebarCollapsed ? 0 : 200
        let hairline: CGFloat = sidebarCollapsed ? 0 : 1
        let changes = {
            self.sidebarWidth.constant = width
            self.separatorWidth.constant = hairline
        }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                changes()
                self.sidebarWidth.animator().constant = width
                self.separatorWidth.animator().constant = hairline
            }
        } else {
            changes()
        }
    }

    private func updateSurfaceVisibility() {
        for (offset, tab) in tabs.enumerated() {
            tab.view.showSurface(offset == selected)
        }
    }

    private func syncWindowTitles() {
        if tabs.indices.contains(selected) {
            window?.title = tabs[selected].label
        }
    }
}
