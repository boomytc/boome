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
        app.setActivationPolicy(.prohibited)
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
        let info = ghostty_info()
        try check("runtime loads the owned terminal core", String(decoding: UnsafeRawBufferPointer(start: info.version, count: Int(info.version_len)), as: UTF8.self) == "1.3.1-boome.1")
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
