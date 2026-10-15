import Foundation

struct ProjectEntry: Equatable {
    let url: URL
    let isDirectory: Bool
    let isSymbolicLink: Bool

    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

enum ProjectFiles {
    static func children(of directory: URL, showHidden: Bool) throws -> [ProjectEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory.resolvingSymlinksInPath(),
            includingPropertiesForKeys: Array(keys),
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            let link = values.isSymbolicLink == true
            return ProjectEntry(
                url: directory.appendingPathComponent(url.lastPathComponent, isDirectory: values.isDirectory == true && !link && values.isPackage != true),
                isDirectory: values.isDirectory == true && !link && values.isPackage != true,
                isSymbolicLink: link
            )
        }.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

enum WorkspaceLayout {
    static func minimumWidth(tabSidebarWidth: CGFloat, explorer: Bool, editor: Bool) -> CGFloat {
        let separators = (tabSidebarWidth > 0 ? 1.0 : 0) + (explorer ? 1 : 0) + (editor ? 1 : 0)
        return max(640, tabSidebarWidth + (explorer ? 180 : 0) + (editor ? 300 : 0) + 240 + separators)
    }

    static func widths(windowWidth: CGFloat, tabSidebarWidth: CGFloat, explorer: Bool, editor: Bool) -> (explorer: CGFloat, editor: CGFloat) {
        let separators = (tabSidebarWidth > 0 ? 1.0 : 0) + (explorer ? 1 : 0) + (editor ? 1 : 0)
        let available = max(0, windowWidth - tabSidebarWidth - separators - 240)
        let editorWidth = editor ? min(420, max(0, available - (explorer ? 180 : 0))) : 0
        let explorerWidth = explorer ? min(260, max(0, available - editorWidth)) : 0
        return (explorerWidth, editorWidth)
    }
}

enum ProjectExplorerMemory {
    static let visibleKey = "BoomeProjectExplorerVisible"
    static let directoryKey = "BoomeProjectExplorerDirectory"
    static let hiddenFilesKey = "BoomeProjectExplorerHiddenFiles"
}
