import AppKit

final class TerminalSessionView: NSView {
    let terminal: TerminalSurfaceView
    let input: CommandInputView?
    override var isFlipped: Bool { true }

    init(terminal: TerminalSurfaceView) {
        self.terminal = terminal
        input = terminal.surface.commandInput.map { CommandInputView(bridge: $0) }
        super.init(frame: terminal.frame)
        addSubview(terminal)
        if let input {
            addSubview(input)
            input.onLayout = { [weak self] in self?.needsLayout = true }
            input.onTerminalFocus = { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.terminal)
            }
            input.onReady = { [weak self] in
                guard let self, !self.isHidden, self.window?.isKeyWindow == true,
                      self.window?.firstResponder === self.terminal, NSEvent.pressedMouseButtons == 0,
                      !GhosttyHost.shared.hasSelection(self.terminal.surface) else { return }
                self.input?.focus()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let height = min(input?.preferredHeight ?? 0, max(0, bounds.height - 100))
        input?.isHidden = height == 0
        input?.frame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        terminal.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - height))
    }

    func focus() {
        if input?.expanded == true { input?.focus() }
        else { window?.makeFirstResponder(terminal) }
    }
}
