import AppKit

@main
enum TabLogicTests {
    static var failed = 0

    static func main() {
        directory()
        tabList()
        closePolicy()
        navigation()
        closeActions()
        presentation()
        fills()
        pulse()
        shortcuts()
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
            "close window action is not a tab close",
            LibraryActionRoute.close(tag: closeWindow) != .tab && closeWindow != closeTab
        )
        check(
            "quit is not routed as a tab or window close",
            LibraryActionRoute.close(tag: quit) == nil
        )
    }

    /// Ordinals of `ghostty_action_tag_e` in the pinned header. The route
    /// function is then called with those values.
    static func ghosttyActionTags() -> [String: UInt32] {
        let path = "vendor/ghostty/include/ghostty.h"
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
            ("option command t", chord(command: true, option: true, key: "t")),
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
