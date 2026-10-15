import Foundation

enum TextFileError: LocalizedError {
    case notRegularFile, tooLarge, notUTF8, changedOnDisk

    var errorDescription: String? {
        switch self {
        case .notRegularFile: "Only regular text files can be edited. Use Open Externally for folders and other file types."
        case .tooLarge: "This file exceeds the editor's 2 MB limit. Use Open Externally to open it in another application."
        case .notUTF8: "This is a binary file or is not UTF-8 text. Use Open Externally to open it in another application."
        case .changedOnDisk: "The file changed outside Boome. Your edits have not overwritten it."
        }
    }
}

struct ProjectTextFile {
    static let maximumBytes = 2 * 1024 * 1024
    let url: URL
    private let storageURL: URL
    private(set) var savedText: String
    private var savedData: Data
    private let bom: Bool
    let lineEnding: String

    static func read(_ url: URL) throws -> ProjectTextFile {
        let storage = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw TextFileError.notRegularFile }
        let handle = try FileHandle(forReadingFrom: storage)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw TextFileError.tooLarge }
        guard !data.contains(0), var text = String(data: data, encoding: .utf8) else { throw TextFileError.notUTF8 }
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let ending = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return ProjectTextFile(url: url, storageURL: storage, savedText: text, savedData: data, bom: bom, lineEnding: ending)
    }

    mutating func save(_ text: String, overwrite: Bool = false) throws {
        guard url.resolvingSymlinksInPath() == storageURL else { throw TextFileError.changedOnDisk }
        if !overwrite {
            let handle = try FileHandle(forReadingFrom: storageURL)
            defer { try? handle.close() }
            let current = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard current == savedData else { throw TextFileError.changedOnDisk }
        }
        let encoded = (bom ? "\u{feff}" : "") + text.replacingOccurrences(of: "\n", with: lineEnding)
        guard let data = encoded.data(using: .utf8) else { throw TextFileError.notUTF8 }
        guard data.count <= Self.maximumBytes else { throw TextFileError.tooLarge }
        try data.write(to: storageURL, options: .atomic)
        savedData = data
        savedText = text
    }
}
