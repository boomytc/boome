import AppKit
import GhosttyKit

func descendants<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
}
func wait(_ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    return predicate()
}
private enum RuntimeFailure: Error { case check(String) }
private var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) throws {
    guard condition() else { throw RuntimeFailure.check(name) }
    checks += 1
    print("PASS \(name)"); fflush(stdout)
}
@main enum CoreRuntimeTests {
    static func main() {
        do { try run() }
        catch { fputs("FAIL runtime integration: \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        let app = NSApplication.shared
        let uiSmoke = ProcessInfo.processInfo.environment["BOOME_INPUT_UI_SMOKE"] == "1"
        app.setActivationPolicy(uiSmoke ? .regular : .prohibited)
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &displayCount) == .success, displayCount > 0 else {
            throw RuntimeFailure.check("runtime checks require an active display; wake the display and retry")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boome core runtime.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        defer { if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) } }
        let host = GhosttyHost.shared
        let workspace = SessionWindowManager()
        host.delegate = workspace
        host.start()
        defer {
            for controller in workspace.controllers { controller.window?.close() }
            host.shutdown()
        }
        if ProcessInfo.processInfo.environment["BOOME_INPUT_FALLBACK_SMOKE"] == "1" {
            let controller = workspace.newWindow(empty: true)!
            controller.window?.alphaValue = 0
            controller.newTab()
            let tab = controller.tabs(with: Set(controller.arrangement.ids))[0]
            let output = root.appendingPathComponent("fallback.txt")
            try check("fallback shell accepts ordinary terminal input", host.performBinding(tab.view.surface, "text:printf 'fallback' > '" + output.path + "'\\r"))
            try check("fallback shell executes without native takeover", wait { (try? String(contentsOf: output)) == "fallback" })
            try check("unsupported shell retains the full terminal", tab.view.surface.commandInput?.snapshot == nil && tab.content.input?.preferredHeight == 0)
            print("OK unsupported-shell fallback checks"); fflush(stdout)
            return
        }
        if uiSmoke {
            try CommandInputUITests.run(workspace: workspace, root: root)
            return
        }
        let info = ghostty_info()
        try check("runtime loads the owned terminal core", String(decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)), as: UTF8.self) == "1.3.1-boome.2")
        try check("runtime core is compiled in ReleaseFast", info.build_mode == GHOSTTY_BUILD_MODE_RELEASE_FAST)
        let aFile = root.appendingPathComponent("A.txt")
        let bFile = root.appendingPathComponent("B.txt")
        try "original A\n".write(to: aFile, atomically: true, encoding: .utf8)
        try "original B\n".write(to: bFile, atomically: true, encoding: .utf8)
        let source = workspace.newWindow(empty: true)!
        source.window?.alphaValue = 0
        source.newTab(); source.newTab()
        let ids = source.arrangement.ids
        try check("two live source sessions", ids.count == 2)
        let a = source.tabs(with: [ids[0]])[0]
        let b = source.tabs(with: [ids[1]])[0]
        try check("both shells become ready", wait { !a.terminalTitle.isEmpty && !b.terminalTitle.isEmpty })
        let originalSurface = a.view.surface!
        let commandInput = a.content.input!
        try check("zsh command-input handshake completes", wait { originalSurface.commandInput?.snapshot?.isReady == true })
        try check("supported shell exposes native command editing", commandInput.expanded)
        let nativeOutput = root.appendingPathComponent("native.txt")
        commandInput.textView.string = "NATIVE_VALUE='中文👩‍💻'; printf '%s:%s' \"$NATIVE_VALUE\" $$ > '" + nativeOutput.path + "'"
        commandInput.textDidChange(Notification(name: NSText.didChangeNotification))
        commandInput.submit()
        try check("native submission executes through the original shell", wait { FileManager.default.fileExists(atPath: nativeOutput.path) && originalSurface.commandInput?.pending == nil })
        try check("native command preserves Unicode and shell PID", (try? String(contentsOf: nativeOutput)) == "中文👩‍💻:" + String(originalSurface.commandInput!.snapshot!.pid))
        try check("native prompt returns after submission", wait { commandInput.expanded && originalSurface.commandInput?.snapshot?.isReady == true })
        commandInput.textView.string = "read -r BOOME_REPLY; printf '%s' \"$BOOME_REPLY\" > '" + root.appendingPathComponent("reply.txt").path + "'"
        commandInput.textDidChange(Notification(name: NSText.didChangeNotification))
        commandInput.submit()
        let released = wait { originalSurface.commandInput?.snapshot?.state == "busy" && originalSurface.commandInput?.pending == nil && !commandInput.expanded }
        if !released { print("Submission state:", String(describing: originalSurface.commandInput?.snapshot), "pending:", String(describing: originalSurface.commandInput?.pending?.action), "error:", String(describing: originalSurface.commandInput?.error), "draft:", commandInput.textView.string) }
        try check("running program releases native input and handshake", released)
        try check("program still receives ordinary terminal input", host.performBinding(originalSurface, "text:reply-from-program\\r"))
        try check("interactive input is not intercepted by command editor", wait { (try? String(contentsOf: root.appendingPathComponent("reply.txt"))) == "reply-from-program" })
        try check("command editor restores after program returns", wait { commandInput.expanded })
        func shell(_ text: String) throws {
            try check("terminal text binding accepted", host.performBinding(originalSurface, "text:" + text + "\\r"))
        }
        try shell("BOOME_PROBE=state-kept; echo \"$BOOME_PROBE:$$\" > '" + root.appendingPathComponent("before.txt").path + "'")
        try check("original shell responds", wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("before.txt").path) })
        let before = try String(contentsOf: root.appendingPathComponent("before.txt"))
        let editor = descendants(source.window!.contentView!, FileEditorView.self)[0]
        let text = descendants(editor, NSTextView.self)[0]
        editor.open(aFile)
        try check("source editor opens", wait { editor.document != nil && !editor.isBusy })
        text.string = "unsaved source buffer\n"; editor.textDidChange(Notification(name: NSText.didChangeNotification))
        source.window!.makeFirstResponder(text)
        try check("native input reaches current prompt before drafting", wait { originalSurface.commandInput?.snapshot?.isReady == true })
        commandInput.textView.insertText("printf 'draft 中👩‍💻'", replacementRange: NSRange(location: 0, length: (commandInput.textView.string as NSString).length))
        commandInput.textDidChange(Notification(name: NSText.didChangeNotification))
        commandInput.textView.setSelectedRange(NSRange(location: 7, length: 5))
        let draft = commandInput.textView.string
        let draftSelection = commandInput.textView.selectedRange()
        let draftUndo = commandInput.textView.undoManager
        let target = workspace.newWindow(empty: true)!
        target.window?.alphaValue = 0
        target.newTab()
        func drag(_ id: TabID) throws {
            let token = workspace.beginDrag(.tab(id), from: source)
            try check("continuous drag obtains fresh identity", token != nil)
            try check("drop transaction accepts destination", workspace.drop(token!, into: target, at: .end))
            workspace.endDrag(token!, at: .zero, operation: .move)
        }
        try drag(ids[1])
        try check("moving another session preserves native editor focus", editor.isFocused && text.string == "unsaved source buffer\n")
        try drag(ids[0])
        try check("last-session transfer leaves editor-only source", source.arrangement.ids.isEmpty && workspace.controllers.contains { $0 === source })
        try check("transfer keeps surface identity", target.tabs(with: [ids[0]]).first?.view === a.view && a.view.surface === originalSurface)
        try check("command draft moves with its session", a.content.input === commandInput && commandInput.textView.string == draft)
        try check("command selection and undo manager survive transfer", commandInput.textView.selectedRange() == draftSelection && commandInput.textView.undoManager === draftUndo)
        commandInput.textView.string = ""
        commandInput.textDidChange(Notification(name: NSText.didChangeNotification))
        try check("clearing draft releases close confirmation", !originalSurface.commandInput!.hasDraft)
        try check("unsaved source remains independent", text.string == "unsaved source buffer\n" && editor.hasUnsavedChanges)
        try shell("echo \"$BOOME_PROBE:$$\" > '" + root.appendingPathComponent("after.txt").path + "'")
        try check("transferred shell keeps PID and local variable", wait { (try? String(contentsOf: root.appendingPathComponent("after.txt"))) == before })
        var saved = false
        editor.save { saved = $0 }
        try check("source buffer can save after last session moved", wait { saved && !editor.hasUnsavedChanges })
        try check("source writes its own buffer", (try? String(contentsOf: aFile)) == "unsaved source buffer\n")
        let targetEditor = descendants(target.window!.contentView!, FileEditorView.self)[0]
        let targetText = descendants(targetEditor, NSTextView.self)[0]
        targetEditor.open(bFile)
        try check("destination editor opens independently", wait { targetEditor.document != nil && !targetEditor.isBusy })
        targetText.string = "pending destination edits\n"; targetEditor.textDidChange(Notification(name: NSText.didChangeNotification))
        var result: Bool?
        try check("multiwindow termination starts", workspace.prepareToTerminate { result = $0 })
        try check("termination locks earlier-approved editor before later sheet", wait { !text.isEditable && target.window?.attachedSheet != nil })
        try check("approved window refuses content focus", !source.window!.makeFirstResponder(text))
        source.newTab()
        try check("approved window refuses new work", source.arrangement.ids.isEmpty)
        let sheet = target.window!.attachedSheet!
        target.window!.endSheet(sheet, returnCode: .alertThirdButtonReturn)
        try check("later cancel reaches global completion", wait { result == false && !workspace.isPreparingTermination })
        try check("cancel restores all windows and editing", workspace.controllers.count == 2 && text.isEditable && targetText.isEditable && source.canMoveSessions && target.canMoveSessions)
        try check("cancel restores original editor focus", editor.isFocused)
        try check("cancel keeps destination unsaved buffer", targetEditor.hasUnsavedChanges && targetText.string == "pending destination edits\n")
        result = nil
        try check("termination can restart after cancellation", workspace.prepareToTerminate { result = $0 })
        try check("second termination still asks about unsaved edits", wait { target.window?.attachedSheet != nil })
        target.window!.endSheet(target.window!.attachedSheet!, returnCode: .alertFirstButtonReturn)
        try check("save finishes multiwindow approval", wait { result == true })
        try check("approved quit saves destination contents", (try? String(contentsOf: bFile)) == "pending destination edits\n")
        for controller in workspace.controllers { controller.resetTerminationApproval() }
        print("OK \(checks) runtime integration checks"); fflush(stdout)
    }
}
