import CoreServices
import Foundation

/// Reads one git total per worktree off the main thread and refreshes it when
/// the worktree changes. Tabs in the same repository share that total.
final class GitChangeMonitor {
    var onUpdate: (() -> Void)?

    private let worker = DispatchQueue(label: "com.boom.boome.git-changes", qos: .utility)
    private let events = DispatchQueue(label: "com.boom.boome.git-events", qos: .utility)
    private var statuses: [String: GitWorktreeStatus] = [:]
    private var roots: [String: String] = [:]
    private var missedRepoAt: [String: Date] = [:]
    private var pending: Set<String> = []
    private var wanted: Set<String> = []
    private var watches: [String: RepoWatch] = [:]
    private var refreshWork: [String: DispatchWorkItem] = [:]
    private var refreshGeneration: [String: Int] = [:]

    deinit {
        let ending = Array(watches.values)
        watches.removeAll()
        events.sync {
            for watch in ending { watch.stop() }
        }
    }

    func status(forWorkingDirectory path: String?) -> GitWorktreeStatus? {
        guard let directory = Self.directory(path) else { return nil }
        guard let root = roots[directory] else { return nil }
        return statuses[root]
    }

    func note(directories: [String?]) {
        wanted = Set(directories.compactMap(Self.directory))
        for directory in wanted {
            if let root = roots[directory] {
                watch(root)
            } else {
                schedule(directory)
            }
        }
        pruneWatches()
    }

    private func schedule(_ directory: String) {
        if roots[directory] != nil || pending.contains(directory) { return }
        if let when = missedRepoAt[directory], Date().timeIntervalSince(when) < 8 { return }
        pending.insert(directory)
        worker.async { [weak self] in
            let loaded = GitChangeQuery.load(workingDirectory: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(directory)
                guard self.wanted.contains(directory) else { return }
                guard let loaded else {
                    self.missedRepoAt[directory] = Date()
                    return
                }
                self.missedRepoAt[directory] = nil
                let changed = self.roots[directory] != loaded.root || self.statuses[loaded.root] != loaded.status
                self.roots[directory] = loaded.root
                self.roots[loaded.root] = loaded.root
                self.statuses[loaded.root] = loaded.status
                self.watch(loaded.root)
                if changed { self.onUpdate?() }
            }
        }
    }

    private func watch(_ root: String) {
        guard watches[root] == nil else { return }
        let watch = RepoWatch(root: root) { [weak self] in
            self?.scheduleRefresh(root)
        }
        watch.start(queue: events)
        watches[root] = watch
    }

    private func pruneWatches() {
        let live = Set(wanted.compactMap { roots[$0] })
        for root in watches.keys where !live.contains(root) {
            refreshGeneration[root, default: 0] += 1
            refreshWork[root]?.cancel()
            refreshWork[root] = nil
            let watch = watches.removeValue(forKey: root)
            events.sync { watch?.stop() }
        }
    }

    private func scheduleRefresh(_ root: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.watches[root] != nil else { return }
            self.refreshWork[root]?.cancel()
            let generation = (self.refreshGeneration[root] ?? 0) + 1
            self.refreshGeneration[root] = generation
            let work = DispatchWorkItem { [weak self] in
                let loaded = GitChangeQuery.load(workingDirectory: root)
                DispatchQueue.main.async {
                    guard let self, self.watches[root] != nil, self.refreshGeneration[root] == generation else { return }
                    self.refreshWork[root] = nil
                    guard let loaded else { return }
                    self.roots[loaded.root] = loaded.root
                    guard self.statuses[loaded.root] != loaded.status else { return }
                    self.statuses[loaded.root] = loaded.status
                    self.onUpdate?()
                }
            }
            self.refreshWork[root] = work
            self.worker.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    private static func directory(_ path: String?) -> String? {
        guard var path else { return nil }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return nil }
        if path == "~" || path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            path = path == "~" ? home : home + path.dropFirst(1)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}

private final class RepoWatch {
    let root: String
    let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(root: String, onChange: @escaping () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    func start(queue: DispatchQueue) {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let created = FSEventStreamCreate(
            nil,
            repoWatchCallback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func receive(paths: [String]) {
        let git = root + "/.git"
        let relevant = paths.isEmpty || paths.contains { path in
            path != git && !path.hasPrefix(git + "/")
        }
        if relevant { onChange() }
    }

    deinit { stop() }
}

private func repoWatchCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watch = Unmanaged<RepoWatch>.fromOpaque(info).takeUnretainedValue()
    let listed = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let count = min(numEvents, CFArrayGetCount(listed))
    var paths: [String] = []
    paths.reserveCapacity(count)
    for index in 0..<count {
        guard let value = CFArrayGetValueAtIndex(listed, index) else { continue }
        let text = Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        paths.append(text)
    }
    watch.receive(paths: paths)
}
