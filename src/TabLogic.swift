import Foundation

/// Identity of one tab in the shell's list. The view and the surface stay
/// outside this value so the transitions can run without a window.
struct TabID: Hashable, Equatable {
    var raw: Int
}

/// New-tab directory. A non-empty path from the library wins; otherwise home.
enum TabDirectory {
    static func choose(inherited: String?, home: String) -> String {
        if let inherited {
            let trimmed = inherited.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return home
    }
}

/// One window's tab list. Closing the last tab inserts `replacement` and
/// leaves a list of one. Nothing here closes the window.
struct TabList: Equatable {
    var ids: [TabID]
    var selected: Int

    var selectedID: TabID? {
        guard ids.indices.contains(selected) else { return nil }
        return ids[selected]
    }

    mutating func append(_ id: TabID) {
        ids.append(id)
        selected = ids.count - 1
    }

    enum CloseEffect: Equatable {
        /// The visible tab is still the one that was selected.
        case removedNonSelected(visible: TabID)
        /// The selected tab is gone. `now` is the neighbor that replaced it.
        case removedSelected(now: TabID)
        /// The only tab was replaced. The window stays on `with`.
        case replacedLast(with: TabID)
    }

    mutating func close(_ id: TabID, replacement: TabID) -> CloseEffect? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        if ids.count == 1 {
            ids = [replacement]
            selected = 0
            return .replacedLast(with: replacement)
        }
        let visible = ids[selected]
        let closingSelected = index == selected
        ids.remove(at: index)
        if closingSelected {
            selected = min(index, ids.count - 1)
            return .removedSelected(now: ids[selected])
        }
        if index < selected {
            selected -= 1
        }
        return .removedNonSelected(visible: visible)
    }

    /// Tabs a "Close Other Tabs" action may ask to close. Does not remove them.
    func requestingCloseOthers(keeping index: Int) -> [TabID] {
        guard ids.indices.contains(index) else { return [] }
        return ids.enumerated().compactMap { offset, id in offset == index ? nil : id }
    }

    /// Tabs a "Close Tabs to the Right" action may ask to close. Does not remove them.
    func requestingCloseRight(of index: Int) -> [TabID] {
        guard ids.indices.contains(index) else { return [] }
        guard index + 1 < ids.count else { return [] }
        return Array(ids[(index + 1)...])
    }
}

/// Previous / next wrap. Last and a numbered tab clamp by refusing an index
/// outside the list. A landing is marked only when the selected row changes.
enum TabNavigation {
    enum Move: Equatable {
        case previous
        case next
        case last
        case index(Int)
    }

    struct Landing: Equatable {
        var index: Int
        var markKeyboardLanding: Bool
    }

    static func landing(count: Int, selected: Int, move: Move) -> Landing? {
        guard count > 0, selected >= 0, selected < count else { return nil }
        let next: Int
        switch move {
        case .previous:
            next = (selected - 1 + count) % count
        case .next:
            next = (selected + 1) % count
        case .last:
            next = count - 1
        case .index(let number):
            let index = number - 1
            guard index >= 0, index < count else { return nil }
            next = index
        }
        return Landing(index: next, markKeyboardLanding: next != selected)
    }
}

/// Which close a library action asks for. The tag is `ghostty_action_tag_e`
/// from the pinned v1.3.1 header. Close Window is not a tab close: the last
/// tab must not be replaced in its place.
enum LibraryActionRoute {
    enum Close: Equatable {
        case tab
        case window
    }

    static let closeTab: UInt32 = 3
    static let closeWindow: UInt32 = 49

    static func close(tag: UInt32) -> Close? {
        switch tag {
        case closeTab:
            return .tab
        case closeWindow:
            return .window
        default:
            return nil
        }
    }
}

/// One close prompt for the whole window. A second prompt is refused while
/// the first is unanswered. Cancel keeps the tabs. Confirm removes only the
/// tab that was asked about, or closes the window. A dead process is not a
/// prompt. While the window prompt is open, nothing is removed: Cancel has
/// to leave every shell.
///
/// A batch (close others, close to the right) waits until every requested
/// tab has reported. Nothing in that batch is removed early. One alive
/// process asks once for the whole batch. Confirm removes every requested
/// tab. Cancel removes none.
struct ClosePolicy {
    enum Subject: Equatable {
        case tab(TabID)
        case tabs([TabID])
        case window
    }

    private struct Batch {
        var waiting: Set<TabID>
        var order: [TabID]
        var alive: [TabID]
    }

    private(set) var pending: Subject?
    private var batch: Batch?

    var isPending: Bool { pending != nil }
    var isBusy: Bool { pending != nil || batch != nil }

    enum Report: Equatable {
        case destroy(TabID)
        case destroyBatch([TabID])
        case ask(Subject)
        case refused
        case closeWindowNow
        case hold
    }

    enum Resolution: Equatable {
        case destroy([TabID])
        case closeWindow
        case keep
        case none
    }

