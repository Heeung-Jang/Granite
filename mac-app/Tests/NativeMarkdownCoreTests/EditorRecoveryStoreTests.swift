import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func editorRecoveryStoreWritesLoadsAndClearsCurrentSnapshot() throws {
    let dataDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EditorRecoveryStore(dataDirectory: dataDirectory)
    let file = FileTreeItem(relativePath: "Notes/Draft.md")

    try store.writeSnapshot(file: file, contents: "unsaved draft")

    #expect(store.recoveryDirectory.path.hasPrefix(dataDirectory.path))
    #expect(try store.loadSnapshot(for: file) == EditorRecoverySnapshot(
        relativePath: file.relativePath,
        contents: "unsaved draft"
    ))

    try store.clearSnapshot(for: file)

    #expect(try store.loadSnapshot(for: file) == nil)
}

@Test
func editorRecoveryStoreIgnoresSnapshotsForOtherFiles() throws {
    let dataDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = EditorRecoveryStore(dataDirectory: dataDirectory)

    try store.writeSnapshot(file: FileTreeItem(relativePath: "Notes/One.md"), contents: "draft")

    #expect(try store.loadSnapshot(for: FileTreeItem(relativePath: "Notes/Two.md")) == nil)
}
