import Foundation

public struct NoteDocument: Equatable, Sendable {
    public let file: FileTreeItem
    public let contents: String

    public init(file: FileTreeItem, contents: String) {
        self.file = file
        self.contents = contents
    }
}

public protocol NoteDocumentLoading: Sendable {
    func loadNote(at vaultURL: URL, file: FileTreeItem) throws -> NoteDocument
}

public enum NoteDocumentLoadError: Error, Equatable {
    case invalidRelativePath(String)
    case outsideVault(String)
    case missing(String)
    case unreadable(String)
    case unsupportedEncoding(String)
}

public struct FileSystemNoteDocumentLoader: NoteDocumentLoading {
    public init() {}

    public func loadNote(at vaultURL: URL, file: FileTreeItem) throws -> NoteDocument {
        let fileURL = try resolve(file.relativePath, under: vaultURL)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NoteDocumentLoadError.missing(file.relativePath)
        }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw NoteDocumentLoadError.unreadable(file.relativePath)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw NoteDocumentLoadError.unreadable(file.relativePath)
        }

        let contents = String(decoding: data, as: UTF8.self)
        guard Data(contents.utf8) == data else {
            throw NoteDocumentLoadError.unsupportedEncoding(file.relativePath)
        }

        return NoteDocument(file: file, contents: contents)
    }

    private func resolve(_ relativePath: String, under vaultURL: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0")
        else {
            throw NoteDocumentLoadError.invalidRelativePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains(".") else {
            throw NoteDocumentLoadError.invalidRelativePath(relativePath)
        }

        let rootURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = vaultURL
            .standardizedFileURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let rootPath = rootURL.path
        let filePath = fileURL.path
        guard filePath.hasPrefix("\(rootPath)/") else {
            throw NoteDocumentLoadError.outsideVault(relativePath)
        }
        return fileURL
    }
}
