import AppKit

/// Owns windows, routes surface callbacks by identity, and commits live-session transfers.
final class SessionWindowManager: GhosttyHostDelegate {
    private(set) var controllers: [MainWindowController] = []
    private(set) var isPreparingTermination = false
    private var drag: ActiveDrag?
    private var escapeMonitor: Any?

    private final class ActiveDrag {
        let token = UUID().uuidString
        let source: MainWindowController
        let item: SessionDragItem
        let ids: [TabID]
        var completed = false
        var cancelled = false
        init(source: MainWindowController, item: SessionDragItem) {
            self.source = source
            self.item = item
            ids = source.arrangement.ids(for: item)
        }
    }

    var activeWindow: MainWindowController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let controller = controllers.first(where: { $0.window === window || $0.window === window.sheetParent }) { return controller }
        }
        return NSApp.orderedWindows.compactMap { window in controllers.first { $0.window === window } }.first
    }

    @discardableResult
    func newWindow(restoreFrame: Bool = false, empty: Bool = false) -> MainWindowController? {
        guard !isPreparingTermination else { return nil }
        let controller = MainWindowController(workspace: self, initialTab: !empty, restoreFrame: restoreFrame)
        controllers.append(controller)
        if !empty { controller.show() }
        return controller
    }

    func didClose(_ controller: MainWindowController) {
        let remembered = controller.window?.frameAutosaveName == ChromeMemory.frameAutosaveName
        if remembered { controller.window?.setFrameAutosaveName("") }
        controllers.removeAll { $0 === controller }
        if remembered { (activeWindow ?? controllers.first)?.rememberWindowFrame() }
    }

    private func owner(of surface: GhosttyHost.Surface?) -> MainWindowController? {
        guard let surface else { return activeWindow }
        return controllers.first { $0.contains(surface: surface) }
    }

    func beginDrag(_ item: SessionDragItem, from source: MainWindowController) -> String? {
        guard drag == nil, !isPreparingTermination, source.canMoveSessions, !source.arrangement.ids(for: item).isEmpty else { return nil }
        let current = ActiveDrag(source: source, item: item)
        drag = current
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak current] event in
            if event.keyCode == 53 { current?.cancelled = true }
            return event
        }
        return current.token
    }

    func dragItem(for token: String) -> SessionDragItem? {
        guard let drag, drag.token == token, !drag.completed, !drag.cancelled,
              drag.ids == drag.source.arrangement.ids(for: drag.item) else { return nil }
        return drag.item
    }

    func canDrop(_ token: String, into destination: MainWindowController, at target: SessionDropTarget, background: Bool = false) -> Bool {
        guard let drag, dragItem(for: token) != nil, !background || drag.source !== destination else { return false }
        return plan(drag.item, from: drag.source, to: destination, at: target) != nil
    }

    func drop(_ token: String, into destination: MainWindowController, at target: SessionDropTarget) -> Bool {
        guard let drag, dragItem(for: token) != nil else { return false }
        guard transfer(drag.item, from: drag.source, to: destination, at: target) else { return false }
        drag.completed = true
        return true
    }

    func endDrag(_ token: String, at point: NSPoint, operation: NSDragOperation) {
        guard let current = drag, current.token == token else { return }
        defer {
            drag = nil
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        }
        guard !current.completed, !current.cancelled, operation.isEmpty,
              NSEvent.pressedMouseButtons & 1 == 0,
              current.ids == current.source.arrangement.ids(for: current.item) else { return }
        // A refused drop inside a busy/source window is cancellation, not a tear-off.
        guard !controllers.contains(where: { $0.window.map { $0.isVisible && $0.frame.contains(point) } == true }) else { return }
        moveToNewWindow(current.item, from: current.source, at: point)
    }

    private func plan(_ item: SessionDragItem, from source: MainWindowController, to destination: MainWindowController,
                      at target: SessionDropTarget) -> SessionArrangement.Transfer? {
        guard !isPreparingTermination, source.canMoveSessions, destination.canMoveSessions,
              controllers.contains(where: { $0 === source }), controllers.contains(where: { $0 === destination }) else { return nil }
        guard let plan = SessionArrangement.transfer(item, from: source.arrangement, to: destination.arrangement,
                                                     at: target, sameWindow: source === destination) else { return nil }
        if source === destination, plan.destination == source.arrangement { return nil }
        return plan
    }

    @discardableResult
    func transfer(_ item: SessionDragItem, from source: MainWindowController, to destination: MainWindowController,
                  at target: SessionDropTarget = .end) -> Bool {
        guard let plan = plan(item, from: source, to: destination, at: target) else { return false }
        let selected = source.selectedTabID
        if source === destination {
            source.applyArrangement(plan.destination, adding: [], selecting: selected, focus: false)
        } else {
            let moved = source.tabs(with: Set(plan.movedIDs))
            let remainingSelection = SessionArrangement.selection(afterRemoving: Set(plan.movedIDs), from: source.arrangement.ids, selected: selected)
            source.applyArrangement(plan.source, adding: [], selecting: remainingSelection, focus: false)
            let landing = selected.flatMap { plan.movedIDs.contains($0) ? $0 : nil } ?? plan.movedIDs.first
            destination.applyArrangement(plan.destination, adding: moved, selecting: landing, focus: true)
            destination.showAfterTransfer()
            source.finishTransferOut()
        }
        return true
    }

    func moveToNewWindow(_ item: SessionDragItem, from source: MainWindowController, at point: NSPoint? = nil) {
        guard source.canMoveSessions, !isPreparingTermination, !source.arrangement.ids(for: item).isEmpty else { return }
        // A single-session window already is the detached result; do not replace its editor.
        if source.arrangement.ids(for: item).count == source.arrangement.items.count, controllers.contains(where: { $0 === source }) {
            source.position(at: point)
            source.showAfterTransfer()
            return
        }
        guard let destination = newWindow(empty: true) else { return }
        destination.position(at: point, relativeTo: source.window)
        if !transfer(item, from: source, to: destination) { destination.closeEmptyWindow() }
    }

    func prepareToTerminate(_ completion: @escaping (Bool) -> Void) -> Bool {
        guard !isPreparingTermination, drag == nil, controllers.allSatisfy(\.canMoveSessions) else { return false }
        isPreparingTermination = true
        let pending = controllers
        func finish(_ allowed: Bool) {
            if !allowed { for controller in controllers { controller.resetTerminationApproval() } }
            DispatchQueue.main.async {
                self.isPreparingTermination = false
                completion(allowed)
            }
        }
        func next(_ index: Int) {
            guard index < pending.count else { finish(true); return }
            let controller = pending[index]
            if !controllers.contains(where: { $0 === controller }) { next(index + 1); return }
            controller.requestQuit { allowed in
                if allowed { next(index + 1) } else { finish(false) }
            }
        }
        next(0)
        return true
    }

    func ghosttyHostOpenNewTab(_ host: GhosttyHost, from surface: GhosttyHost.Surface?) {
        if let controller = owner(of: surface) { controller.newTab() }
        else { newWindow() }
    }
    func ghosttyHostOpenNewWindow(_ host: GhosttyHost) { newWindow() }
    func ghosttyHostCloseCurrentTab(_ host: GhosttyHost, from surface: GhosttyHost.Surface?) {
        if let surface { owner(of: surface)?.close(surface: surface) }
        else { activeWindow?.closeCurrentTab() }
    }
    func ghosttyHostCloseWindow(_ host: GhosttyHost, from surface: GhosttyHost.Surface?) { owner(of: surface)?.window?.performClose(nil) }
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface?, cycle: GhosttyHost.Cycle) { owner(of: surface)?.cycle(cycle) }
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setTitle title: String) { owner(of: surface)?.ghosttyHost(host, surface: surface, setTitle: title) }
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setTabTitle title: String) { owner(of: surface)?.ghosttyHost(host, surface: surface, setTabTitle: title) }
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setWorkingDirectory path: String) { owner(of: surface)?.ghosttyHost(host, surface: surface, setWorkingDirectory: path) }
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, closeProcessAlive alive: Bool) { owner(of: surface)?.ghosttyHost(host, surface: surface, closeProcessAlive: alive) }
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursor: GhosttyHost.CursorStyle) { owner(of: surface)?.ghosttyHost(host, surface: surface, cursor: cursor) }
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursorHidden hidden: Bool) { owner(of: surface)?.ghosttyHost(host, surface: surface, cursorHidden: hidden) }
}
