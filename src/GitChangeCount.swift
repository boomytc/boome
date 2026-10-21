import AppKit

/// Uncommitted changes for one git worktree. Warp's vertical tab shows the same
/// total: tracked lines from `git diff --numstat HEAD`, plus a newline count for
/// each untracked text file. A binary file still counts as a changed file.
struct GitChangeCount: Equatable {
    var filesChanged: Int
    var linesAdded: Int
    var linesRemoved: Int

    var showsBadge: Bool {
        filesChanged > 0 || linesAdded > 0 || linesRemoved > 0
    }

    enum Token: Equatable {
        case added(Int)
        case removed(Int)
        case zero

        var text: String {
            switch self {
            case .added(let count): return "+\(count)"
            case .removed(let count): return "-\(count)"
            case .zero: return "0"
            }
        }
    }

    /// `+N` then `-M`. `0` when files changed and both line totals are zero.
    var tokens: [Token] {
        var result: [Token] = []
        if linesAdded > 0 { result.append(.added(linesAdded)) }
        if linesRemoved > 0 { result.append(.removed(linesRemoved)) }
        if result.isEmpty { result.append(.zero) }
        return result
    }

    var accessibilityMark: String {
        tokens.map(\.text).joined(separator: " ")
    }

    static func aggregate(
        porcelain: Data,
        numstat: String,
        untrackedLines: (String) -> Int
    ) -> GitChangeCount {
        let stats = GitNumstat.parse(numstat)
        var files = 0
        var added = 0
        var removed = 0
        for entry in GitStatusList.parse(porcelain) {
            files += 1
            switch entry.kind {
            case .untracked:
                added += max(0, untrackedLines(entry.path))
            case .tracked:
                if let stat = stats[entry.path] {
                    added += stat.added
                    removed += stat.removed
                }
            }
        }
        return GitChangeCount(filesChanged: files, linesAdded: added, linesRemoved: removed)
    }
}

/// Branch name and uncommitted totals for one worktree. Both come from one status read.
struct GitWorktreeStatus: Equatable {
    var branch: String?
    var count: GitChangeCount
}

/// `git status --porcelain=2 -z` records that contribute to the badge.
enum GitStatusList {
    struct Entry: Equatable {
        enum Kind: Equatable { case tracked, untracked }
        var kind: Kind
        var path: String
    }

