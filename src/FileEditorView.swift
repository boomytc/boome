import AppKit

private final class EditorContentView: NSView {
    override var isFlipped: Bool { true }
}

final class FileEditorView: NSView, NSTextViewDelegate {
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var document: ProjectTextFile?
    private(set) var isBusy = false
    var hasUnsavedChanges: Bool { document.map { $0.savedText != textView.string } ?? false }
    var isFocused: Bool { (window?.firstResponder as? NSView)?.isDescendant(of: self) == true }

    private let content = EditorContentView()
    private let title = NSTextField(labelWithString: "Editor")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let closeButton = NSButton()
    private let status = NSTextField(labelWithString: "Select a file in Project Explorer")
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let placeholder = NSTextField(wrappingLabelWithString: "Open a text file from Project Explorer to edit it here.")
    private let queue = DispatchQueue(label: "com.boom.boome.file-editor", qos: .userInitiated)
    private var confirming = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File Editor")
        setAccessibilityIdentifier("FileEditor")
        addSubview(content)
        for view in [title, saveButton, closeButton, scroll, status, placeholder] { content.addSubview(view) }
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        saveButton.isBordered = false
        saveButton.font = .systemFont(ofSize: 12, weight: .medium)
        saveButton.target = self
        saveButton.action = #selector(saveAction(_:))
        saveButton.toolTip = "Save (⌘S)"
        saveButton.setAccessibilityIdentifier("EditorSave")
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeAction(_:))
        closeButton.toolTip = "Close Editor"
        closeButton.setAccessibilityLabel("Close Editor")
        status.font = .systemFont(ofSize: 10)
        status.lineBreakMode = .byTruncatingTail
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.alignment = .center
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.setAccessibilityIdentifier("EditorText")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        use(background: BoomeChrome.fallbackBackground)
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let width = max(300, bounds.width)
        content.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        title.frame = NSRect(x: 12, y: 12, width: width - 94, height: 18)
        saveButton.frame = NSRect(x: width - 78, y: 8, width: 46, height: 26)
        closeButton.frame = NSRect(x: width - 30, y: 8, width: 24, height: 26)
        scroll.frame = NSRect(x: 0, y: 42, width: width, height: max(0, bounds.height - 72))
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(textView.frame.height, scroll.contentSize.height)))
        status.frame = NSRect(x: 12, y: max(42, bounds.height - 25), width: width - 24, height: 18)
        placeholder.frame = NSRect(x: 24, y: max(60, bounds.height / 2 - 32), width: width - 48, height: 64)
    }

    func use(background: NSColor) {
        layer?.backgroundColor = background.cgColor
        textView.backgroundColor = background
        scroll.backgroundColor = background
        textView.textColor = BoomeChrome.text(selected: true, on: background)
        textView.insertionPointColor = BoomeChrome.text(selected: true, on: background)
        title.textColor = BoomeChrome.text(selected: true, on: background)
        status.textColor = BoomeChrome.secondaryText(selected: false, on: background)
        placeholder.textColor = status.textColor
        closeButton.contentTintColor = status.textColor
        saveButton.contentTintColor = title.textColor
    }

    func focus() { if document != nil { window?.makeFirstResponder(textView) } }

    func open(_ url: URL) {
        guard !isBusy, !confirming else { return }
        if document?.url == url { onShow?(); focus(); return }
        prepareToLeave { [weak self] allowed in
            guard allowed, let self else { return }
            self.onShow?()
            self.isBusy = true
            self.updateChrome()
            self.status.stringValue = "Opening \(url.lastPathComponent)…"
            self.queue.async { [weak self] in
                let result = Result { try ProjectTextFile.read(url) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isBusy = false
                    switch result {
                    case .success(let file):
                        self.document = file
                        self.textView.string = file.savedText
                        self.textView.undoManager?.removeAllActions()
                        self.textView.setSelectedRange(NSRange(location: 0, length: 0))
                        self.focus()
                    case .failure(let error): self.showError("Could not open \(url.lastPathComponent)", error: error)
                    }
                    self.updateChrome()
                }
            }
        }
    }

    func save(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isBusy, let file = document else { completion(false); return }
        if !hasUnsavedChanges { completion(true); return }
        write(file, text: textView.string, overwrite: false, completion: completion)
    }

    private func write(_ file: ProjectTextFile, text: String, overwrite: Bool, completion: @escaping (Bool) -> Void) {
        isBusy = true
        updateChrome()
        status.stringValue = "Saving…"
        queue.async { [weak self] in
            let result = Result { () throws -> ProjectTextFile in
                var updated = file
                try updated.save(text, overwrite: overwrite)
                return updated
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let updated):
                    self.document = updated
                    self.updateChrome()
                    completion(true)
                case .failure(let error):
                    self.updateChrome()
                    if case TextFileError.changedOnDisk = error, !overwrite, let window = self.window {
                        let alert = NSAlert()
                        alert.messageText = "This file changed outside Boome"
                        alert.informativeText = "Overwrite the external changes with your edits? Cancel keeps both the disk file and your unsaved buffer unchanged."
                        alert.addButton(withTitle: "Cancel")
                        alert.addButton(withTitle: "Overwrite")
                        self.confirming = true
                        alert.beginSheetModal(for: window) { [weak self] response in
                            guard let self else { return }
                            self.confirming = false
                            if response == .alertSecondButtonReturn {
                                self.write(file, text: text, overwrite: true, completion: completion)
                            } else { completion(false) }
                        }
                    } else {
                        self.showError("Could not save \(file.url.lastPathComponent)", error: error)
                        completion(false)
                    }
                }
            }
        }
    }

    func prepareToLeave(_ completion: @escaping (Bool) -> Void) {
        guard !isBusy, !confirming else { completion(false); return }
        guard hasUnsavedChanges, let document else { completion(true); return }
        guard let window else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.url.lastPathComponent)?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        confirming = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.confirming = false
            switch response {
            case .alertFirstButtonReturn: self.save(completion: completion)
            case .alertSecondButtonReturn:
                self.textView.string = document.savedText
                self.textView.undoManager?.removeAllActions()
                self.updateChrome()
                completion(true)
            default: completion(false)
            }
        }
    }

    @objc private func saveAction(_ sender: Any?) { save() }
    @objc private func closeAction(_ sender: Any?) { onClose?() }

    func textDidChange(_ notification: Notification) { updateChrome() }
    func textViewDidChangeSelection(_ notification: Notification) { updateStatus() }

    private func updateChrome() {
        title.stringValue = document.map { (hasUnsavedChanges ? "● " : "") + $0.url.lastPathComponent } ?? "Editor"
        title.toolTip = document?.url.path
        saveButton.isEnabled = document != nil && hasUnsavedChanges && !isBusy
        closeButton.isEnabled = !isBusy
        textView.isEditable = document != nil && !isBusy
        scroll.isHidden = document == nil
        placeholder.isHidden = document != nil
        updateStatus()
    }

    private func updateStatus() {
        guard let document else { status.stringValue = "Select a file in Project Explorer"; return }
        let text = textView.string as NSString
        let offset = min(text.length, textView.selectedRange().location)
        let prefix = text.substring(to: offset)
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let lastNewline = (prefix as NSString).range(of: "\n", options: .backwards).location
        let col = lastNewline == NSNotFound ? offset + 1 : offset - lastNewline
        status.stringValue = "Ln \(line), Col \(col)   ·   UTF-8\(document.lineEnding == "\r\n" ? " · CRLF" : "")"
        status.toolTip = document.url.path
    }

    private func showError(_ title: String, error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
