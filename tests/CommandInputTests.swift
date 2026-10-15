import AppKit

enum CommandInputTests {
    static func run(_ check: (String, Bool) -> Void) {
        _ = NSApplication.shared
        typealias P = CommandInputProtocol
        let unicode = "a👩‍💻中\ne\u{301}\n"
        let data = P.encode(["", unicode, "tail"])!
        check("command protocol preserves Unicode and trailing newlines", P.decode(data, count: 3) == ["", unicode, "tail"])
        check("command protocol rejects NUL", P.encode(["a\0b"]) == nil)
        check("command protocol rejects oversized frames", P.encode([String(repeating: "x", count: P.maximumBytes)]) == nil)
        check("command protocol rejects missing terminator", P.decode(Data("a".utf8), count: 1) == nil)
        check("command protocol rejects invalid UTF8", P.decode(Data([0xff, 0]), count: 1) == nil)
        check("command protocol rejects wrong field count", P.decode(data, count: 2) == nil)
        check("UTF16 cursor converts emoji boundary", P.scalarOffset(in: "a👩b", utf16Offset: 3) == 2)
        check("UTF16 half surrogate clamps backward", P.scalarOffset(in: "a👩b", utf16Offset: 2) == 1)
        check("shell scalar cursor maps to UTF16", P.utf16Offset(in: "a👩b", scalarOffset: 2) == 3)
        check("cursor conversion clamps negative and overflow", P.scalarOffset(in: unicode, utf16Offset: -1) == 0 && P.utf16Offset(in: unicode, scalarOffset: 999) == unicode.utf16.count)

        guard let bridge = CommandInputBridge() else { check("private command mailbox created", false); return }
        defer { bridge.close() }
        let fd = Darwin.open(bridge.directory.appendingPathComponent("notify").path, O_RDWR | O_NONBLOCK)
        defer { if fd >= 0 { Darwin.close(fd) } }
        func frame(state: String = "ready", text: String = "", cursor: Int = 0, epoch: Int = 1,
                   revision: Int = 1, acknowledgement: String = "", result: String = "", pid: Int = 123) -> Data {
            P.encode(["BOOME1", bridge.token, String(pid), "generation", String(epoch), String(revision),
                      state, text, String(cursor), "main", "start", acknowledgement, result])!
        }
        func publish(_ data: Data) {
            try! data.write(to: bridge.directory.appendingPathComponent("state"), options: .atomic)
            bridge.poll()
        }
        let ready = frame(text: unicode, cursor: unicode.unicodeScalars.count)
        let snapshot = P.Snapshot(data: ready, token: bridge.token)!
        check("ready snapshot accepts scalar cursor", snapshot.isReady && snapshot.text == unicode)
        check("snapshot rejects wrong session token", P.Snapshot(data: ready, token: "wrong") == nil)
        check("snapshot rejects out of bounds cursor", P.Snapshot(data: frame(text: "x", cursor: 2), token: bridge.token) == nil)
        check("busy snapshot is not editable", P.Snapshot(data: frame(state: "busy"), token: bridge.token)?.isReady == false)
        publish(frame())
        let input = CommandInputView(bridge: bridge)
        check("supported shell expands command input", input.expanded)
        input.textView.string = unicode
        input.textDidChange(Notification(name: NSText.didChangeNotification))
        input.textView.setSelectedRange(NSRange(location: 1, length: 5))
        check("native command document retains Unicode selection", input.textView.selectedRange() == NSRange(location: 1, length: 5))
        check("native command edits are tracked as unsent", bridge.hasDraft)
        var commits = 0
        bridge.onCommit = { _ in commits += 1; return true }
        check("request uses private mailbox", bridge.send(.submit, text: unicode, cursor: unicode.unicodeScalars.count))
        let request = bridge.pending!
        check("duplicate submit blocked while request pending", !bridge.send(.submit, text: "duplicate", cursor: 0))
        publish(frame(state: "armed", text: unicode, cursor: unicode.unicodeScalars.count, revision: 2, acknowledgement: request.id, result: "accepted"))
        check("arming cannot masquerade as an accepted submission", bridge.pending != nil && commits == 0)
        publish(frame(state: "armed", text: unicode, cursor: unicode.unicodeScalars.count, revision: 3, acknowledgement: request.id, result: "armed"))
        bridge.poll()
        check("armed request forwards exactly one commit key", commits == 1)
        publish(frame(state: "busy", revision: 3, acknowledgement: request.id, result: "accepted"))
        check("running command releases pending handshake", bridge.pending == nil && bridge.completion?.1 == true)
        check("running program hides command editor", !input.expanded)
        check("accepted submission clears unsent draft", !bridge.hasDraft && input.textView.string.isEmpty)
        publish(frame(epoch: 2, revision: 4))
        check("new prompt restores native editor", input.expanded)
        publish(frame(text: "shell buffer", cursor: 12, epoch: 2, revision: 5))
        check("unsubmitted shell history participates in close confirmation", bridge.hasDraft)
        input.textView.setSelectedRange(NSRange(location: 2, length: 4))
        input.setInteractionLocked(true)
        input.submit()
        check("approved command editor refuses editing and submission", !input.textView.isEditable && bridge.pending == nil)
        input.setInteractionLocked(false)
        check("cancelled quit restores command selection and editing", input.textView.isEditable && input.textView.selectedRange() == NSRange(location: 2, length: 4))
        check("native editor rejects NUL insertion", !input.textView(input.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "\0"))
        check("native editor rejects oversized paste", !input.textView(input.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: String(repeating: "x", count: P.maximumBytes)))
        let nextInput = CommandInputView(bridge: bridge)
        check("each editor owns a distinct undo manager", input.undoManager(for: input.textView) !== nextInput.undoManager(for: nextInput.textView))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = nextInput
        window.makeFirstResponder(nextInput.textView)
        nextInput.textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                        replacementRange: NSRange(location: NSNotFound, length: 0))
        nextInput.submit()
        check("IME candidate confirmation does not submit", bridge.pending == nil && nextInput.textView.hasMarkedText())
        check("IME preedit participates in close confirmation", bridge.hasDraft)
        nextInput.textView.unmarkText()
        window.close()