    /// `# branch.head main`. A detached head uses the short commit id.
    static func branch(in data: Data) -> String? {
        var head: String?
        var oid: String?
        for record in splitNUL(data) {
            guard let text = String(data: record, encoding: .utf8) else { continue }
            guard text.hasPrefix("# ") else { continue }
            let body = text.dropFirst(2)
            if body.hasPrefix("branch.head ") {
                head = String(body.dropFirst("branch.head ".count)).trimmingCharacters(in: .whitespaces)
            } else if body.hasPrefix("branch.oid ") {
                oid = String(body.dropFirst("branch.oid ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let head, !head.isEmpty, head != "(detached)", head != "(initial)" {
            return head
        }
        guard let oid, oid.count >= 7, oid.allSatisfy(\.isHexDigit) else { return nil }
        return String(oid.prefix(7))
    }

    static func parse(_ data: Data) -> [Entry] {
        let records = splitNUL(data)
        var entries: [Entry] = []
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let text = String(data: record, encoding: .utf8), !text.isEmpty else { continue }
            if text.hasPrefix("# ") { continue }
            switch text.first {
            case "1":
                if let path = field(text, index: 8, limit: 9) {
                    entries.append(Entry(kind: .tracked, path: path))
                }
            case "2":
                if let path = field(text, index: 9, limit: 10) {
                    entries.append(Entry(kind: .tracked, path: path))
                }
                index += 1
            case "u":
                if let path = field(text, index: 10, limit: 11) {
                    entries.append(Entry(kind: .tracked, path: path))
                }
            case "?":
                guard text.hasPrefix("? "), text.count > 2 else { continue }
                entries.append(Entry(kind: .untracked, path: String(text.dropFirst(2))))
            default:
                break
            }
        }
        return entries
    }

    /// The path is the last field and may contain spaces.
    private static func field(_ text: String, index: Int, limit: Int) -> String? {
        var parts: [Substring] = []
        var rest = Substring(text)
        while parts.count < limit - 1, let space = rest.firstIndex(of: " ") {
            parts.append(rest[..<space])
            rest = rest[rest.index(after: space)...]
        }
        parts.append(rest)
        guard parts.count == limit else { return nil }
        let path = String(parts[index])
        return path.isEmpty ? nil : path
    }

    private static func splitNUL(_ data: Data) -> [Data] {
        var records: [Data] = []
        var start = data.startIndex
        for offset in data.indices where data[offset] == 0 {
            if offset > start { records.append(data[start..<offset]) }
            start = data.index(after: offset)
        }
        if start < data.endIndex { records.append(data[start..<data.endIndex]) }
        return records
    }
}

/// `git diff --numstat` rows, keyed by the worktree path.
enum GitNumstat {
    struct Stat: Equatable {
        var added: Int
        var removed: Int
    }

    static func parse(_ text: String) -> [String: Stat] {
        var map: [String: Stat] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            let stat = Stat(added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0)
            let field = parts[2...].joined(separator: "\t")
            let key = GitQuotedPath.unquote(field)
            map[key] = stat
            let destination = destination(of: key)
            if destination != key { map[destination] = stat }
        }
        return map
    }

    /// `old => new` and `dir/{old => new}/file` both name the worktree path.
    static func destination(of field: String) -> String {
        guard let marker = field.range(of: " => ") else { return field }
        let left = field[..<marker.lowerBound]
        let right = field[marker.upperBound...]
        if let open = left.lastIndex(of: "{"), let close = right.firstIndex(of: "}") {
            let prefix = left[..<open]
            let name = right[..<close]
            let suffix = right[right.index(after: close)...]
            return String(prefix) + String(name) + String(suffix)
        }
        return String(right)
    }
}

/// git quotes unusual paths as C strings when `core.quotePath` is on.
enum GitQuotedPath {
    static func unquote(_ field: String) -> String {
        guard field.count >= 2, field.first == "\"", field.last == "\"" else { return field }
        let bytes = Array(field.utf8)
        var index = 1
        let end = bytes.count - 1
        var out: [UInt8] = []
        while index < end {
            let byte = bytes[index]
            index += 1
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                continue
            }
            guard index < end else { break }
            let escaped = bytes[index]
            index += 1
            switch escaped {
            case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
            case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            default:
                guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(escaped) else {
                    out.append(escaped)
                    continue
                }
                var value = Int(escaped - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < end, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                out.append(UInt8(truncatingIfNeeded: value))
            }
        }
        return String(bytes: out, encoding: .utf8) ?? field
    }
}

/// Newline count for an untracked file. A NUL in the first 1024 bytes, a symlink,
/// or a file over 20 MB contributes no lines. Warp counts `\\n` bytes, not visual lines.
enum UntrackedLines {
    static let maxBytes = 20_000_000
    private static let probeBytes = 1024

    static func count(in root: String, relative: String) -> Int {
        count(at: URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relative))
    }

    static func count(at url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isRegularFile != true { return 0 }
        if let size = values.fileSize, size > maxBytes { return 0 }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let probe = handle.readData(ofLength: probeBytes)
        if probe.contains(0) { return 0 }
        var newlines = newlineCount(probe)
        if probe.count < probeBytes { return newlines }
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            newlines += newlineCount(chunk)
        }
        return newlines
    }

    private static func newlineCount(_ data: Data) -> Int {
        data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
    }
}

