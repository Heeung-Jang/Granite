import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func noteDocumentLoaderReadsUtf8Markdown() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try write("# Home\n", to: vaultURL.appendingPathComponent("Home.md"))

    let document = try FileSystemNoteDocumentLoader().loadNote(
        at: vaultURL,
        file: FileTreeItem(relativePath: "Home.md")
    )

    #expect(document.contents == "# Home\n")
    #expect(document.file.relativePath == "Home.md")
}

@Test
func noteDocumentLoaderRejectsOutsideVaultRelativePath() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    #expect(throws: NoteDocumentLoadError.invalidRelativePath("../Outside.md")) {
        try FileSystemNoteDocumentLoader().loadNote(
            at: vaultURL,
            file: FileTreeItem(relativePath: "../Outside.md")
        )
    }
}

@Test
func noteDocumentLoaderReportsMissingFile() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

    #expect(throws: NoteDocumentLoadError.missing("Missing.md")) {
        try FileSystemNoteDocumentLoader().loadNote(
            at: vaultURL,
            file: FileTreeItem(relativePath: "Missing.md")
        )
    }
}

@Test
func noteDocumentLoaderRejectsSymlinkEscape() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let vaultURL = temporaryRoot.appendingPathComponent("vault", isDirectory: true)
    let outsideURL = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    try write("# Outside\n", to: outsideURL.appendingPathComponent("Outside.md"))
    try FileManager.default.createSymbolicLink(
        at: vaultURL.appendingPathComponent("Link.md"),
        withDestinationURL: outsideURL.appendingPathComponent("Outside.md")
    )

    #expect(throws: NoteDocumentLoadError.outsideVault("Link.md")) {
        try FileSystemNoteDocumentLoader().loadNote(
            at: vaultURL,
            file: FileTreeItem(relativePath: "Link.md")
        )
    }
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
