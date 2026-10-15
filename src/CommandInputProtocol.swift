import Foundation
import Darwin

enum CommandInputProtocol {
    static let maximumBytes = 1_048_576

    static func encode(_ fields: [String]) -> Data? {
        guard fields.allSatisfy({ !$0.contains("\0") }) else { return nil }
        let data = Data((fields.joined(separator: "\0") + "\0").utf8)
        return data.count <= maximumBytes ? data : nil
    }

    static func decode(_ data: Data, count: Int) -> [String]? {
        guard data.count <= maximumBytes, data.last == 0,
              let string = String(data: data, encoding: .utf8) else { return nil }
        var fields = string.components(separatedBy: "\0")
        fields.removeLast()
        return fields.count == count ? fields : nil
    }

    struct Identity: Equatable {
        let generation: String
        let epoch: Int
        let revision: Int
    }

    struct Snapshot: Equatable {
        let identity: Identity
        let pid: Int32
        let state: String
        let text: String
        let cursor: Int
        let keymap: String
        let context: String
        let acknowledgement: String
        let result: String
        var isReady: Bool {
            state == "ready" && ["main", "emacs", "viins"].contains(keymap)
                && ["start", "cont"].contains(context)
        }

        init?(data: Data, token: String) {
            guard let f = CommandInputProtocol.decode(data, count: 13),
                  f[0] == "BOOME1", f[1] == token, let pid = Int32(f[2]), pid > 0,
                  !f[3].isEmpty, let epoch = Int(f[4]), epoch > 0,
                  let revision = Int(f[5]), revision > 0,
                  ["ready", "armed", "busy", "unsupported"].contains(f[6]),
                  let cursor = Int(f[8]), cursor >= 0, cursor <= f[7].unicodeScalars.count,
                  ["", "armed", "accepted", "rejected"].contains(f[12]) else { return nil }
            identity = Identity(generation: f[3], epoch: epoch, revision: revision)
            self.pid = pid; state = f[6]; text = f[7]; self.cursor = cursor
            keymap = f[9]; context = f[10]; acknowledgement = f[11]; result = f[12]
        }
    }

    enum Action: String {
        case submit, terminal, complete, search, previous, next, cancel
        var requiresCommit: Bool { self == .submit || self == .complete || self == .search }
    }

    struct Request {
        let id: String
        let action: Action
        let identity: Identity
        let deadline: Date
        let data: Data
        var commitKey: String { "\u{1B}[99;\(id)~" }

        init?(snapshot: Snapshot, token: String, action: Action, text: String, cursor: Int, now: Date = Date()) {
            guard snapshot.isReady, cursor >= 0, cursor <= text.unicodeScalars.count else { return nil }
            id = UUID().uuidString; self.action = action; identity = snapshot.identity
            deadline = now.addingTimeInterval(4)
            guard let data = CommandInputProtocol.encode([
                "BOOME1", token, identity.generation, String(identity.epoch), String(identity.revision),
                id, action.rawValue, String(Int(deadline.timeIntervalSince1970)), text, String(cursor),
            ]) else { return nil }
            self.data = data
        }
    }

    static func utf16Offset(in text: String, scalarOffset: Int) -> Int {
        let scalars = text.unicodeScalars
        let index = scalars.index(scalars.startIndex, offsetBy: min(max(0, scalarOffset), scalars.count))
        return index.utf16Offset(in: text)
    }

    static func scalarOffset(in text: String, utf16Offset: Int) -> Int {
        let clamped = min(max(0, utf16Offset), text.utf16.count)
        var units = 0
        var result = 0
        for scalar in text.unicodeScalars {
            let length = scalar.value > 0xFFFF ? 2 : 1
            if units + length > clamped { break }
            units += length; result += 1
        }
        return result
    }
}

/// Per-surface mailbox. Text stays out of the PTY; only an armed ZLE commit key is forwarded.
final class CommandInputBridge {
    let directory: URL
    let token = UUID().uuidString
    var onChange: (() -> Void)?
    var onCommit: ((String) -> Bool)?
    var draftIsPresent: (() -> Bool)?
    var hasDraft: Bool { draftIsPresent?() ?? false }
    private(set) var snapshot: CommandInputProtocol.Snapshot?
    private(set) var pending: CommandInputProtocol.Request?
    private(set) var completion: (CommandInputProtocol.Request, Bool)?
    private(set) var error: String?
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var lastData: Data?
    private var closed = false
    private var committed = false
    private var cancelling = false
    private var shellPID: Int32?