    /// Starts a batch. False when a prompt or another batch is already open.
    /// An empty list does not become busy.
    mutating func beginBatch(_ ids: [TabID]) -> Bool {
        if isBusy { return false }
        var seen = Set<TabID>()
        var order: [TabID] = []
        for id in ids where seen.insert(id).inserted {
            order.append(id)
        }
        guard !order.isEmpty else { return true }
        batch = Batch(waiting: Set(order), order: order, alive: [])
        return true
    }

    mutating func reportTab(_ id: TabID, alive: Bool) -> Report {
        if var batch {
            if batch.order.contains(id) {
                guard batch.waiting.contains(id) else { return .refused }
                batch.waiting.remove(id)
                if alive { batch.alive.append(id) }
                if !batch.waiting.isEmpty {
                    self.batch = batch
                    return .hold
                }
                let order = batch.order
                let anyAlive = !batch.alive.isEmpty
                self.batch = nil
                if anyAlive {
                    pending = .tabs(order)
                    return .ask(.tabs(order))
                }
                return .destroyBatch(order)
            }
            // A shell outside this batch can exit on its own. Dropping that
            // report would leave the dead tab after Cancel.
            if !alive { return .destroy(id) }
            return .refused
        }
        if case .tabs(let ids) = pending {
            if !alive && !ids.contains(id) { return .destroy(id) }
            return .refused
        }
        if alive {
            if pending != nil { return .refused }
            pending = .tab(id)
            return .ask(.tab(id))
        }
        if case .window = pending { return .refused }
        if case .tab(let waiting) = pending, waiting == id { return .refused }
        return .destroy(id)
    }

    mutating func reportWindow(live: [TabID]) -> Report {
        if pending != nil || batch != nil { return .refused }
        if live.isEmpty { return .closeWindowNow }
        pending = .window
        return .ask(.window)
    }

    mutating func resolve(confirmed: Bool) -> Resolution {
        guard let pending else { return .none }
        let subject = pending
        self.pending = nil
        guard confirmed else { return .keep }
        switch subject {
        case .tab(let id):
            return .destroy([id])
        case .tabs(let ids):
            return .destroy(ids)
        case .window:
            return .closeWindow
        }
    }
}

/// Layout remembered across launches. The window frame is saved by AppKit.
/// Tabs stay in the left sidebar. A missing collapsed value leaves it open.
enum ChromeMemory {
    static let collapsedKey = "BoomeSidebarCollapsed"
    static let frameAutosaveName = "BoomeMain"
    static var frameDefaultsKey: String { "NSWindow Frame \(frameAutosaveName)" }

    /// `setFrameAutosaveName` succeeds when it registers the name, even when
    /// nothing was saved yet. A frame string is the record that can be restored.
    static func hasSavedFrame(_ saved: String?) -> Bool {
        guard let saved else { return false }
        return !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Horizontal tabs used to stay on screen even when the collapse bit was
    /// set. Dropping that layout opens the sidebar, so the same list remains visible.
    static func sidebarCollapsed(stored: Bool?, obsoletePlacement: String?) -> Bool {
        if obsoletePlacement == "horizontal" { return false }
        return stored ?? false
    }
}

/// The row flash after a keyboard landing. Reduced motion skips it.
enum SelectionPulse {
    static func plays(marked: Bool, reduceMotion: Bool) -> Bool {
        marked && !reduceMotion
    }
}

/// Close mark only on the row the pointer is on, or the row that is selected.
enum TabChrome {
    static func showsClose(selected: Bool, hovered: Bool) -> Bool {
        selected || hovered
    }
}

/// Shortcuts the shell keeps. Anything else may go to the visible surface.
enum AppShortcut {
    struct Chord: Equatable {
        var command: Bool
        var option: Bool
        var shift: Bool
        var control: Bool
        var key: String
        var keyCode: UInt16
    }

    static func owns(_ chord: Chord) -> Bool {
        let key = chord.key.lowercased()
        let commandOnly = chord.command && !chord.option && !chord.shift && !chord.control
        let commandOption = chord.command && chord.option && !chord.shift && !chord.control
        let commandShift = chord.command && !chord.option && chord.shift && !chord.control
        if commandOnly && (key == "t" || key == "w" || key == "q" || key == "s") { return true }
        if commandOption && (key == "s" || key == "e") { return true }
        if commandShift && (key == "[" || key == "]") { return true }
        if chord.control && chord.keyCode == 48 { return true }
        return false
    }
}

/// Sidebar drawing of one tab. The window title stays the full string.
/// A `user@host:path` title is split so the path is the line you scan;
/// tail truncation in a 200-point column was hiding it.
struct TabPresentation: Equatable {
    var primary: String
    var secondary: String?
    var accessibility: String

    static func rowHeight(hasSecondary: Bool) -> CGFloat {
        hasSecondary ? 46 : 34
    }

