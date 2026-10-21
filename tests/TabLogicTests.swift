import AppKit

@main
enum TabLogicTests {
    static var failed = 0

    static func main() {
        directory()
        tabList()
        closePolicy()
        chromeMemory()
        navigation()
        closeActions()
        presentation()
        gitChanges()
        fills()
        pulse()
        shortcuts()
        ProjectExplorerTests.run { check($0, $1) }
        SessionArrangementTests.run { check($0, $1) }
        CommandInputTests.run { check($0, $1) }
        if failed != 0 {
            print("FAILED \(failed)")
            exit(1)
        }
        print("OK")
    }

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("PASS \(name)")
        } else {
            failed += 1
            print("FAIL \(name) \(detail)")
        }
    }

    static func directory() {
        let home = "/Users/boom"
        check(
            "inherited directory is used when non-empty",
            TabDirectory.choose(inherited: "/tmp", home: home) == "/tmp"
        )
        check(
            "home directory is used when inherited is nil",
            TabDirectory.choose(inherited: nil, home: home) == home
        )
        check(
            "home directory is used when inherited is empty",
            TabDirectory.choose(inherited: "", home: home) == home
        )
        check(
            "home directory is used when inherited is blank",
            TabDirectory.choose(inherited: " \n", home: home) == home
        )
    }

    static func tabList() {
        let a = TabID(raw: 1)
        let b = TabID(raw: 2)
        let c = TabID(raw: 3)
        let replacement = TabID(raw: 4)

        var background = TabList(ids: [a, b, c], selected: 1)
        let kept = background.close(a, replacement: replacement)
        if case .removedNonSelected(let visible) = kept {
            check("close non-selected keeps the visible tab", visible == b && background.selectedID == b && background.ids == [b, c])
        } else {
            check("close non-selected keeps the visible tab", false, "\(String(describing: kept))")
        }

        var selected = TabList(ids: [a, b, c], selected: 1)
        let neighbor = selected.close(b, replacement: replacement)
        if case .removedSelected(let now) = neighbor {
            check("close selected selects a neighbor", now == c && selected.selectedID == c && selected.ids == [a, c])
        } else {
            check("close selected selects a neighbor", false, "\(String(describing: neighbor))")
        }

        var end = TabList(ids: [a, b, c], selected: 2)
        let previousNeighbor = end.close(c, replacement: replacement)
        if case .removedSelected(let now) = previousNeighbor {
            check("close selected at the end selects the previous neighbor", now == b && end.selectedID == b)
        } else {
            check("close selected at the end selects the previous neighbor", false)
        }

        var only = TabList(ids: [a], selected: 0)
        let replaced = only.close(a, replacement: replacement)
        if case .replacedLast(let with) = replaced {
            check(
                "close last replaces the tab and the list stays one",
                with == replacement && only.ids == [replacement] && only.selectedID == replacement
            )
        } else {
            check("close last replaces the tab and the list stays one", false)
        }

        let others = TabList(ids: [a, b, c], selected: 0)
        let asked = others.requestingCloseOthers(keeping: 1)
        check(
            "close others requests only the other tabs",
            asked == [a, c] && others.ids == [a, b, c] && others.selectedID == a
        )
        let right = others.requestingCloseRight(of: 0)
        check(
            "close right requests only tabs to the right",
            right == [b, c] && others.requestingCloseRight(of: 2).isEmpty
        )
    }

    static func closePolicy() {
        let a = TabID(raw: 1)
        let b = TabID(raw: 2)

        var ask = ClosePolicy()
        check("alive process asks once", ask.reportTab(a, alive: true) == .ask(.tab(a)) && ask.isPending)
        check("second confirm is refused while one is pending", ask.reportTab(b, alive: true) == .refused && ask.isPending)
        check("cancel keeps the tab", ask.resolve(confirmed: false) == .keep && !ask.isPending)

        var confirm = ClosePolicy()
        _ = confirm.reportTab(a, alive: true)
        _ = confirm.reportTab(b, alive: true)
        check("confirm destroys only that tab", confirm.resolve(confirmed: true) == .destroy([a]))

        var mixed = ClosePolicy()
        _ = mixed.reportTab(a, alive: true)
        check(
            "a dead tab can close while another confirm is open",
            mixed.reportTab(b, alive: false) == .destroy(b) && mixed.isPending
        )
        check("confirm still destroys only the asked tab", mixed.resolve(confirmed: true) == .destroy([a]))

        var dead = ClosePolicy()
        check("a dead tab closes without a prompt", dead.reportTab(a, alive: false) == .destroy(a) && !dead.isPending)

        var window = ClosePolicy()
        check(
            "window close asks when a process is alive",
            window.reportWindow(live: [a, b]) == .ask(.window) && window.isPending
        )
        check(
            "a second window confirm is refused while one is pending",
            window.reportWindow(live: []) == .refused && window.reportTab(a, alive: true) == .refused
        )
        check(
            "a dead tab is kept while the window confirm is open",
            window.reportTab(b, alive: false) == .refused
        )
        check("window cancel keeps the shells", window.resolve(confirmed: false) == .keep && !window.isPending)

        var windowConfirm = ClosePolicy()
        _ = windowConfirm.reportWindow(live: [a])
        check("window confirm closes", windowConfirm.resolve(confirmed: true) == .closeWindow)

        var quiet = ClosePolicy()
        check(
            "window close with nothing alive closes without a prompt",
            quiet.reportWindow(live: []) == .closeWindowNow && !quiet.isPending
        )

        var again = ClosePolicy()
        _ = again.reportTab(a, alive: true)
        _ = again.resolve(confirmed: false)
        check("a confirm can open again after cancel", again.reportTab(b, alive: true) == .ask(.tab(b)))

        let c = TabID(raw: 3)
        var batch = ClosePolicy()
        check("a batch can start", batch.beginBatch([a, b, c]))
        check("the first report waits for the rest of the batch", batch.reportTab(a, alive: true) == .hold && !batch.isPending && batch.isBusy)
        let outside = TabID(raw: 9)
        check(
            "a tab that exits outside a collecting batch is closed",
            batch.reportTab(outside, alive: false) == .destroy(outside) && batch.isBusy && !batch.isPending
        )
        check(
            "a still-running tab outside the batch does not open a second prompt",
            batch.reportTab(TabID(raw: 8), alive: true) == .refused && batch.isBusy
        )
        check("a second batch is refused while one is collecting", !batch.beginBatch([a]))
        check(
            "one alive process asks once for the whole batch",
            batch.reportTab(b, alive: false) == .hold
                && batch.reportTab(c, alive: true) == .ask(.tabs([a, b, c]))
                && batch.isPending
        )
        let exited = TabID(raw: 7)
        check(
            "a tab that exits while the batch prompt is open is closed",
            batch.reportTab(exited, alive: false) == .destroy(exited) && batch.isPending
        )
        check("cancel keeps every tab in the batch", batch.resolve(confirmed: false) == .keep && !batch.isBusy)
        check(
            "the exited tab is not part of the cancelled batch",
            batch.resolve(confirmed: true) == .none
        )

        var batchConfirm = ClosePolicy()
        check("batch confirm removes every requested tab", {
            guard batchConfirm.beginBatch([c, a]) else { return false }
            guard batchConfirm.reportTab(c, alive: false) == .hold else { return false }
            return batchConfirm.reportTab(a, alive: true) == .ask(.tabs([c, a]))
                && batchConfirm.resolve(confirmed: true) == .destroy([c, a])
        }())

        var quietBatch = ClosePolicy()
        check("a batch with nothing alive closes without a prompt", {
            guard quietBatch.beginBatch([a, b]) else { return false }
            guard quietBatch.reportTab(b, alive: false) == .hold else { return false }
            return quietBatch.reportTab(a, alive: false) == .destroyBatch([a, b]) && !quietBatch.isBusy
        }())

        var duplicate = ClosePolicy()
        _ = duplicate.beginBatch([a, b])
        _ = duplicate.reportTab(a, alive: false)
        check(
            "a second exit report for a batch tab is not applied early",
            duplicate.reportTab(a, alive: false) == .refused && duplicate.isBusy && !duplicate.isPending
        )

        var blocked = ClosePolicy()
        _ = blocked.reportWindow(live: [a])
        check("a batch does not start while the window confirm is open", !blocked.beginBatch([a, b]))
    }

    static func chromeMemory() {
        check("a missing window frame is not a restore", !ChromeMemory.hasSavedFrame(nil) && !ChromeMemory.hasSavedFrame("  "))
        check("a saved window frame can be restored", ChromeMemory.hasSavedFrame("0 0 800 600 0 0 1440 900 "))
        check(
            "a saved horizontal layout opens the vertical sidebar",
            !ChromeMemory.sidebarCollapsed(stored: true, obsoletePlacement: "horizontal")
                && !ChromeMemory.sidebarCollapsed(stored: nil, obsoletePlacement: "horizontal")
        )
        check(
            "a saved collapse stays collapsed once there is no placement",
            ChromeMemory.sidebarCollapsed(stored: true, obsoletePlacement: nil)
                && ChromeMemory.sidebarCollapsed(stored: true, obsoletePlacement: "vertical")
                && !ChromeMemory.sidebarCollapsed(stored: false, obsoletePlacement: nil)
                && !ChromeMemory.sidebarCollapsed(stored: nil, obsoletePlacement: nil)
        )
    }

    static func navigation() {
        let previous = TabNavigation.landing(count: 3, selected: 0, move: .previous)
        check(
            "previous wraps and marks the landing",
            previous == TabNavigation.Landing(index: 2, markKeyboardLanding: true)
        )
        let next = TabNavigation.landing(count: 3, selected: 2, move: .next)
        check(
            "next wraps and marks the landing",
            next == TabNavigation.Landing(index: 0, markKeyboardLanding: true)
        )
        let last = TabNavigation.landing(count: 3, selected: 0, move: .last)
        check(
            "last moves to the end and marks the landing",
            last == TabNavigation.Landing(index: 2, markKeyboardLanding: true)
        )
        let stayed = TabNavigation.landing(count: 3, selected: 2, move: .last)
        check(
            "last on the last row does not mark a landing",
            stayed == TabNavigation.Landing(index: 2, markKeyboardLanding: false)
        )
        check(
            "an index outside the list does not move",
            TabNavigation.landing(count: 3, selected: 1, move: .index(9)) == nil
        )
        let numbered = TabNavigation.landing(count: 3, selected: 0, move: .index(2))
        check(
            "a numbered tab lands on that row and marks it",
            numbered == TabNavigation.Landing(index: 1, markKeyboardLanding: true)
        )
    }

    static func closeActions() {
        let tags = ghosttyActionTags()
        guard let closeTab = tags["GHOSTTY_ACTION_CLOSE_TAB"],
              let closeWindow = tags["GHOSTTY_ACTION_CLOSE_WINDOW"],
              let quit = tags["GHOSTTY_ACTION_QUIT"] else {
            check("close window action closes the window", false, "header tags missing")
            return
        }
        check(
            "close tab action closes the current tab",
            LibraryActionRoute.close(tag: closeTab) == .tab
        )
        check(
            "close window action closes the window",
            LibraryActionRoute.close(tag: closeWindow) == .window
        )
        check(
            "quit is not routed as a tab or window close",
            LibraryActionRoute.close(tag: quit) == nil
        )
    }

    /// Ordinals of `ghostty_action_tag_e` in the owned core header. The route
    /// function is then called with those values.
    static func ghosttyActionTags() -> [String: UInt32] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("core/include/ghostty.h").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let quit = text.range(of: "\n  GHOSTTY_ACTION_QUIT,"),
              let end = text.range(of: "} ghostty_action_tag_e;", range: quit.lowerBound..<text.endIndex) else {
            return [:]
        }
        var tags: [String: UInt32] = [:]
        var value: UInt32 = 0
        let body = text[text.index(after: quit.lowerBound)..<end.lowerBound]
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("GHOSTTY_ACTION_") else { continue }
            let name = trimmed.prefix { $0 != "," && $0 != " " && $0 != "=" && $0 != "/" }
            guard !name.isEmpty else { continue }
            tags[String(name)] = value
            value += 1
        }
        return tags
    }

    static func presentation() {
        let custom = TabPresentation.make(label: "me@remote:~/work", customTitle: true)
        check(
            "custom title is not split",
            custom.primary == "me@remote:~/work" && custom.secondary == nil
        )

        let host = ProcessInfo.processInfo.hostName
        let local = TabPresentation.make(label: "me@\(host):~", customTitle: false)
        check(
            "local host is not a second line",
            !host.isEmpty && local.primary == "~" && local.secondary == nil,
            "host=\(host) primary=\(local.primary) secondary=\(String(describing: local.secondary))"
        )

        let remote = TabPresentation.make(label: "me@example-remote:~/app", customTitle: false)
        check(
            "remote host is the second line",
            remote.primary == "app" && remote.secondary == "me@example-remote"
        )

        let same = TabPresentation.make(label: "me@example-remote:~", customTitle: false)
        let duplicates = TabPresentation.disambiguate([same, same])
        check(
            "duplicate rows are disambiguated",
            duplicates.count == 2
                && duplicates[0].primary == duplicates[1].primary
                && duplicates[0].secondary != duplicates[1].secondary
                && (duplicates[0].secondary?.contains("example-remote") == true)
                && (duplicates[1].secondary?.contains("example-remote") == true)
        )

        let src = TabPresentation.make(label: "~/src/app", customTitle: false)
        let lib = TabPresentation.make(label: "~/lib/app", customTitle: false)
        check(
            "same directory name keeps a different parent",
            src.primary == "app" && lib.primary == "app" && src.secondary != lib.secondary
        )

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = home + "/workspace/boome"
        let located = TabPresentation.make(label: "ignored", customTitle: false, directory: directory)
        check(
            "a working directory is a title and a friendly path",
            located.primary == "boome" && located.secondary == "~/workspace/boome"
        )
        let renamed = TabPresentation.make(label: "Notes", customTitle: true, directory: directory)
        check(
            "a custom title keeps the path line",
            renamed.primary == "Notes" && renamed.secondary == "~/workspace/boome"
        )
    }

    static func gitChanges() {
        let addedAndRemoved = GitChangeCount(filesChanged: 2, linesAdded: 12, linesRemoved: 3)
        check(
            "change tokens put additions before deletions",
            addedAndRemoved.tokens == [.added(12), .removed(3)] && addedAndRemoved.accessibilityMark == "+12 -3"
        )
        let removedOnly = GitChangeCount(filesChanged: 1, linesAdded: 0, linesRemoved: 4)
        check("a deletion-only change is one token", removedOnly.tokens == [.removed(4)])
        let binary = GitChangeCount(filesChanged: 1, linesAdded: 0, linesRemoved: 0)
        check(
            "a binary change shows zero",
            binary.showsBadge && binary.tokens == [.zero]
        )
        let clean = GitChangeCount(filesChanged: 0, linesAdded: 0, linesRemoved: 0)
        check("a clean worktree has no badge", !clean.showsBadge)

        let porcelain = Data((
            "# branch.oid abcdef\0"
                + "1 .M N... 100644 100644 100644 aaa bbb src/A.swift\0"
                + "? new file.txt\0"
                + "2 R. N... 100644 100644 100644 aaa bbb R090 src/New.swift\0"
                + "src/Old.swift\0"
        ).utf8)
        let numstat = """
        4\t1\tsrc/A.swift
        3\t0\tsrc/{Old => New}.swift
        2\t0\t"quoted name.swift"

        """
        let count = GitChangeCount.aggregate(porcelain: porcelain, numstat: numstat) { path in
            path == "new file.txt" ? 2 : 0
        }
        check(
            "porcelain and numstat add tracked lines and untracked newlines",
            count.filesChanged == 3 && count.linesAdded == 9 && count.linesRemoved == 1,
            "files=\(count.filesChanged) added=\(count.linesAdded) removed=\(count.linesRemoved)"
        )
        check(
            "a rename destination is the numstat key",
            GitNumstat.destination(of: "src/{Old => New}.swift") == "src/New.swift"
                && GitNumstat.destination(of: "old => new") == "new"
        )
        check(
            "quoted numstat paths unescape",
            GitQuotedPath.unquote(#""my file.swift""#) == "my file.swift"
                && GitNumstat.parse("2\t0\t\"my file.swift\"\n")["my file.swift"]?.added == 2
        )

        let headed = Data(("# branch.head main\0" + "# branch.oid abcdef0123456789\0").utf8)
        check("porcelain reports the branch name", GitStatusList.branch(in: headed) == "main")
        let detached = Data(("# branch.head (detached)\0" + "# branch.oid 0123456789abcdef\0").utf8)
        check("a detached head uses the short commit", GitStatusList.branch(in: detached) == "0123456")

        let bounds = NSRect(x: 0, y: 0, width: 200, height: 34)
        let plain = TabRowLayout.make(hasPath: false, hasBranch: false, changes: nil, in: bounds, left: 12)
        check(
            "a row without changes keeps the title inset",
            plain.badge == nil && plain.menu == nil && plain.close == nil
                && plain.path == nil && plain.title == NSRect(x: 12, y: 8, width: 176, height: 18)
        )
        check(
            "title actions appear only while the pointer is on the row",
            !TabChrome.showsTitleActions(hovered: false) && TabChrome.showsTitleActions(hovered: true)
        )
        let closed = TabRowLayout.make(
            hasPath: true,
            hasBranch: false,
            changes: nil,
            showsTitleActions: true,
            in: NSRect(x: 0, y: 0, width: 200, height: 46),
            left: 12
        )
        check(
            "hover actions sit on the title line and leave the path full width",
            closed.path == NSRect(x: 12, y: 26, width: 176, height: 14)
                && closed.menu == NSRect(x: 156, y: 7, width: 16, height: 16)
                && closed.close == NSRect(x: 176, y: 7, width: 16, height: 16)
                && closed.title.maxX + 6 <= (closed.menu?.minX ?? 0)
                && (closed.menu?.maxY ?? 0) <= closed.title.maxY
        )
        let three = NSRect(x: 0, y: 0, width: 200, height: 62)
        let withBadge = TabRowLayout.make(
            hasPath: true,
            hasBranch: true,
            changes: addedAndRemoved,
            showsTerminalIcon: true,
            showsTitleActions: true,
            in: three,
            left: 12
        )
        let resting = TabRowLayout.make(
            hasPath: true,
            hasBranch: true,
            changes: addedAndRemoved,
            showsTerminalIcon: true,
            in: three,
            left: 12
        )
        check(
            "the change pill stays on the branch line while title actions appear",
            withBadge.badge != nil
                && withBadge.path != nil
                && withBadge.branch != nil
                && withBadge.menu != nil
                && withBadge.close != nil
                && withBadge.badge == resting.badge
                && withBadge.path == resting.path
                && withBadge.title.maxX < resting.title.maxX
                && (withBadge.path?.maxY ?? 0) <= (withBadge.branch?.minY ?? 0)
                && (withBadge.close?.maxY ?? 0) <= withBadge.title.maxY
                && (withBadge.branch?.maxX ?? 0) <= (withBadge.badge?.minX ?? 0)
        )
        let addition = GitChangeBadge.addition.usingColorSpace(.sRGB)
        let deletion = GitChangeBadge.deletion.usingColorSpace(.sRGB)
        check(
            "addition and deletion use the default ANSI green and red",
            addition.map { abs($0.redComponent - 181.0 / 255.0) < 0.01 && abs($0.greenComponent - 189.0 / 255.0) < 0.01 && abs($0.blueComponent - 104.0 / 255.0) < 0.01 } == true
                && deletion.map { abs($0.redComponent - 204.0 / 255.0) < 0.01 && abs($0.greenComponent - 102.0 / 255.0) < 0.01 && abs($0.blueComponent - 102.0 / 255.0) < 0.01 } == true
        )
        let fill = GitChangeBadge.fill(on: BoomeChrome.fallbackBackground)
        check("the pill fill is a 5 percent foreground", abs(fill.alphaComponent - 0.05) < 0.001)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boome-git-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("boome-not-a-repo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            check("a directory that is not a repository has no count", GitChangeQuery.load(workingDirectory: outside.path) == nil)

            check("git init", git(["init", "-b", "main"], in: root) == 0)
            try Data([0x61, 0x00, 0x62]).write(to: root.appendingPathComponent("binary.dat"))
            let binaryOnly = GitChangeQuery.load(workingDirectory: root.path)
            check(
                "an untracked binary file shows zero lines",
                binaryOnly?.status.branch == "main"
                    && binaryOnly?.status.count.filesChanged == 1
                    && binaryOnly?.status.count.linesAdded == 0
                    && binaryOnly?.status.count.linesRemoved == 0
                    && binaryOnly?.status.count.tokens == [.zero],
                "\(String(describing: binaryOnly))"
            )

            try Data("hello\nworld\n".utf8).write(to: root.appendingPathComponent("my file.txt"))
            let untracked = GitChangeQuery.load(workingDirectory: root.path)
            check(
                "untracked text adds its newline count",
                untracked?.status.count.filesChanged == 2 && untracked?.status.count.linesAdded == 2 && untracked?.status.count.linesRemoved == 0,
                "\(String(describing: untracked))"
            )

            check("git add", git(["add", "binary.dat", "my file.txt"], in: root) == 0)
            check("git commit", git(["-c", "user.name=Boome", "-c", "user.email=boome@example.com", "commit", "-m", "init"], in: root) == 0)
            let committed = GitChangeQuery.load(workingDirectory: root.path)
            check(
                "a clean worktree hides the badge",
                committed?.status.count.showsBadge == false && committed?.status.branch == "main",
                "\(String(describing: committed))"
            )

            try Data("hello\nWORLD\n".utf8).write(to: root.appendingPathComponent("my file.txt"))
            let edited = GitChangeQuery.load(workingDirectory: root.path)
            check(
                "an edited tracked file reports both sides",
                edited?.status.count.filesChanged == 1 && edited?.status.count.linesAdded == 1 && edited?.status.count.linesRemoved == 1,
                "\(String(describing: edited))"
            )
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let fromNested = GitChangeQuery.load(workingDirectory: nested.path)
            let sameRoot = fromNested.map {
                URL(fileURLWithPath: $0.root).resolvingSymlinksInPath().path
                    == root.resolvingSymlinksInPath().path
            } == true
            check(
                "a subdirectory uses the worktree total",
                sameRoot && fromNested?.status == edited?.status,
                "root=\(fromNested?.root ?? "") count=\(String(describing: fromNested?.status))"
            )
        } catch {
            check("git change fixture", false, "\(error)")
        }
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func fills() {
        let dark = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
        let light = NSColor(srgbRed: 0.95, green: 0.94, blue: 0.90, alpha: 1)
        check("dark selection is stronger than hover and hover is stronger than rest", ordered(dark))
        check("light selection is stronger than hover and hover is stronger than rest", ordered(light))
        check(
            "new tab has no resting fill",
            strength(BoomeChrome.newTabFill(hovered: false, on: dark)) == 0
                && strength(BoomeChrome.newTabFill(hovered: false, on: light)) == 0
        )
        check(
            "new tab hover uses the row hover fill",
            strength(BoomeChrome.newTabFill(hovered: true, on: dark)) == strength(BoomeChrome.rowFill(.hover, on: dark))
                && strength(BoomeChrome.newTabFill(hovered: true, on: light)) == strength(BoomeChrome.rowFill(.hover, on: light))
        )
        check(
            "selection fill is not a solid plate",
            strength(BoomeChrome.rowFill(.selected, on: dark)) < 1
                && strength(BoomeChrome.rowFill(.selected, on: light)) < 1
        )
    }

    static func ordered(_ background: NSColor) -> Bool {
        let selected = strength(BoomeChrome.rowFill(.selected, on: background))
        let hover = strength(BoomeChrome.rowFill(.hover, on: background))
        let rest = strength(BoomeChrome.rowFill(.rest, on: background))
        return selected > hover && hover > rest && rest == 0
    }

    static func strength(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return rgb.alphaComponent
    }

    static func pulse() {
        check("reduced motion skips the pulse", !SelectionPulse.plays(marked: true, reduceMotion: true))
        check("a marked landing pulses when motion is allowed", SelectionPulse.plays(marked: true, reduceMotion: false))
        check("an unmarked row does not pulse", !SelectionPulse.plays(marked: false, reduceMotion: false))
    }

    static func shortcuts() {
        func chord(
            command: Bool = false,
            option: Bool = false,
            shift: Bool = false,
            control: Bool = false,
            key: String = "",
            keyCode: UInt16 = 0
        ) -> AppShortcut.Chord {
            AppShortcut.Chord(
                command: command,
                option: option,
                shift: shift,
                control: control,
                key: key,
                keyCode: keyCode
            )
        }
        let owned: [(String, AppShortcut.Chord)] = [
            ("command t", chord(command: true, key: "t")),
            ("command w", chord(command: true, key: "w")),
            ("command q", chord(command: true, key: "q")),
            ("option command s", chord(command: true, option: true, key: "s")),
            ("shift command left bracket", chord(command: true, shift: true, key: "[")),
            ("shift command right bracket", chord(command: true, shift: true, key: "]")),
            ("control tab", chord(control: true, keyCode: 48)),
            ("control shift tab", chord(shift: true, control: true, keyCode: 48)),
        ]
        for (name, chord) in owned {
            check("\(name) is owned by the app", AppShortcut.owns(chord))
        }
        check(
            "an ordinary key is not owned by the app",
            !AppShortcut.owns(chord(key: "a", keyCode: 0))
        )
    }
}