    init?() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("boome-input-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(token.utf8).write(to: directory.appendingPathComponent("token"), options: .atomic)
            guard mkfifo(directory.appendingPathComponent("notify").path, 0o600) == 0 else { throw POSIXError(.EIO) }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    func start() {
        guard !closed, timer == nil else { return }
        // Watch the directory because shell snapshots are replaced atomically.
        // The timer remains a timeout/failure fallback, not the normal input path.
        let fd = Darwin.open(directory.path, O_EVTONLY | O_NOFOLLOW)
        if fd >= 0 {
            let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            watcher.setEventHandler { [weak self] in self?.poll() }
            watcher.setCancelHandler { Darwin.close(fd) }
            self.watcher = watcher
            watcher.resume()
        }
        let timer = Timer(timeInterval: fd >= 0 ? 0.25 : 0.08, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.invalidate(); timer = nil
        watcher?.cancel(); watcher = nil
        onChange = nil; onCommit = nil; draftIsPresent = nil; pending = nil; snapshot = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func clearError() { error = nil }

    private func readState() -> Data? {
        let fd = Darwin.open(directory.appendingPathComponent("state").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink <= 1,
              info.st_size >= 0, info.st_size <= CommandInputProtocol.maximumBytes else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count == data.count ? data : nil
    }

    func poll(now: Date = Date()) {
        guard !closed else { return }
        var changed = false
        let data = readState()
        if data != lastData {
            lastData = data
            snapshot = data.flatMap { CommandInputProtocol.Snapshot(data: $0, token: token) }
            if let incoming = snapshot {
                if let shellPID, shellPID != incoming.pid { snapshot = nil }
                else { shellPID = incoming.pid }
            }
            changed = true
        }
        if let request = pending {
            if let snapshot, snapshot.acknowledgement == request.id {
                if (snapshot.result == "accepted" && snapshot.state != "armed") || snapshot.result == "rejected" {
                    completion = (request, snapshot.result == "accepted")
                    error = snapshot.result == "accepted" ? nil : "Shell input changed. Your draft is kept."
                    pending = nil; changed = true
                } else if request.action.requiresCommit, snapshot.state == "armed", snapshot.result == "armed", !committed, !cancelling,
                          snapshot.identity.generation == request.identity.generation,
                          snapshot.identity.epoch == request.identity.epoch, now < request.deadline {
                    committed = true
                    if onCommit?(request.commitKey) != true { committed = false; abort(request) }
                    changed = true
                }
            }
            if pending != nil, !committed, let snapshot, snapshot.state != "armed",
               snapshot.state == "busy" || snapshot.identity.generation != request.identity.generation ||
                snapshot.identity.epoch != request.identity.epoch {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("request"))
                completion = (request, false); pending = nil
                error = "The shell left this prompt. Your draft is kept."
                changed = true
            }
            if pending != nil, now >= request.deadline, !committed, !cancelling {
                abort(request); changed = true
            }
            if pending != nil, committed, now.timeIntervalSince(request.deadline) > 4,
               error != "Waiting for zsh to finish submission…" {
                error = "Waiting for zsh to finish submission…"; changed = true
            }
        }
        if changed { onChange?() }
    }

    private func signalShell() throws {
        let fd = Darwin.open(directory.appendingPathComponent("notify").path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO, info.st_uid == getuid(),
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
        var byte: UInt8 = 46
        guard Darwin.write(fd, &byte, 1) == 1 else { throw POSIXError(.EIO) }
    }

    private func abort(_ request: CommandInputProtocol.Request) {
        // Cancellation is acknowledged by ZLE before an armed request is forgotten.
        var fields = CommandInputProtocol.decode(request.data, count: 10)!
        fields[6] = "abort"
        cancelling = true
        do {
            try CommandInputProtocol.encode(fields)!.write(to: directory.appendingPathComponent("request"), options: .atomic)
            try signalShell()
            error = "Cancelling an expired request. Your draft is kept."
        } catch {
            self.error = "Cannot reach zsh. Close this session to disconnect safely."
        }
    }

    @discardableResult
    func send(_ action: CommandInputProtocol.Action, text: String, cursor: Int,
              expectedIdentity: CommandInputProtocol.Identity? = nil) -> Bool {
        let expected = expectedIdentity ?? snapshot?.identity
        poll()
        guard expected == snapshot?.identity else {
            error = "Shell input changed. Your draft is kept."
            onChange?(); return false
        }
        guard !closed, pending == nil, let snapshot,
              let request = CommandInputProtocol.Request(snapshot: snapshot, token: token, action: action, text: text, cursor: cursor) else {
            error = "Command input is unavailable or the draft is too large."
            onChange?(); return false
        }
        do {
            try request.data.write(to: directory.appendingPathComponent("request"), options: .atomic)
            try signalShell()
            pending = request; committed = false; cancelling = false
            error = nil; completion = nil
            onChange?(); return true
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("request"))
            self.error = "Could not contact the shell. Your draft is kept."
            onChange?(); return false
        }
    }
}