    static func make(label: String, customTitle: Bool) -> TabPresentation {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if customTitle {
            return TabPresentation(primary: label, secondary: nil, accessibility: label)
        }
        if let split = splitShellTitle(trimmed) ?? splitPath(trimmed) {
            return split
        }
        return TabPresentation(primary: label, secondary: nil, accessibility: label)
    }

    /// Rows that still draw the same two lines get a quiet second line:
    /// the parent path segment that differs, or an ordinal when nothing else does.
    static func disambiguate(_ rows: [TabPresentation]) -> [TabPresentation] {
        var groups: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            let key = row.primary + "\u{1e}" + (row.secondary ?? "")
            groups[key, default: []].append(index)
        }
        var result = rows
        for indices in groups.values where indices.count > 1 {
            let paths = indices.map { path(from: rows[$0].accessibility) }
            let marks = distinguishingParents(paths) ?? indices.indices.map { String($0 + 1) }
            for (offset, index) in indices.enumerated() {
                let mark = marks[offset]
                let existing = rows[index].secondary
                result[index].secondary = merge(existing: existing, mark: mark)
                if !rows[index].accessibility.contains(mark) {
                    result[index].accessibility = rows[index].accessibility + " · " + mark
                }
            }
        }
        return result
    }

    /// A title that is only a path still hides its last component when the
    /// line is tail-truncated. The parent stays on the second line when it
    /// is more than `/` or `~`.
    private static func splitPath(_ title: String) -> TabPresentation? {
        guard title.hasPrefix("/") || title.hasPrefix("~") else { return nil }
        let name = directoryName(title)
        guard !name.isEmpty, name != title else { return nil }
        return TabPresentation(primary: name, secondary: meaningfulParent(title), accessibility: title)
    }

    private static func splitShellTitle(_ title: String) -> TabPresentation? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@") else { return nil }
        let afterAt = trimmed.index(after: at)
        guard afterAt < trimmed.endIndex,
              let colon = trimmed[afterAt...].firstIndex(of: ":") else { return nil }
        let userHost = String(trimmed[..<colon])
        let path = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let name = directoryName(path)
        guard !userHost.isEmpty, !name.isEmpty else { return nil }
        let secondary = isLocal(userHost) ? meaningfulParent(path) : userHost
        return TabPresentation(primary: name, secondary: secondary, accessibility: trimmed)
    }

    /// The local host is on every tab, so it does not earn a second line.
    private static func isLocal(_ userHost: String) -> Bool {
        guard let at = userHost.lastIndex(of: "@") else { return false }
        let host = String(userHost[userHost.index(after: at)...]).lowercased()
        if localNames.contains(host) { return true }
        if let dot = host.firstIndex(of: "."), localNames.contains(String(host[..<dot])) {
            return true
        }
        return false
    }

    private static let localNames: Set<String> = {
        var names: Set<String> = ["localhost"]
        let full = ProcessInfo.processInfo.hostName.lowercased()
        names.insert(full)
        if let dot = full.firstIndex(of: ".") {
            names.insert(String(full[..<dot]))
        }
        if let localized = Host.current().localizedName?.lowercased() {
            names.insert(localized)
            names.insert(localized.replacingOccurrences(of: " ", with: "-"))
        }
        return names
    }()

    private static func meaningfulParent(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "/" || parent == "~" || parent == "." || parent == path {
            return nil
        }
        return parent
    }

    private static func path(from label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.firstIndex(of: "@") {
            let after = trimmed.index(after: at)
            if after < trimmed.endIndex, let colon = trimmed[after...].firstIndex(of: ":") {
                let path = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return path }
            }
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return trimmed }
        return nil
    }

    private static func distinguishingParents(_ paths: [String?]) -> [String]? {
        let concrete = paths.compactMap { $0 }
        guard concrete.count == paths.count else { return nil }
        let parents = concrete.map { parentComponents($0) }
        guard let first = parents.first, !parents.allSatisfy({ $0 == first }) else { return nil }
        let longest = parents.map(\.count).max() ?? 0
        var take = 1
        while take <= max(longest, 1) {
            let marks = parents.map { suffix($0, take) }
            if Set(marks).count == marks.count { return marks }
            take += 1
        }
        return parents.map { suffix($0, longest) }
    }

    private static func parentComponents(_ path: String) -> [String] {
        var text = path
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        let pieces = text.split(separator: "/").map(String.init)
        if pieces.count <= 1 { return [] }
        return Array(pieces.dropLast())
    }

    private static func suffix(_ parts: [String], _ count: Int) -> String {
        if parts.isEmpty { return "/" }
        let start = max(0, parts.count - count)
        return parts[start...].joined(separator: "/")
    }

    private static func merge(existing: String?, mark: String) -> String {
        guard let existing, !existing.isEmpty else { return mark }
        if existing == mark || existing.hasSuffix(" · " + mark) { return existing }
        return existing + " · " + mark
    }

    private static func directoryName(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path == "~" || path == "~/" { return "~" }
        if path == "/" { return "/" }
        let name = (path as NSString).lastPathComponent
        if name.isEmpty || name == "/" { return "~" }
        return name
    }
}
