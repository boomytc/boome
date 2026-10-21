import AppKit

private final class PromptCoverView: NSView {
    var onFocus: (() -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}

final class TerminalSessionView: NSView {
    let terminal: TerminalSurfaceView
    let input: CommandInputView?
    private let promptCover = PromptCoverView()
    override var isFlipped: Bool { true }

    init(terminal: TerminalSurfaceView) {
        self.terminal = terminal
        input = terminal.surface.commandInput.map { CommandInputView(bridge: $0) }
        super.init(frame: terminal.frame)
        addSubview(terminal)
        promptCover.wantsLayer = true
        promptCover.isHidden = true
        promptCover.setAccessibilityElement(false)
        addSubview(promptCover)
        promptCover.onScroll = { [weak self] event in self?.terminal.scrollWheel(with: event) }
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
            terminal.commandKeysBelongToEditor = { [weak input] in input?.ownsCommand == true }
            terminal.onEditorFocus = { [weak input] in input?.focus() }
            terminal.onReturnCommandKey = { [weak input] event in
                input?.focus()
                input?.textView.keyDown(with: event)
            }
            terminal.onViewportChange = { [weak self] in self?.needsLayout = true }
            promptCover.onFocus = { [weak input] in input?.focus() }
            input.preferTerminalCopy {
                guard GhosttyHost.shared.hasSelection(terminal.surface) else { return false }
                return GhosttyHost.shared.performBinding(terminal.surface, "copy_to_clipboard")
            }
        }
    }

    func use(background: NSColor) {
        input?.use(background: background)
        promptCover.layer?.backgroundColor = background.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let height = input?.gridInset(limit: max(0, bounds.height - 100)) ?? 0
        let inputFrame = NSRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        let terminalHeight = max(1, bounds.height - height)
        let terminalFrame = NSRect(x: 0, y: 0, width: bounds.width, height: terminalHeight)
        if input?.isHidden != (height == 0) { input?.isHidden = height == 0 }
        if input?.frame != inputFrame { input?.frame = inputFrame }
        // Assigning the same frame still reaches the terminal and resizes the grid.
        if terminal.frame != terminalFrame { terminal.frame = terminalFrame }
        let cover = input?.ownsCommand == true
            ? CommandPromptCover.height(top: GhosttyHost.shared.promptTop(for: terminal.surface), terminalHeight: terminalHeight)
            : 0
        let coverFrame = NSRect(x: 0, y: terminalHeight - cover, width: bounds.width, height: cover)
        if promptCover.isHidden != (cover <= 0) { promptCover.isHidden = cover <= 0 }
        if promptCover.frame != coverFrame { promptCover.frame = coverFrame }
    }

    func focus() {
        if input?.expanded == true { input?.focus() }
        else { window?.makeFirstResponder(terminal) }
    }
}
