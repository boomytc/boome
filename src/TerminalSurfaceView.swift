import AppKit

/// One live terminal grid. Input goes to libghostty. The view does not
/// call `ghostty_*`; `GhosttyHost` does.
final class TerminalSurfaceView: NSView, NSTextInputClient {
    private(set) var surface: GhosttyHost.Surface!
    private let host = GhosttyHost.shared
    private var marked = NSMutableAttributedString()
    private var collecting = false
    private var collected: [String] = []
    private var cursorStyle: GhosttyHost.CursorStyle = .text
    private var cursorHidden = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    func attach(_ surface: GhosttyHost.Surface) {
        self.surface = surface
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { !isHidden }
    override var isFlipped: Bool { false }

    func noteCursor(_ style: GhosttyHost.CursorStyle) {
        cursorStyle = style
        window?.invalidateCursorRects(for: self)
    }

    func noteCursorHidden(_ hidden: Bool) {
        cursorHidden = hidden
        if hidden {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func focusSurface(_ focused: Bool) {
        host.setSurfaceFocus(surface, focused: focused)
    }

    func showSurface(_ visible: Bool) {
        isHidden = !visible
        host.setSurfaceVisible(surface, visible: visible)
        if visible {
            host.syncGeometry(surface)
            window?.makeFirstResponder(self)
            focusSurface(true)
        } else {
            focusSurface(false)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        host.syncGeometry(surface)
        if window != nil, !isHidden {
            host.setSurfaceVisible(surface, visible: true)
        }
    }

    override func layout() {
        super.layout()
        host.syncGeometry(surface)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        host.syncGeometry(surface)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorStyle.cursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursorStyle.cursor.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = host.sendMouseButton(surface, pressed: true, button: 0, modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        _ = host.sendMouseButton(surface, pressed: false, button: 0, modifiers: event.modifierFlags)
    }

    override func rightMouseDown(with event: NSEvent) {
        if !host.sendMouseButton(surface, pressed: true, button: 1, modifiers: event.modifierFlags) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !host.sendMouseButton(surface, pressed: false, button: 1, modifiers: event.modifierFlags) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        _ = host.sendMouseButton(surface, pressed: true, button: event.buttonNumber, modifiers: event.modifierFlags)
    }

    override func otherMouseUp(with event: NSEvent) {
        _ = host.sendMouseButton(surface, pressed: false, button: event.buttonNumber, modifiers: event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPosition(event)
    }

    override func mouseEntered(with event: NSEvent) {
        sendPosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        if NSEvent.pressedMouseButtons != 0 { return }
        host.sendMousePosition(surface, x: -1, y: -1, modifiers: event.modifierFlags)
    }

    override func scrollWheel(with event: NSEvent) {
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        var mods: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        host.sendScroll(surface, x: Double(x), y: Double(y), mods: mods)
    }

    override func keyDown(with event: NSEvent) {
        let translated = host.translatedModifiers(for: surface, flags: event.modifierFlags)
        let source = eventByApplying(translated, to: event)
        collecting = true
        collected = []
        interpretKeyEvents([source])
        collecting = false
        let action: GhosttyHost.KeyAction = event.isARepeat ? .repeat : .press
        if collected.isEmpty {
            send(action, event: event, characters: typedText(source), translation: translated, composing: marked.length > 0)
        } else {
            for text in collected {
                send(action, event: event, characters: text, translation: translated, composing: false)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        send(.release, event: event, characters: nil, translation: event.modifierFlags, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
        if marked.length > 0 { return }
        let deviceBit: UInt
        switch event.keyCode {
        case 0x39: deviceBit = NSEvent.ModifierFlags.capsLock.rawValue
        case 0x38: deviceBit = NSEvent.ModifierFlags.shift.rawValue
        case 0x3C: deviceBit = 0x4
        case 0x3B: deviceBit = NSEvent.ModifierFlags.control.rawValue
        case 0x3E: deviceBit = 0x2000
        case 0x3A: deviceBit = NSEvent.ModifierFlags.option.rawValue
        case 0x3D: deviceBit = 0x40
        case 0x37: deviceBit = NSEvent.ModifierFlags.command.rawValue
        case 0x36: deviceBit = 0x10
        default: return
        }
        let pressed = event.modifierFlags.rawValue & deviceBit != 0
        send(pressed ? .press : .release, event: event, characters: nil, translation: event.modifierFlags, composing: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        if Self.isAppShortcut(event) { return false }
        let action: GhosttyHost.KeyAction = event.isARepeat ? .repeat : .press
        let translated = host.translatedModifiers(for: surface, flags: event.modifierFlags)
        send(action, event: event, characters: typedText(event), translation: translated, composing: false)
        return true
    }

    override func doCommand(by selector: Selector) {}

    @objc func copy(_ sender: Any?) {
        _ = host.performBinding(surface, "copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        _ = host.performBinding(surface, "paste_from_clipboard")
    }

    @objc func pasteAsPlainText(_ sender: Any?) {
        _ = host.performBinding(surface, "paste_from_clipboard")
    }

    @objc override func selectAll(_ sender: Any?) {
        _ = host.performBinding(surface, "select_all")
    }

    func hasMarkedText() -> Bool { marked.length > 0 }

    func markedRange() -> NSRange {
        marked.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.length)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let value = Self.plain(string)
        marked = NSMutableAttributedString(string: value)
        host.sendPreedit(surface, value)
    }

    func unmarkText() {
        marked = NSMutableAttributedString()
        host.sendPreedit(surface, "")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = Self.plain(string)
        unmarkText()
        if collecting {
            collected.append(value)
        } else {
            let current = NSApp.currentEvent
            let translated = current.map { host.translatedModifiers(for: surface, flags: $0.modifierFlags) } ?? []
            send(.press, event: current, characters: value, translation: translated, composing: false)
        }
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let ime = host.imeRect(for: surface)
        let cell = host.cellSize(for: surface)
        let height = max(ime.height, cell.height > 0 ? cell.height : 16)
        let viewRect = NSRect(
            x: ime.x,
            y: bounds.height - ime.y,
            width: ime.width,
            height: height
        )
        let windowRect = convert(viewRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    private func sendPosition(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        host.sendMousePosition(
            surface,
            x: Double(point.x),
            y: Double(bounds.height - point.y),
            modifiers: event.modifierFlags
        )
    }

    private func send(
        _ action: GhosttyHost.KeyAction,
        event: NSEvent?,
        characters: String?,
        translation: NSEvent.ModifierFlags,
        composing: Bool
    ) {
        let source = event ?? NSApp.currentEvent
        let keyCode = source.map { UInt32($0.keyCode) } ?? 0
        let modifiers = source?.modifierFlags ?? []
        var unshifted: String?
        if let source, source.type == .keyDown || source.type == .keyUp {
            unshifted = source.characters(byApplyingModifiers: [])
        }
        host.sendKey(surface, GhosttyHost.KeyInput(
            action: action,
            keyCode: keyCode,
            modifiers: modifiers,
            translationModifiers: translation,
            characters: characters,
            unshifted: unshifted,
            composing: composing
        ))
    }

    private func typedText(_ event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    private func eventByApplying(_ flags: NSEvent.ModifierFlags, to event: NSEvent) -> NSEvent {
        if flags == event.modifierFlags { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private static func plain(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        return ""
    }

    static func isAppShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "t" || key == "w" || key == "q" { return true }
        if flags == [.command, .shift], key == "[" || key == "]" { return true }
        if flags.contains(.control), event.keyCode == 48 { return true }
        return false
    }
}
