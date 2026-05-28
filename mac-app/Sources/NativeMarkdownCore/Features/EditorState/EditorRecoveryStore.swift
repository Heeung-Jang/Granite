import Foundation

public struct EditorRecoverySnapshot: Codable, Equatable, Sendable {
    public let relativePath: String
    public let contents: String

    public init(relativePath: String, contents: String) {
        self.relativePath = relativePath
        self.contents = contents
    }
}

public struct EditorRecoveryStore: Sendable {
    public let recoveryDirectory: URL

    private var snapshotFile: URL {
        recoveryDirectory.appendingPathComponent("current-editor.json", isDirectory: false)
    }

    public init(dataDirectory: URL) {
        recoveryDirectory = dataDirectory.appendingPathComponent("editor-recovery", isDirectory: true)
    }

    public func writeSnapshot(file: FileTreeItem, contents: String) throws {
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
        let snapshot = EditorRecoverySnapshot(relativePath: file.relativePath, contents: contents)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotFile, options: .atomic)
    }

    public func loadSnapshot(for file: FileTreeItem) throws -> EditorRecoverySnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotFile.path) else {
            return nil
        }
        let data = try Data(contentsOf: snapshotFile)
        let snapshot = try JSONDecoder().decode(EditorRecoverySnapshot.self, from: data)
        guard snapshot.relativePath == file.relativePath else {
            return nil
        }
        return snapshot
    }

    public func clearSnapshot(for file: FileTreeItem) throws {
        guard try loadSnapshot(for: file) != nil else {
            return
        }
        try FileManager.default.removeItem(at: snapshotFile)
    }
}
