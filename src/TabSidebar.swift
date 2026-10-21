import AppKit

/// Keeps a short tab list at the top. The default clip view pins a
/// short document to the bottom of the sidebar.
private final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

func paintFill(_ layer: CALayer?, color: NSColor, animated: Bool, duration requested: CFTimeInterval = 0.14) {
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
private final class TabRowView: NSView, NSDraggingSource {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onBeginDrag: (() -> String?)?
    var onDragEnded: ((String, NSPoint, NSDragOperation) -> Void)?
    var indentation: CGFloat = 0
    var canClose = true
    private var downEvent: NSEvent?
    private var pressedClose = false
    private var pressedMenu = false
    private var dragging = false
    private var dragToken: String?

    private var model = TabPresentation(primary: "", secondary: nil, accessibility: "")
    private var branch: String?
    private var changes: GitChangeCount?
    private var showsTerminalIcon = false
    private var surfaceBackground = BoomeChrome.fallbackBackground
    private var selected = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var heightConstraint: NSLayoutConstraint?
    private var pulseToken = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
                self?.onClose?()
                return true
            },
            NSAccessibilityCustomAction(name: "Show Menu") { [weak self] in
                self?.showMenu(at: self?.layout.menu)
                return true
            },
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(
        _ model: TabPresentation,
        git: GitWorktreeStatus? = nil,
        showsTerminalIcon: Bool = false,
        selected: Bool,
        background: NSColor,
        animated: Bool
    ) {
        let selectionChanged = self.selected != selected
        self.model = model
        self.branch = git?.branch
        self.changes = git?.count
        self.showsTerminalIcon = showsTerminalIcon
        self.selected = selected
        surfaceBackground = background
        let label = Self.accessibilityLabel(model.accessibility, branch: branch, changes: changes)
        toolTip = label
        setAccessibilityLabel(label)
        setAccessibilitySelected(selected)
        heightConstraint?.constant = rowHeight
        applyChrome(animated: animated && selectionChanged)
    }

    func pinHeight() {
        let constraint = heightAnchor.constraint(equalToConstant: rowHeight)
        constraint.isActive = true
        heightConstraint = constraint
    }

    private var hasBranchLine: Bool {
        branch?.isEmpty == false || changes?.showsBadge == true
    }

    private var rowHeight: CGFloat {
        TabPresentation.rowHeight(hasPath: model.secondary != nil, hasBranch: hasBranchLine)
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

    func synchronizeHover() {
        let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        hovered = window?.isKeyWindow == true && point.map { visibleRect.contains($0) } == true
        applyChrome(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        let point = convert(event.locationInWindow, from: nil)
        pressedClose = showsTitleActions && closeHitRect.contains(point)
        pressedMenu = showsTitleActions && menuHitRect.contains(point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, !pressedClose, !pressedMenu, let start = downEvent else { return }
        let delta = NSPoint(x: event.locationInWindow.x - start.locationInWindow.x, y: event.locationInWindow.y - start.locationInWindow.y)
        guard hypot(delta.x, delta.y) >= 5, let token = onBeginDrag?() else { return }
        dragToken = token
        dragging = true
        let writer = NSPasteboardItem()
        writer.setString(token, forType: .boomeSession)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        defer { dragToken = nil; downEvent = nil; dragging = false; pressedClose = false; pressedMenu = false }
        if let dragToken { onDragEnded?(dragToken, point, operation) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil; pressedClose = false; pressedMenu = false }
        let point = convert(event.locationInWindow, from: nil)
        guard !dragging, bounds.contains(point) else { return }
        if pressedMenu {
            if showsTitleActions, menuHitRect.contains(point) { onMenu?(event) }
            return
        }
        if pressedClose {
            if showsTitleActions, closeHitRect.contains(point) { onClose?() }
            return
        }
        onSelect?()
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return onSelect != nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = self.layout
        let titleColor = BoomeChrome.text(selected: selected, on: surfaceBackground)
        let secondaryColor = BoomeChrome.secondaryText(selected: selected, on: surfaceBackground)
        if let icon = layout.terminalIcon {
            Self.symbol("terminal", point: 11, color: titleColor)?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineBreakMode = .byTruncatingTail
        (model.primary as NSString).draw(
            with: layout.title,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
                .foregroundColor: titleColor,
                .paragraphStyle: titleStyle,
            ]
        )
        if let secondary = model.secondary, let rect = layout.path {
            let pathStyle = NSMutableParagraphStyle()
            pathStyle.lineBreakMode = .byTruncatingHead
            (secondary as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: secondaryColor,
                    .paragraphStyle: pathStyle,
                ]
            )
        }
        if let icon = layout.branchIcon {
            Self.symbol("arrow.triangle.branch", point: 10, color: secondaryColor)?.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let branch, let rect = layout.branch, !branch.isEmpty {
            let branchStyle = NSMutableParagraphStyle()
            branchStyle.lineBreakMode = .byTruncatingTail
            (branch as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: secondaryColor,
                    .paragraphStyle: branchStyle,
                ]
            )
        }
        if let changes, let badge = layout.badge {
            GitChangeBadge.draw(changes, in: badge, on: surfaceBackground)
        }
        guard showsTitleActions else { return }
        let mark = BoomeChrome.text(selected: selected, on: surfaceBackground)
        if let rect = layout.menu {
            // This system has no ellipsis.vertical symbol, so the image was nil and the button stayed blank.
            Self.drawVerticalEllipsis(in: rect, color: mark)
        }
        if let rect = layout.close {
            Self.symbol("xmark", point: 10, color: mark)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private var layout: TabRowLayout {
        TabRowLayout.make(
            hasPath: model.secondary != nil,
            hasBranch: hasBranchLine,
            showsBranchName: branch?.isEmpty == false,
            changes: changes,
            showsTerminalIcon: showsTerminalIcon,
            showsTitleActions: showsTitleActions,
            in: bounds,
            left: 12 + indentation
        )
    }

    private var showsTitleActions: Bool { canClose && TabChrome.showsTitleActions(hovered: hovered) }

    private func showMenu(at rect: NSRect?) {
        guard let window else { return }
        let anchor = rect ?? layoutShowingActions.menu
        guard let anchor else { return }
        let location = convert(NSPoint(x: anchor.midX, y: anchor.maxY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        onMenu?(event)
    }

    /// The menu action is available without the pointer resting on the row.
    private var layoutShowingActions: TabRowLayout {
        TabRowLayout.make(
            hasPath: model.secondary != nil,
            hasBranch: hasBranchLine,
            showsBranchName: branch?.isEmpty == false,
            changes: changes,
            showsTerminalIcon: showsTerminalIcon,
            showsTitleActions: true,
            in: bounds,
            left: 12 + indentation
        )
    }

    private static func accessibilityLabel(_ title: String, branch: String?, changes: GitChangeCount?) -> String {
        var label = title
        if let branch, !branch.isEmpty, !label.contains(branch) {
            label += " · " + branch
        }
        if let changes, changes.showsBadge {
            label += " · " + changes.accessibilityMark
        }
        return label
    }

    private static func drawVerticalEllipsis(in rect: NSRect, color: NSColor) {
        let radius: CGFloat = 1.5
        let spacing: CGFloat = 4
        color.setFill()
        for index in -1...1 {
            let center = NSPoint(x: rect.midX, y: rect.midY + CGFloat(index) * spacing)
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    private static func symbol(_ name: String, point: CGFloat, color: NSColor) -> NSImage? {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let size = NSImage.SymbolConfiguration(pointSize: point, weight: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return symbol?.withSymbolConfiguration(size.applying(palette))
    }

    private var menuHitRect: NSRect { layout.menu ?? .zero }
    private var closeHitRect: NSRect { layout.close ?? .zero }

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


final class TabSidebar: NSView {
    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onNew: (() -> Void)?
    var onMenu: ((TabID, NSEvent) -> Void)?
    var onToggleGroup: ((UUID) -> Void)?
    var onGroupMenu: ((UUID, NSEvent) -> Void)?
    var onBeginDrag: ((SessionDragItem) -> String?)?
    var onDragItem: ((String) -> SessionDragItem?)?
    var onCanDrop: ((String, SessionDropTarget) -> Bool)?
    var onDrop: ((String, SessionDropTarget) -> Bool)?
    var onDragEnded: ((String, NSPoint, NSDragOperation) -> Void)?

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let addButton = QuietAddButton()
    private let indicator = SessionDropIndicator()
    private var rowViews: [SessionDragItem: TabRowView] = [:]
    // AppKit does not retain a source row removed by the drop transaction.
    private var dragSourceRow: TabRowView?
    private var visibleRows: [SessionDragItem] = []
    private var arrangement = SessionArrangement()
    private var selected: TabID?
    private var surfaceBackground = BoomeChrome.fallbackBackground

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityIdentifier("SessionSidebar")
        registerForDraggedTypes([.boomeSession])
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
        indicator.isHidden = true
        addSubview(indicator)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func reload(
        arrangement next: SessionArrangement,
        rows: [TabPresentation],
        git: [TabID: GitWorktreeStatus] = [:],
        selected id: TabID?,
        pulse: Bool = false
    ) {
        let presentations = Dictionary(uniqueKeysWithValues: zip(next.ids, rows))
        var visible: [SessionDragItem] = []
        var seen: Set<UUID> = []
        for item in next.items {
            if let group = item.groupID, let model = next.groups[group] {
                if seen.insert(group).inserted { visible.append(.group(group)) }
                if model.collapsed { continue }
            }
            visible.append(.tab(item.id))
        }
        let changed = visible != visibleRows
        let reveal = changed || selected != id
        let animate = selected != id
        selected = id
        arrangement = next
        if changed {
            for row in stack.arrangedSubviews { stack.removeArrangedSubview(row); row.removeFromSuperview() }
        }
        var updated: [SessionDragItem: TabRowView] = [:]
        for identity in visible {
            let row = rowViews[identity] ?? TabRowView()
            row.translatesAutoresizingMaskIntoConstraints = false
            if changed { stack.addArrangedSubview(row) }
            let model: TabPresentation
            let isSelected: Bool
            switch identity {
            case .tab(let tab):
                model = presentations[tab] ?? TabPresentation(primary: "Terminal", secondary: nil, accessibility: "Terminal")
                isSelected = tab == id
                row.indentation = next.items.first { $0.id == tab }?.groupID == nil ? 0 : 14
                row.canClose = true
                row.setAccessibilityIdentifier("SessionTab-\(tab.raw)")
                row.onSelect = { [weak self] in self?.onSelect?(tab) }
                row.onClose = { [weak self] in self?.onClose?(tab) }
                row.onMenu = { [weak self] event in self?.onMenu?(tab, event) }
            case .group(let group):
                guard let metadata = next.groups[group] else { continue }
                let members = next.ids(for: identity)
                model = TabPresentation(
                    primary: "\(metadata.collapsed ? "▸" : "▾")  \(metadata.name) · \(members.count)",
                    secondary: nil,
                    accessibility: "Group \(metadata.name), \(members.count) tabs, \(metadata.collapsed ? "collapsed" : "expanded")"
                )
                isSelected = metadata.collapsed && id.map { members.contains($0) } == true
                row.indentation = 0
                row.canClose = false
                row.setAccessibilityCustomActions([])
                row.setAccessibilityIdentifier("SessionGroup-\(group.uuidString)")
                row.onSelect = { [weak self] in self?.onToggleGroup?(group) }
                row.onClose = nil
                row.onMenu = { [weak self] event in self?.onGroupMenu?(group, event) }
            }
            row.setAccessibilityHelp("Drag between rows to reorder; onto a row to group; outside the window to detach.")
            row.onBeginDrag = { [weak self, weak row] in
                guard let self, let token = self.onBeginDrag?(identity) else { return nil }
                self.dragSourceRow = row
                return token
            }
            row.onDragEnded = { [weak self] token, point, operation in
                guard let self else { return }
                defer { self.dragSourceRow = nil }
                self.indicator.isHidden = true
                self.synchronizeHover()
                self.onDragEnded?(token, point, operation)
            }
            let status: GitWorktreeStatus?
            let icon: Bool
            if case .tab(let tab) = identity {
                status = git[tab]
                icon = true
            } else {
                status = nil
                icon = false
            }
            row.show(model, git: status, showsTerminalIcon: icon, selected: isSelected, background: surfaceBackground, animated: animate && !pulse)
            if rowViews[identity] == nil { row.pinHeight() }
            if pulse && isSelected { row.pulse() }
            updated[identity] = row
        }
        rowViews = updated
        visibleRows = visible
        if reveal { revealSelected() }
        synchronizeHover()
    }

    private func synchronizeHover() {
        layoutSubtreeIfNeeded()
        for row in rowViews.values { row.synchronizeHover() }
    }

    func revealSelection() { revealSelected() }

    private func revealSelected() {
        guard let selected else { return }
        let identity: SessionDragItem
        if let group = arrangement.items.first(where: { $0.id == selected })?.groupID,
           arrangement.groups[group]?.collapsed == true { identity = .group(group) }
        else { identity = .tab(selected) }
        guard let row = rowViews[identity] else { return }
        layoutSubtreeIfNeeded()
        scroll.contentView.scrollToVisible(row.convert(row.bounds, to: scroll.contentView))
    }

    func use(background: NSColor) {
        surfaceBackground = background
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.backgroundColor = surfaceBackground.cgColor
        indicator.background = surfaceBackground
        addButton.use(background: surfaceBackground)
        for row in rowViews.values { row.use(background: surfaceBackground) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrag(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { indicator.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { indicator.isHidden = true }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let token = sender.draggingPasteboard.string(forType: .boomeSession) else { return false }
        let target = dropTarget(at: convert(sender.draggingLocation, from: nil), drag: onDragItem?(token)).0
        return onCanDrop?(token, target) == true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        guard let token = sender.draggingPasteboard.string(forType: .boomeSession) else { return false }
        let target = dropTarget(at: convert(sender.draggingLocation, from: nil), drag: onDragItem?(token)).0
        return onDrop?(token, target) == true
    }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let token = sender.draggingPasteboard.string(forType: .boomeSession), let drag = onDragItem?(token) else {
            indicator.isHidden = true
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        if scroll.frame.contains(point) {
            var origin = scroll.contentView.bounds.origin
            if point.y < scroll.frame.minY + 24 { origin.y -= 12 }
            else if point.y > scroll.frame.maxY - 24 { origin.y += 12 }
            origin.y = min(max(0, origin.y), max(0, stack.bounds.height - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let (target, rect, line) = dropTarget(at: point, drag: drag)
        guard onCanDrop?(token, target) == true else { indicator.isHidden = true; return [] }
        indicator.frame = rect
        indicator.line = line
        indicator.isHidden = false
        indicator.needsDisplay = true
        return .move
    }

    private func dropTarget(at point: NSPoint, drag: SessionDragItem?) -> (SessionDropTarget, NSRect, Bool) {
        layoutSubtreeIfNeeded()
        for identity in visibleRows {
            guard let row = rowViews[identity] else { continue }
            let rect = row.convert(row.bounds, to: self)
            guard point.y <= rect.maxY else { continue }
            let fraction = (point.y - rect.minY) / max(1, rect.height)
            let before = fraction < 0.25
            let after = fraction > 0.75
            if !before && !after {
                switch identity {
                case .tab(let id): return (.intoTab(id), rect, false)
                case .group(let id): return (.intoGroup(id), rect, false)
                }
            }
            var target: SessionDropTarget
            var edge = after ? rect.maxY + 2 : rect.minY - 2
            switch identity {
            case .tab(let id):
                if case .group = drag, let group = arrangement.items.first(where: { $0.id == id })?.groupID {
                    target = after ? .afterGroup(group) : .beforeGroup(group)
                    let groupRows = visibleRows.filter {
                        if case .tab(let tab) = $0 { return arrangement.items.first { $0.id == tab }?.groupID == group }
                        return $0 == .group(group)
                    }.compactMap { rowViews[$0] }
                    let frames = groupRows.map { $0.convert($0.bounds, to: self) }
                    edge = after ? (frames.map(\.maxY).max() ?? rect.maxY) + 2 : (frames.map(\.minY).min() ?? rect.minY) - 2
                } else { target = after ? .after(id) : .before(id) }
            case .group(let id):
                target = after ? .afterGroup(id) : .beforeGroup(id)
                if after, let last = arrangement.ids(for: .group(id)).last, let lastRow = rowViews[.tab(last)] {
                    edge = lastRow.convert(lastRow.bounds, to: self).maxY + 2
                }
            }
            return (target, NSRect(x: 8, y: min(max(edge, scroll.frame.minY), scroll.frame.maxY - 4), width: bounds.width - 16, height: 4), true)
        }
        let bottom = visibleRows.last.flatMap { rowViews[$0] }.map { $0.convert($0.bounds, to: self).maxY + 2 } ?? scroll.frame.minY + 4
        return (.end, NSRect(x: 8, y: min(bottom, scroll.frame.maxY - 4), width: bounds.width - 16, height: 4), true)
    }
}
