import AppKit

// Local fixtures only: no user's project, preferences, or documents are modified.
enum ProjectExplorerTests {
    static func run(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("boome-project-tests-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let suite = "com.boom.boome.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? fm.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let sources = root.appendingPathComponent("Sources", isDirectory: true)
            try fm.createDirectory(at: sources, withIntermediateDirectories: true)
            let package = root.appendingPathComponent("Example.app", isDirectory: true)
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            for name in ["file10.txt", "file2.txt", ".hidden"] {
                try Data("hello\n".utf8).write(to: root.appendingPathComponent(name))
            }
            let link = root.appendingPathComponent("loop")
            try fm.createSymbolicLink(at: link, withDestinationURL: root)
            let entries = try ProjectFiles.children(of: root, showHidden: false)
            check("project folders sort before files", entries.first?.url == sources)
            check("project files use natural numeric sorting", entries.firstIndex(where: { $0.name == "file2.txt" })! < entries.firstIndex(where: { $0.name == "file10.txt" })!)
            check("hidden files are hidden by default", !entries.contains(where: { $0.name == ".hidden" }))
            check("hidden files can be shown", try ProjectFiles.children(of: root, showHidden: true).contains(where: { $0.name == ".hidden" }))
            check("directory symlinks are leaves, preventing cycles", entries.first(where: { $0.name == "loop" }).map { $0.isSymbolicLink && !$0.isDirectory } == true)
            check("application packages are not recursively expanded", entries.first(where: { $0.name == "Example.app" })?.isDirectory == false)
            check("an explicitly chosen symlink root can still be listed", try ProjectFiles.children(of: link, showHidden: false).count == entries.count)
            check("missing directories report a failure", fails { _ = try ProjectFiles.children(of: root.appendingPathComponent("missing"), showHidden: false) })

            for tabs: CGFloat in [0, 200] {
                for explorer in [false, true] {
                    for editor in [false, true] {
                        let minimum = WorkspaceLayout.minimumWidth(tabSidebarWidth: tabs, explorer: explorer, editor: editor)
                        for width in [minimum, max(minimum, 1100), 1600] {
                            let panels = WorkspaceLayout.widths(windowWidth: width, tabSidebarWidth: tabs, explorer: explorer, editor: editor)
                            let separators = (tabs > 0 ? 1.0 : 0) + (explorer ? 1 : 0) + (editor ? 1 : 0)
                            let terminal = width - tabs - panels.explorer - panels.editor - separators
                            check("panels preserve terminal space (\(tabs),\(explorer),\(editor),\(width))", terminal >= 240 && (explorer ? panels.explorer >= 180 : panels.explorer == 0) && (editor ? panels.editor >= 300 : panels.editor == 0))
                        }
                    }
                }
            }
            let file = root.appendingPathComponent("file2.txt")
            var document = try ProjectTextFile.read(file)
            check("UTF-8 text loads without modification", document.savedText == "hello\n")
            try document.save("changed 中文\n")
            check("edited UTF-8 text saves atomically", try String(contentsOf: file, encoding: .utf8) == "changed 中文\n" && document.savedText == "changed 中文\n")
            try Data("external\n".utf8).write(to: file)
            check("save detects an external edit", fails { try document.save("local\n") })
            check("external edits are not silently overwritten", try String(contentsOf: file, encoding: .utf8) == "external\n")
            try document.save("confirmed\n", overwrite: true)
            check("explicitly confirmed overwrite succeeds", try String(contentsOf: file, encoding: .utf8) == "confirmed\n")
            let crlf = root.appendingPathComponent("crlf.txt")
            try Data([0xef, 0xbb, 0xbf] + Array("a\r\nb\r\n".utf8)).write(to: crlf)
            var windows = try ProjectTextFile.read(crlf)
            check("CRLF and BOM are normalized only in the editing buffer", windows.savedText == "a\nb\n" && windows.lineEnding == "\r\n")
            try windows.save("a\nc\n")
            check("saving retains the original CRLF and UTF-8 BOM", try Data(contentsOf: crlf) == Data([0xef, 0xbb, 0xbf] + Array("a\r\nc\r\n".utf8)))
            let binary = root.appendingPathComponent("binary.dat")
            try Data([0x61, 0, 0x62]).write(to: binary)
            check("binary files are refused", fails { _ = try ProjectTextFile.read(binary) })
            let invalid = root.appendingPathComponent("invalid.dat")
            try Data([0xff, 0xff]).write(to: invalid)
            check("unsupported text encodings are refused", fails { _ = try ProjectTextFile.read(invalid) })
            let large = root.appendingPathComponent("large.txt")
            try Data(repeating: 65, count: ProjectTextFile.maximumBytes + 1).write(to: large)
            check("oversized text is refused before loading the editor", fails { _ = try ProjectTextFile.read(large) })
            check("folders cannot be opened as text documents", fails { _ = try ProjectTextFile.read(sources) })
            let fileLink = root.appendingPathComponent("linked.txt")
            try fm.createSymbolicLink(at: fileLink, withDestinationURL: file)
            var linked = try ProjectTextFile.read(fileLink)
            try linked.save("through link\n")
            check("saving through a symlink preserves the link", try fm.attributesOfItem(atPath: fileLink.path)[.type] as? FileAttributeType == .typeSymbolicLink && String(contentsOf: file, encoding: .utf8) == "through link\n")
            try fm.removeItem(at: fileLink)
            try fm.createSymbolicLink(at: fileLink, withDestinationURL: crlf)
            check("a retargeted symlink cannot overwrite the previous target", fails { try linked.save("wrong target", overwrite: true) })
            let executable = root.appendingPathComponent("script.sh")
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            var script = try ProjectTextFile.read(executable)
            try script.save("#!/bin/sh\necho ok\n")
            check("atomic save retains executable permissions", (try fm.attributesOfItem(atPath: executable.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)

            _ = NSApplication.shared
            let explorerView = ProjectExplorerView(frame: NSRect(x: 0, y: 0, width: 260, height: 600), defaults: defaults)
            explorerView.follow(directory: root.path)
            check("a closed explorer does not enumerate the active directory", explorerView.rootURL == nil)
            explorerView.setActive(true)
            check("opening the explorer follows the active directory", explorerView.rootURL == root.standardizedFileURL)
            let tree = descendants(explorerView).compactMap { $0 as? NSOutlineView }.first!
            check("the project root loads asynchronously", wait { row(named: "file2.txt", in: tree) != nil })
            var opened: URL?
            explorerView.onOpenFile = { opened = $0 }
            if let index = row(named: "file2.txt", in: tree) {
                tree.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                _ = tree.sendAction(tree.doubleAction, to: tree.target)
            }
            check("file activation routes to the internal editor callback", opened == file)
            explorerView.useDirectory(sources)
            explorerView.follow(directory: root.path)
            check("a chosen project folder remains pinned", explorerView.rootURL == sources.standardizedFileURL && !explorerView.followsActiveSession)
            explorerView.useDirectory(nil)
            check("follow current session restores automatic navigation", explorerView.rootURL == root.standardizedFileURL && explorerView.followsActiveSession)
            explorerView.setActive(false)
            explorerView.follow(directory: sources.path)
            check("hidden explorer defers directory changes", explorerView.rootURL == root.standardizedFileURL)
            explorerView.setActive(true)
            check("reopening catches up with the current directory", explorerView.rootURL == sources.standardizedFileURL)
            explorerView.follow(directory: root.path)
            explorerView.follow(directory: sources.path)
            check("late directory reads cannot replace the latest root", wait { explorerView.rootURL == sources.standardizedFileURL && row(named: "No visible files", in: tree) != nil })

            let editorView = FileEditorView(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
            editorView.open(file)
            check("the embedded editor loads local text asynchronously", wait { editorView.document?.url == file && !editorView.isBusy })
            let text = descendants(editorView).compactMap { $0 as? NSTextView }.first!
            text.string = "saved in editor\n"
            check("editing marks the document dirty", editorView.hasUnsavedChanges)
            var saved = false
            editorView.save { saved = $0 }
            check("the embedded editor save clears the dirty state", wait { saved && !editorView.hasUnsavedChanges })
            check("the embedded editor writes the displayed buffer", try String(contentsOf: file, encoding: .utf8) == "saved in editor\n")
            text.string = "unsaved buffer"
            var allowed = true
            editorView.prepareToLeave { allowed = $0 }
            check("dirty documents cannot be discarded without confirmation", !allowed && editorView.hasUnsavedChanges)
            let explorerChord = AppShortcut.Chord(command: true, option: true, shift: false, control: false, key: "e", keyCode: 14)
            let saveChord = AppShortcut.Chord(command: true, option: false, shift: false, control: false, key: "s", keyCode: 1)
            check("project explorer shortcut remains owned by the app", AppShortcut.owns(explorerChord))
            check("save is routed to the embedded editor instead of the terminal", AppShortcut.owns(saveChord))
        } catch {
            check("project explorer fixture and editor checks (\(error))", false)
        }
    }

    private static func fails(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    private static func wait(_ predicate: () -> Bool) -> Bool {
        let until = Date(timeIntervalSinceNow: 3)
        while !predicate() && Date() < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return predicate()
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func row(named name: String, in tree: NSOutlineView) -> Int? {
        (0..<tree.numberOfRows).first { index in
            (tree.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == name
        }
    }
}