enum GitChangeQuery {
    /// Nil when `directory` is not inside a git worktree or git cannot be read.
    static func load(workingDirectory directory: String) -> (root: String, status: GitWorktreeStatus)? {
        guard let top = GitProcess.output(["rev-parse", "--show-toplevel"], in: directory),
              top.status == 0,
              let root = String(data: top.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty
        else { return nil }

        guard let status = GitProcess.output(
            ["status", "--untracked-files=all", "--branch", "--porcelain=2", "-z"],
            in: root
        ), status.status == 0 else { return nil }

        let numstat: String
        if let diff = GitProcess.output(["diff", "--numstat", "HEAD"], in: root),
           diff.status == 0,
           let text = String(data: diff.data, encoding: .utf8) {
            numstat = text
        } else {
            numstat = ""
        }

        let count = GitChangeCount.aggregate(porcelain: status.data, numstat: numstat) { relative in
            UntrackedLines.count(in: root, relative: relative)
        }
        return (root, GitWorktreeStatus(branch: GitStatusList.branch(in: status.data), count: count))
    }
}

enum GitProcess {
    struct Output {
        var data: Data
        var status: Int32
    }

    static func output(_ arguments: [String], in directory: String) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("boome-git-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        try? handle.close()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Output(data: data, status: process.terminationStatus)
    }
}

/// Title, path, and the branch line. The change pill sits on the branch line, at the trailing edge.
struct TabRowLayout: Equatable {
    var terminalIcon: NSRect?
    var title: NSRect
    var path: NSRect?
    var branchIcon: NSRect?
    var branch: NSRect?
    var badge: NSRect?
    /// Vertical ellipsis, then the close mark. Both sit on the title line.
    var menu: NSRect?
    var close: NSRect?

    static let titleHeight: CGFloat = 18
    static let lineHeight: CGFloat = 14
    static let lineGap: CGFloat = 2
    static let terminalIconSide: CGFloat = 14
    static let branchIconSide: CGFloat = 11

    static func make(
        hasPath: Bool,
        hasBranch: Bool,
        showsBranchName: Bool = true,
        changes: GitChangeCount?,
        showsTerminalIcon: Bool = false,
        showsTitleActions: Bool = false,
        in bounds: NSRect,
        left: CGFloat
    ) -> TabRowLayout {
        let showsBadge = hasBranch && changes?.showsBadge == true
        let block = titleHeight
            + (hasPath ? lineGap + lineHeight : 0)
            + (hasBranch ? lineGap + lineHeight : 0)
        let top = ((bounds.height - block) / 2).rounded()
        let textLeft = left + (showsTerminalIcon ? terminalIconSide + 6 : 0)
        let trailing: CGFloat = 12
        let textWidth = max(0, bounds.width - textLeft - trailing)
        var title = NSRect(x: textLeft, y: top, width: textWidth, height: titleHeight)
        let actionSide: CGFloat = 16
        let actionGap: CGFloat = 4
        var menu: NSRect?
        var close: NSRect?
        if showsTitleActions {
            let mark = NSRect(
                x: bounds.width - 8 - actionSide,
                y: (title.minY + (title.height - actionSide) / 2).rounded(),
                width: actionSide,
                height: actionSide
            )
            close = mark
            menu = NSRect(x: mark.minX - actionGap - actionSide, y: mark.minY, width: actionSide, height: actionSide)
            title.size.width = max(0, (menu?.minX ?? mark.minX) - 6 - textLeft)
        }
        let terminalIcon = showsTerminalIcon
            ? NSRect(
                x: left,
                y: (title.minY + (title.height - terminalIconSide) / 2).rounded(),
                width: terminalIconSide,
                height: terminalIconSide
            )
            : nil
        let path = hasPath
            ? NSRect(x: textLeft, y: title.maxY + lineGap, width: textWidth, height: lineHeight)
            : nil
        guard hasBranch else {
            return TabRowLayout(
                terminalIcon: terminalIcon,
                title: title,
                path: path,
                branchIcon: nil,
                branch: nil,
                badge: nil,
                menu: menu,
                close: close
            )
        }
        let branchLine = NSRect(
            x: textLeft,
            y: (path?.maxY ?? title.maxY) + lineGap,
            width: textWidth,
            height: lineHeight
        )
        let branchIcon = showsBranchName
            ? NSRect(
                x: textLeft,
                y: (branchLine.minY + (branchLine.height - branchIconSide) / 2).rounded(),
                width: branchIconSide,
                height: branchIconSide
            )
            : nil
        var badge: NSRect?
        var branchTextX = (branchIcon?.maxX ?? textLeft) + (showsBranchName ? 4 : 0)
        var branchTextWidth = showsBranchName ? max(0, branchLine.maxX - branchTextX) : 0
        if showsBadge, let changes {
            let badgeSize = GitChangeBadge.size(for: changes)
            let pill = NSRect(
                x: bounds.width - trailing - badgeSize.width,
                y: (branchLine.minY + (branchLine.height - badgeSize.height) / 2).rounded(),
                width: badgeSize.width,
                height: badgeSize.height
            )
            badge = pill
            branchTextWidth = max(0, pill.minX - 6 - branchTextX)
        }
        if branchTextWidth == 0 { branchTextX = textLeft }
        return TabRowLayout(
            terminalIcon: terminalIcon,
            title: title,
            path: path,
            branchIcon: branchTextWidth == 0 ? nil : branchIcon,
            branch: NSRect(x: branchTextX, y: branchLine.minY, width: branchTextWidth, height: lineHeight),
            badge: badge,
            menu: menu,
            close: close
        )
    }
}

/// Warp's diff pill: 10pt semibold, 4pt horizontal and 1pt vertical padding, 3pt corners,
/// foreground at 5% opacity. `+` uses Ghostty's default ANSI green, `-` its ANSI red.
enum GitChangeBadge {
    static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let horizontalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = 1
    static let radius: CGFloat = 3
    static let addition = NSColor(srgbRed: 181.0 / 255.0, green: 189.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
    static let deletion = NSColor(srgbRed: 204.0 / 255.0, green: 102.0 / 255.0, blue: 102.0 / 255.0, alpha: 1)

    static func fill(on background: NSColor) -> NSColor {
        BoomeChrome.isDark(background) ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.05)
    }

