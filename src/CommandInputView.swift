import AppKit

private final class CommandTextView: NSTextView {
    var onTerminalControl: ((NSEvent) -> Bool)?
    private(set) var keyEvent: NSEvent?
    private(set) var wasComposing = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func keyDown(with event: NSEvent) {
        keyEvent = event; wasComposing = hasMarkedText()
        defer { keyEvent = nil; wasComposing = false }
        if !wasComposing, onTerminalControl?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// An independent text document per session; terminal output is never edited.
final class CommandInputView: NSView, NSTextViewDelegate {
    let textView: NSTextView = CommandTextView()
    private let bridge: CommandInputBridge
    private let scroll = NSScrollView()
    private let caption = NSTextField(labelWithString: "ZSH")
    private let run = NSButton(title: "Run ⏎", target: nil, action: nil)
    private let terminal = NSButton(title: "Terminal", target: nil, action: nil)
    private let resume = NSButton(title: "Edit command", target: nil, action: nil)
    private let keep = NSButton(title: "Use draft", target: nil, action: nil)
    private let useShell = NSButton(title: "Use shell", target: nil, action: nil)
    private let commandUndo = UndoManager()
    private var base: CommandInputProtocol.Snapshot?
    private var dirty = false
    private var interactionLocked = false
    private var conflict = false
    private var terminalMode = false
    private var lastCompletion: String?
    private var submitted: CommandInputProtocol.Identity?
    private var wasWaiting = false
    private(set) var expanded = false
    var onLayout: (() -> Void)?
    var onTerminalFocus: (() -> Void)?
    var onReady: (() -> Void)?
    var preferredHeight: CGFloat {
        guard bridge.snapshot?.isReady == true || bridge.pending != nil else { return 0 }
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        return expanded ? min(220, max(94, (textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40) + 52)) : 32
    }
    var isFocused: Bool { window?.firstResponder === textView }
    var hasDraft: Bool {
        (dirty || textView.hasMarkedText() || bridge.snapshot?.isReady == true) && !textView.string.isEmpty
    }
    override var isFlipped: Bool { true }

    init(bridge: CommandInputBridge) {
        self.bridge = bridge
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command Input")
        setAccessibilityIdentifier("CommandInput")
        for child in [caption, run, terminal, resume, keep, useShell, scroll] { addSubview(child) }
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.lineBreakMode = .byTruncatingTail
        for (button, action, identifier) in [
            (run, #selector(submit), "CommandRun"), (terminal, #selector(returnToTerminal), "CommandTerminal"),
            (resume, #selector(resumeEditing), "CommandResume"), (keep, #selector(keepDraft), "CommandUseDraft"),
            (useShell, #selector(loadShell), "CommandUseShell"),
        ] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        run.toolTip = "Execute in this zsh session (Enter). Shift+Enter inserts a newline."
        terminal.toolTip = "Continue in the terminal's shell editor (Escape). Tab transfers to shell completion."
        resume.toolTip = "Edit this shell command with native text selection"
        keep.toolTip = "Keep this draft for review without executing or changing shell input"
        useShell.toolTip = "Discard the native draft and use the shell’s current command"
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.setAccessibilityIdentifier("CommandText")
        textView.setAccessibilityLabel("Command")
        (textView as! CommandTextView).onTerminalControl = { [weak self] event in self?.terminalControl(event) ?? false }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        bridge.draftIsPresent = { [weak self] in self?.hasDraft ?? false }
        bridge.onChange = { [weak self] in self?.receive() }
        use(background: BoomeChrome.fallbackBackground)
        receive()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func use(background: NSColor) {
        layer?.backgroundColor = BoomeChrome.selectionFill(on: background).cgColor
        textView.backgroundColor = background
        scroll.backgroundColor = background
        textView.textColor = BoomeChrome.text(selected: true, on: background)
        textView.insertionPointColor = textView.textColor
        caption.textColor = BoomeChrome.secondaryText(selected: false, on: background)
        for button in [run, terminal, resume, keep, useShell] {
            button.contentTintColor = BoomeChrome.text(selected: true, on: background)
        }
    }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 12, y: 8, width: max(0, bounds.width - (conflict ? 250 : 150)), height: 17)
        run.frame = NSRect(x: bounds.width - 68, y: 3, width: 58, height: 26)
        terminal.frame = NSRect(x: bounds.width - 142, y: 3, width: 70, height: 26)
        resume.frame = NSRect(x: bounds.width - 115, y: 3, width: 104, height: 26)
        keep.frame = NSRect(x: bounds.width - 226, y: 3, width: 72, height: 26)
        useShell.frame = NSRect(x: bounds.width - 150, y: 3, width: 76, height: 26)
        scroll.frame = NSRect(x: 1, y: 32, width: max(0, bounds.width - 2), height: max(0, bounds.height - 33))
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, textView.frame.height)))
    }

    func focus() {
        guard expanded, !interactionLocked, bridge.pending == nil, bridge.snapshot?.isReady == true else { return }
        superview?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(textView)
    }

    private func adopt(_ snapshot: CommandInputProtocol.Snapshot) {
        let changed = textView.string != snapshot.text
        if changed {
            textView.string = snapshot.text
            textView.undoManager?.removeAllActions()
        }
        let caretChanged = base?.cursor != snapshot.cursor || base?.identity.generation != snapshot.identity.generation || base?.identity.epoch != snapshot.identity.epoch
        if changed || caretChanged {
            textView.setSelectedRange(NSRange(location: CommandInputProtocol.utf16Offset(in: snapshot.text, scalarOffset: snapshot.cursor), length: 0))
        }
        base = snapshot; dirty = false; conflict = false
    }

    private func receive() {
        let wasExpanded = expanded
        let previouslyWaiting = wasWaiting
        wasWaiting = bridge.pending != nil
        let focused = isFocused
        let snapshot = bridge.snapshot
        if let (request, accepted) = bridge.completion, request.id != lastCompletion {
            lastCompletion = request.id
            if accepted {
                dirty = false; conflict = false
                switch request.action {
                case .submit:
                    textView.string = ""
                    textView.undoManager?.removeAllActions()
                    submitted = request.identity
                case .terminal, .complete, .search: terminalMode = true
                case .previous, .next, .cancel: break
                }
                if request.action != .submit, let snapshot { adopt(snapshot) }
            } else { conflict = dirty }
        }
        if let snapshot, snapshot.isReady {
            let samePrompt = base.map { $0.identity.generation == snapshot.identity.generation && $0.identity.epoch == snapshot.identity.epoch } ?? false
            if !samePrompt { terminalMode = false }
            if textView.hasMarkedText() { dirty = true }
            if !dirty && !conflict { adopt(snapshot) }
            else if let base, base.identity != snapshot.identity,
                    base.text != snapshot.text || !samePrompt { conflict = true }
            else if !conflict { base = snapshot }
        }
        let waitingForNextPrompt = submitted.map {
            $0.generation == snapshot?.identity.generation && $0.epoch == snapshot?.identity.epoch
        } ?? false
        expanded = bridge.pending != nil || (snapshot?.isReady == true && !terminalMode && !waitingForNextPrompt)
        scroll.isHidden = !expanded
        run.isHidden = !expanded
        terminal.isHidden = !expanded || conflict
        resume.isHidden = expanded
        keep.isHidden = !expanded || !conflict
        useShell.isHidden = keep.isHidden
        let available = !interactionLocked && snapshot?.isReady == true && bridge.pending == nil
        textView.isEditable = available
        run.isEnabled = available && !conflict && !waitingForNextPrompt && !textView.hasMarkedText()
        terminal.isEnabled = available && !conflict
        resume.isEnabled = available
        keep.isEnabled = available; useShell.isEnabled = available
        caption.stringValue = bridge.error ?? (conflict ? "Shell changed · draft kept" :
            bridge.pending != nil ? "Waiting for zsh…" : expanded ? "ZSH  ·  ⇧Enter newline" : "Shell input")
        caption.toolTip = caption.stringValue
        needsLayout = true
        onLayout?()
        if focused && (!expanded || !available) && bridge.pending == nil { onTerminalFocus?() }
        if expanded && (!wasExpanded || previouslyWaiting) && available { onReady?() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { commandUndo }

    func textDidChange(_ notification: Notification) {
        dirty = textView.string != base?.text
        refreshControls()
        onLayout?()
    }
    func textViewDidChangeSelection(_ notification: Notification) { refreshControls() }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard !interactionLocked else { return false }
        guard let replacementString else { return true }
        guard NSMaxRange(range) <= (textView.string as NSString).length, !replacementString.contains("\0") else { return false }
        let proposed = (textView.string as NSString).replacingCharacters(in: range, with: replacementString)
        return proposed.utf8.count <= CommandInputProtocol.maximumBytes - 2048
    }

    private func refreshControls() {
        run.isEnabled = !interactionLocked && bridge.snapshot?.isReady == true && bridge.pending == nil && !conflict && !textView.hasMarkedText()
    }

    private func perform(_ action: CommandInputProtocol.Action) {
        guard !interactionLocked, !textView.hasMarkedText() else { return }
        guard bridge.pending == nil, !conflict,
              let base, let current = bridge.snapshot, current.isReady,
              base.identity == current.identity else {
            bridge.poll(); receive(); return
        }
        let range = textView.selectedRange()
        let head = textView.selectionAffinity == .upstream ? range.location : NSMaxRange(range)
        let cursor = CommandInputProtocol.scalarOffset(in: textView.string, utf16Offset: head)
        _ = bridge.send(action, text: textView.string, cursor: cursor, expectedIdentity: base.identity)
    }

    func setInteractionLocked(_ locked: Bool) {
        interactionLocked = locked
        receive()
    }

    @objc func submit() { perform(.submit) }
    @objc private func returnToTerminal() { perform(.terminal) }
    @objc private func resumeEditing() {
        guard !interactionLocked else { return }
        bridge.clearError()
        guard let snapshot = bridge.snapshot, snapshot.isReady, bridge.pending == nil else { return }
        terminalMode = false; submitted = nil
        receive(); focus()
    }
    @objc private func keepDraft() {
        guard !interactionLocked else { return }
        bridge.clearError()
        guard let snapshot = bridge.snapshot, snapshot.isReady, bridge.pending == nil else { return }
        base = snapshot; conflict = false
        dirty = textView.string != snapshot.text
        receive(); focus()
    }
    @objc private func loadShell() {
        guard !interactionLocked else { return }
        bridge.clearError()
        guard let snapshot = bridge.snapshot, bridge.pending == nil else { return }
        adopt(snapshot); receive(); focus()
    }

    private func terminalControl(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, let key = event.charactersIgnoringModifiers?.lowercased(),
           ["c", "r"].contains(key) {
            if key == "c" { perform(.cancel) }
            else { perform(.search) }
            return true
        }
        return false
    }

    private func atVisualBoundary(first: Bool) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let length = (textView.string as NSString).length
        if length == 0 { return true }
        if selection.location == length, textView.string.hasSuffix("\n") { return !first }
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return false }
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: min(selection.location, length - 1))
        var line = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        return first ? line.location == 0 : NSMaxRange(line) >= layout.numberOfGlyphs
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if (textView as? CommandTextView)?.wasComposing == true { return true }
            let flags = (textView as? CommandTextView)?.keyEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) { textView.insertText("\n", replacementRange: textView.selectedRange()) }
            else { submit() }
            return true
        case #selector(NSResponder.insertTab(_:)): perform(.complete); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if textView.hasMarkedText() || (textView as? CommandTextView)?.wasComposing == true { return false }
            perform(.terminal); return true
        case #selector(NSResponder.moveUp(_:)):
            if atVisualBoundary(first: true) { perform(.previous); return true }
        case #selector(NSResponder.moveDown(_:)):
            if atVisualBoundary(first: false) { perform(.next); return true }
        default: break
        }
        return false
    }
}
