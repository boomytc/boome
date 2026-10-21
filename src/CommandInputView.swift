import AppKit

private final class CommandTextView: NSTextView {
    var onTerminalControl: ((NSEvent) -> Bool)?
    var onCopySelection: (() -> Bool)?
    var suggestion = ""
    var suggestionColor = NSColor.secondaryLabelColor
    private(set) var keyEvent: NSEvent?
    private(set) var wasComposing = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override func keyDown(with event: NSEvent) {
        keyEvent = event; wasComposing = hasMarkedText()
        defer { keyEvent = nil; wasComposing = false }
        if !wasComposing, onTerminalControl?(event) == true { return }
        super.keyDown(with: event)
    }
    override func copy(_ sender: Any?) {
        if selectedRange().length == 0, onCopySelection?() == true { return }
        super.copy(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let length = (string as NSString).length
        guard !suggestion.isEmpty, selectedRange() == NSRange(location: length, length: 0), let window else { return }
        var unused = NSRange()
        var caret = firstRect(forCharacterRange: NSRange(location: length, length: 0), actualRange: &unused)
        caret = convert(window.convertFromScreen(caret), from: nil)
        guard caret.width >= 0, caret.height > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: suggestionColor,
            .paragraphStyle: style,
        ]
        (suggestion as NSString).draw(
            with: NSRect(x: caret.maxX, y: caret.minY, width: max(0, bounds.maxX - caret.maxX), height: caret.height),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
    }
}

enum CommandPromptCover {
    /// Height of the active prompt measured from its top to the bottom of the terminal view.
    static func height(top: CGFloat?, terminalHeight: CGFloat) -> CGFloat {
        guard let top, top.isFinite, top >= 0, terminalHeight > top else { return 0 }
        return terminalHeight - top
    }
}

enum CommandGridInset {
    /// Space the editor occupies. While a command is running, keep the previous
    /// height. Giving those rows back resizes the grid, and that resize clears
    /// the prompt line. zsh does not redraw a command it has already accepted.
    static func height(editor: CGFloat, reserved: CGFloat, hold: Bool, limit: CGFloat) -> CGFloat {
        let chosen = editor > 0 ? editor : (hold ? reserved : 0)
        guard chosen > 0, limit > 0 else { return 0 }
        return min(chosen, limit)
    }
}

/// An independent text document per session; terminal output is never edited.
final class CommandInputView: NSView, NSTextViewDelegate {
    let textView: NSTextView = CommandTextView()
    private let bridge: CommandInputBridge
    private let scroll = NSScrollView()
    private let caption = NSTextField(labelWithString: "ZSH")
    private let run = NSButton(title: "Run ⏎", target: nil, action: nil)
    private let keep = NSButton(title: "Use draft", target: nil, action: nil)
    private let useShell = NSButton(title: "Use shell", target: nil, action: nil)
    private let commandUndo = UndoManager()
    private var base: CommandInputProtocol.Snapshot?
    private var dirty = false
    private var interactionLocked = false
    private var conflict = false
    private var applyingSnapshot = false
    private var suggestWork: DispatchWorkItem?
    private var suggestAgain = false
    private var suggestedLine = ""
    private var layoutToken = ""
    private var lastInputHeight: CGFloat = -1
    private(set) var suggestionSuffix = ""
    private var searchQuery: String?
    private var searchOrigin = ""
    private var lastCompletion: String?
    private var submitted: CommandInputProtocol.Identity?
    private var reservedGridInset: CGFloat = 0
    private var wasWaiting = false
    private(set) var expanded = false
    var onLayout: (() -> Void)?
    var onTerminalFocus: (() -> Void)?
    var onReady: (() -> Void)?
    var preferredHeight: CGFloat {
        guard expanded else { return 0 }
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        return min(220, max(94, (textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40) + 52))
    }
    /// True while the submitted command is still the active prompt. The grid
    /// must keep its size until the next prompt, or the resize erases that command.
    var holdsGridSize: Bool {
        guard let submitted, let snapshot = bridge.snapshot else { return false }
        return snapshot.state == "busy"
            && submitted.generation == snapshot.identity.generation
            && submitted.epoch == snapshot.identity.epoch
    }
    func gridInset(limit: CGFloat) -> CGFloat {
        let editor = preferredHeight
        if editor > 0 { reservedGridInset = editor }
        return CommandGridInset.height(editor: editor, reserved: reservedGridInset, hold: holdsGridSize, limit: limit)
    }
    private var inputBlocked: Bool {
        guard let action = bridge.pending?.action else { return false }
        return action != .suggest
    }
    var ownsCommand: Bool { expanded && !inputBlocked && textView.isEditable }
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
        for child in [caption, run, keep, useShell, scroll] { addSubview(child) }
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.lineBreakMode = .byTruncatingTail
        for (button, action, identifier) in [
            (run, #selector(submit), "CommandRun"),
            (keep, #selector(keepDraft), "CommandUseDraft"),
            (useShell, #selector(loadShell), "CommandUseShell"),
        ] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        run.toolTip = "Execute in this zsh session (Enter). Shift+Enter inserts a newline. Ctrl+R searches history."
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
        (textView as? CommandTextView)?.suggestionColor = BoomeChrome.secondaryText(selected: false, on: background)
        caption.textColor = BoomeChrome.secondaryText(selected: false, on: background)
        for button in [run, keep, useShell] {
            button.contentTintColor = BoomeChrome.text(selected: true, on: background)
        }
    }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 12, y: 8, width: max(0, bounds.width - (conflict ? 180 : 80)), height: 17)
        run.frame = NSRect(x: bounds.width - 68, y: 3, width: 58, height: 26)
        keep.frame = NSRect(x: bounds.width - 164, y: 3, width: 76, height: 26)
        useShell.frame = NSRect(x: bounds.width - 84, y: 3, width: 76, height: 26)
        scroll.frame = NSRect(x: 1, y: 32, width: max(0, bounds.width - 2), height: max(0, bounds.height - 33))
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, textView.frame.height)))
    }

    func focus() {
        guard expanded, !interactionLocked, bridge.pending == nil, bridge.snapshot?.isReady == true else { return }
        superview?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(textView)
    }

    func preferTerminalCopy(_ copy: @escaping () -> Bool) {
        (textView as? CommandTextView)?.onCopySelection = copy
    }

    private func adopt(_ snapshot: CommandInputProtocol.Snapshot) {
        applyingSnapshot = true
        defer { applyingSnapshot = false }
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
        wasWaiting = inputBlocked
        let focused = isFocused
        let snapshot = bridge.snapshot
        if let (request, accepted) = bridge.completion, request.id != lastCompletion {
            lastCompletion = request.id
            if accepted {
                dirty = false; conflict = false
                var keepTyping = false
                switch request.action {
                case .submit:
                    searchQuery = nil
                    show(suggestion: "")
                    textView.string = ""
                    textView.undoManager?.removeAllActions()
                    submitted = request.identity
                case .search: break
                case .suggest:
                    if textView.string == snapshot?.text {
                        base = snapshot
                        show(suggestion: snapshot?.suggestion ?? "")
                        if suggestAgain { suggestAgain = false; scheduleSuggest() }
                    } else {
                        keepTyping = true
                        dirty = textView.string != base?.text
                        suggestAgain = false
                        scheduleSuggest()
                    }
                case .terminal, .complete, .previous, .next, .cancel:
                    searchQuery = nil
                }
                if !keepTyping, request.action != .submit && request.action != .suggest, let snapshot {
                    adopt(snapshot)
                    show(suggestion: snapshot.suggestion)
                }
            } else {
                searchQuery = nil
                conflict = dirty
            }
        }
        if let snapshot, snapshot.isReady {
            let samePrompt = base.map { $0.identity.generation == snapshot.identity.generation && $0.identity.epoch == snapshot.identity.epoch } ?? false
            if !samePrompt { searchQuery = nil }
            if textView.hasMarkedText() { dirty = true }
            if !dirty && !conflict { adopt(snapshot) }
            else if let base, base.identity != snapshot.identity,
                    base.text != snapshot.text || !samePrompt { conflict = true }
            else if !conflict {
                base = snapshot
                if textView.string == snapshot.text { show(suggestion: snapshot.suggestion) }
            }
        }
        let waitingForNextPrompt = submitted.map {
            $0.generation == snapshot?.identity.generation && $0.epoch == snapshot?.identity.epoch
        } ?? false
        expanded = inputBlocked || bridge.pending != nil || (snapshot?.isReady == true && !waitingForNextPrompt)
        scroll.isHidden = !expanded
        run.isHidden = !expanded || conflict
        keep.isHidden = !expanded || !conflict
        useShell.isHidden = keep.isHidden
        let available = !interactionLocked && snapshot?.isReady == true && !inputBlocked
        if textView.isEditable != available { textView.isEditable = available }
        let runEnabled = available && !conflict && !waitingForNextPrompt && !textView.hasMarkedText()
        if run.isEnabled != runEnabled { run.isEnabled = runEnabled }
        if keep.isEnabled != available { keep.isEnabled = available }
        if useShell.isEnabled != available { useShell.isEnabled = available }
        let captionText = bridge.error ?? (conflict ? "Shell changed · draft kept" :
            inputBlocked ? "Waiting for zsh…" :
            searchQuery != nil ? "History · ⏎ run · ⎋ back" : "ZSH  ·  ⇧Enter newline")
        if caption.stringValue != captionText {
            caption.stringValue = captionText
            caption.toolTip = captionText
        }
        let token = "\(expanded) \(Int(preferredHeight.rounded())) \(captionText)"
        if token != layoutToken {
            layoutToken = token
            lastInputHeight = preferredHeight
            needsLayout = true
            onLayout?()
        }
        if focused && (!expanded || !available) && bridge.pending == nil { onTerminalFocus?() }
        if expanded && (!wasExpanded || previouslyWaiting) && available { onReady?() }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { commandUndo }

    func textDidChange(_ notification: Notification) {
        if !applyingSnapshot {
            searchQuery = nil
            let typed = textView.string
            let atEnd = textView.selectedRange() == NSRange(location: (typed as NSString).length, length: 0)
            if atEnd, !typed.isEmpty, !suggestedLine.isEmpty, suggestedLine.hasPrefix(typed), suggestedLine.count > typed.count {
                let rest = suggestedLine.index(suggestedLine.startIndex, offsetBy: typed.count)
                show(suggestion: String(suggestedLine[rest...]))
            } else {
                show(suggestion: "")
            }
            scheduleSuggest()
        }
        dirty = textView.string != base?.text
        refreshControls()
        let height = preferredHeight
        guard abs(height - lastInputHeight) > 0.5 else { return }
        lastInputHeight = height
        onLayout?()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        (textView as? CommandTextView)?.needsDisplay = true
        refreshControls()
    }

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

    @discardableResult
    private func perform(_ action: CommandInputProtocol.Action) -> Bool {
        guard !interactionLocked, !textView.hasMarkedText() else { return false }
        guard bridge.pending == nil, !conflict,
              let base, let current = bridge.snapshot, current.isReady,
              base.identity == current.identity else {
            bridge.poll(); receive(); return false
        }
        let text: String
        let cursor: Int
        if action == .search {
            if searchQuery == nil {
                searchOrigin = textView.string
                searchQuery = textView.string
            }
            text = searchQuery ?? ""
            cursor = text.unicodeScalars.count
        } else {
            if action == .submit { searchQuery = nil }
            text = textView.string
            let range = textView.selectedRange()
            let head = textView.selectionAffinity == .upstream ? range.location : NSMaxRange(range)
            cursor = CommandInputProtocol.scalarOffset(in: text, utf16Offset: head)
        }
        return bridge.send(action, text: text, cursor: cursor, expectedIdentity: base.identity)
    }

    private func show(suggestion: String) {
        suggestionSuffix = suggestion
        suggestedLine = suggestion.isEmpty ? "" : textView.string + suggestion
        guard (textView as? CommandTextView)?.suggestion != suggestion else { return }
        (textView as? CommandTextView)?.suggestion = suggestion
        textView.needsDisplay = true
    }

    private func scheduleSuggest() {
        suggestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendSuggest() }
        suggestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func sendSuggest() {
        guard searchQuery == nil, !conflict, !textView.hasMarkedText() else { return }
        let length = (textView.string as NSString).length
        guard !textView.string.isEmpty, textView.selectedRange() == NSRange(location: length, length: 0) else { return }
        if bridge.pending?.action == .suggest {
            suggestAgain = true
            return
        }
        if !perform(.suggest) { suggestAgain = true }
    }

    private func acceptSuggestion(partial: Bool) -> Bool {
        let length = (textView.string as NSString).length
        guard !suggestionSuffix.isEmpty, textView.selectedRange() == NSRange(location: length, length: 0) else { return false }
        let addition: String
        if partial, let space = suggestionSuffix.firstIndex(of: " ") {
            addition = String(suggestionSuffix[...space])
        } else {
            addition = suggestionSuffix
        }
        guard !addition.isEmpty else { return false }
        show(suggestion: "")
        textView.insertText(addition, replacementRange: NSRange(location: length, length: 0))
        return true
    }

    func setInteractionLocked(_ locked: Bool) {
        interactionLocked = locked
        receive()
    }

    @objc func submit() { perform(.submit) }
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
            if key == "c" {
                searchQuery = nil
                perform(.cancel)
            } else { perform(.search) }
            return true
        }
        return false
    }

    private func exitSearch() {
        let origin = searchOrigin
        searchQuery = nil
        applyingSnapshot = true
        textView.string = origin
        applyingSnapshot = false
        dirty = textView.string != base?.text
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        refreshControls()
        receive()
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
        case #selector(NSResponder.moveRight(_:)):
            if acceptSuggestion(partial: false) { return true }
        case #selector(NSResponder.moveToRightEndOfLine(_:)):
            if acceptSuggestion(partial: false) { return true }
        case #selector(NSResponder.moveWordRight(_:)):
            if acceptSuggestion(partial: true) { return true }
        case #selector(NSResponder.cancelOperation(_:)):
            if textView.hasMarkedText() || (textView as? CommandTextView)?.wasComposing == true { return false }
            if searchQuery != nil { exitSearch() }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if atVisualBoundary(first: true) { perform(.previous); return true }
        case #selector(NSResponder.moveDown(_:)):
            if atVisualBoundary(first: false) { perform(.next); return true }
        default: break
        }
        return false
    }
}