        publish(frame(epoch: 3, revision: 5))
        check("stale prompt request starts", bridge.send(.submit, text: "old draft", cursor: 9))
        publish(frame(state: "busy", epoch: 3, revision: 6))
        check("prompt departure cancels request without commit key", bridge.pending == nil && commits == 1 && bridge.completion?.1 == false)
        publish(frame(epoch: 4, revision: 7, pid: 456))
        check("mailbox rejects a different shell PID", bridge.snapshot == nil)

        if let raceBridge = CommandInputBridge() {
            defer { raceBridge.close() }
            let raceFD = Darwin.open(raceBridge.directory.appendingPathComponent("notify").path, O_RDWR | O_NONBLOCK)
            defer { if raceFD >= 0 { Darwin.close(raceFD) } }
            func raceFrame(_ revision: Int, _ text: String) -> Data {
                P.encode(["BOOME1", raceBridge.token, "123", "race-generation", "1", String(revision),
                          "ready", text, "0", "main", "start", "", ""])!
            }
            let stateURL = raceBridge.directory.appendingPathComponent("state")
            try! raceFrame(1, "").write(to: stateURL, options: .atomic)
            raceBridge.poll()
            let raceInput = CommandInputView(bridge: raceBridge)
            raceInput.textView.string = "native draft"
            raceInput.textDidChange(Notification(name: NSText.didChangeNotification))
            // The shell changes after the view's guard but before send() polls.
            try! raceFrame(2, "shell changed").write(to: stateURL, options: .atomic)
            raceInput.submit()
            check("submission cannot silently rebase onto a changed shell snapshot",
                  raceBridge.pending == nil && !FileManager.default.fileExists(atPath: raceBridge.directory.appendingPathComponent("request").path))
            check("snapshot race preserves both native draft and shell text",
                  raceInput.textView.string == "native draft" && raceBridge.snapshot?.text == "shell changed")
        } else { check("snapshot race mailbox created", false) }
        bridge.close()
        check("closing a surface removes private mailbox", !FileManager.default.fileExists(atPath: bridge.directory.path))
    }
}