    static func zeroColor(on background: NSColor) -> NSColor {
        let foreground = BoomeChrome.isDark(background)
            ? NSColor(srgbRed: 0.93, green: 0.91, blue: 0.88, alpha: 1)
            : BoomeChrome.ink
        guard let base = background.usingColorSpace(.sRGB), let ink = foreground.usingColorSpace(.sRGB) else {
            return foreground
        }
        func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from * 0.4 + to * 0.6 }
        return NSColor(
            srgbRed: mix(base.redComponent, ink.redComponent),
            green: mix(base.greenComponent, ink.greenComponent),
            blue: mix(base.blueComponent, ink.blueComponent),
            alpha: 1
        )
    }

    static func size(for count: GitChangeCount) -> NSSize {
        let measured = pieces(count)
        return NSSize(
            width: ceil(measured.width) + horizontalPadding * 2,
            height: ceil(measured.height) + verticalPadding * 2
        )
    }

    static func draw(_ count: GitChangeCount, in badge: NSRect, on background: NSColor) {
        NSBezierPath(roundedRect: badge, xRadius: radius, yRadius: radius).fill(using: fill(on: background))
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        var x = badge.minX + horizontalPadding
        let textHeight = max(0, badge.height - verticalPadding * 2)
        let y = badge.minY + verticalPadding
        for (index, piece) in pieces(count).items.enumerated() {
            if index > 0 { x += space }
            let color: NSColor
            switch piece.token {
            case .added: color = addition
            case .removed: color = deletion
            case .zero: color = zeroColor(on: background)
            }
            (piece.token.text as NSString).draw(
                with: NSRect(x: x, y: y, width: ceil(piece.width), height: textHeight),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .foregroundColor: color]
            )
            x += piece.width
        }
    }

    private struct Measured {
        var items: [(token: GitChangeCount.Token, width: CGFloat)]
        var width: CGFloat
        var height: CGFloat
    }

    private static func pieces(_ count: GitChangeCount) -> Measured {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let space = (" " as NSString).size(withAttributes: attributes).width
        var items: [(token: GitChangeCount.Token, width: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, token) in count.tokens.enumerated() {
            if index > 0 { width += space }
            let size = (token.text as NSString).size(withAttributes: attributes)
            items.append((token, size.width))
            width += size.width
            height = max(height, size.height)
        }
        return Measured(items: items, width: width, height: height)
    }
}

private extension NSBezierPath {
    func fill(using color: NSColor) {
        color.setFill()
        fill()
    }
}
