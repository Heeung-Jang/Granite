import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func sourcePreservationLoaderKeepsExactUTF8BytesForLivePreviewSeeds() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: vaultURL)
    }

    let cases = [
        "\u{FEFF}# Heading\r\n\r\nText with CRLF.\r\n",
        "---\ntitle: Fixture\nhtml: \"<script>nope</script>\"\n---\n# Body\n",
        "| Name | Status |\n| --- | --- |\n| Alpha | Draft |\n",
        "![[attachments/safe-pixel.png|64x64]]\n",
        "![[../../secret.png]]\n![[/etc/passwd]]\n",
        "[File](file:///tmp/secret.md)\n[JS](javascript:alert(1))\n![Data](data:image/png;base64,AAAA)\n",
        "Unclosed **bold and [[wikilink\n",
        "Korean text: 안녕하세요 #상태/검토\n",
        "Emoji text: note 📝 with combining e\u{301}\n",
        "Final newline is preserved.\n"
    ]

    for (index, source) in cases.enumerated() {
        let relativePath = "Seed-\(index).md"
        let fileURL = vaultURL.appendingPathComponent(relativePath, isDirectory: false)
        try writeUTF8(source, to: fileURL)

        let document = try FileSystemNoteDocumentLoader().loadNote(
            at: vaultURL,
            file: FileTreeItem(relativePath: relativePath)
        )

        #expect(document.contents == source)
        #expect(document.contents.data(using: .utf8) == source.data(using: .utf8))
    }
}

@Test
func sourcePreservationLoaderRejectsInvalidUTF8Bytes() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: vaultURL)
    }
    let fileURL = vaultURL.appendingPathComponent("Invalid.md", isDirectory: false)
    try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    try Data([0x66, 0x80, 0x67]).write(to: fileURL)

    #expect(throws: NoteDocumentLoadError.unsupportedEncoding("Invalid.md")) {
        try FileSystemNoteDocumentLoader().loadNote(
            at: vaultURL,
            file: FileTreeItem(relativePath: "Invalid.md")
        )
    }
}

private func writeUTF8(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}
