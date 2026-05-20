import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func attachmentPreviewGateAllowsSmallResolvedImagesInsideVault() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = FileTreeItem(relativePath: "attachments/tiny.png")
    try writeTinyPng(to: vaultURL.appendingPathComponent(file.relativePath))

    let state = FileSystemAttachmentPreviewGate().previewState(
        vaultURL: vaultURL,
        reference: reference(state: .resolved(file))
    )

    guard case .eligible(let info) = state else {
        Issue.record("expected eligible preview")
        return
    }
    #expect(info.file == file)
    #expect(info.url.path.hasPrefix(vaultURL.path))
    #expect(info.byteSize > 0)
    #expect(info.pixelWidth == 1)
    #expect(info.pixelHeight == 1)
    #expect(AttachmentPreviewImageDecoder.canDecode(info))
}

@Test
func attachmentPreviewGateBlocksUnsupportedTypesAndRemoteReferences() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let svg = FileTreeItem(relativePath: "attachments/diagram.svg")
    let pdf = FileTreeItem(relativePath: "attachments/spec.pdf")
    let html = FileTreeItem(relativePath: "attachments/page.html")
    try write("<svg></svg>", to: vaultURL.appendingPathComponent(svg.relativePath))
    try write("%PDF-1.7", to: vaultURL.appendingPathComponent(pdf.relativePath))
    try write("<html></html>", to: vaultURL.appendingPathComponent(html.relativePath))

    let gate = FileSystemAttachmentPreviewGate()

    #expect(gate.previewState(vaultURL: vaultURL, reference: reference(state: .resolved(svg))) == .blocked(.unsupportedType))
    #expect(gate.previewState(vaultURL: vaultURL, reference: reference(state: .resolved(pdf))) == .blocked(.unsupportedType))
    #expect(gate.previewState(vaultURL: vaultURL, reference: reference(state: .resolved(html))) == .blocked(.unsupportedType))
    #expect(gate.previewState(vaultURL: vaultURL, reference: reference(state: .remote)) == .blocked(.remote))
    #expect(gate.previewState(vaultURL: vaultURL, reference: reference(state: .rejected(.outsideVault))) == .blocked(.rejected))
}

@Test
func attachmentPreviewGateBlocksOversizedFilesAndDimensions() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let file = FileTreeItem(relativePath: "attachments/tiny.png")
    try writeTinyPng(to: vaultURL.appendingPathComponent(file.relativePath))
    let gate = FileSystemAttachmentPreviewGate()
    let resolved = reference(state: .resolved(file))

    #expect(gate.previewState(
        vaultURL: vaultURL,
        reference: resolved,
        policy: AttachmentPreviewPolicy(maxFileSizeBytes: 1)
    ) == .blocked(.fileTooLarge))

    #expect(gate.previewState(
        vaultURL: vaultURL,
        reference: resolved,
        policy: AttachmentPreviewPolicy(maxDimensionPixels: 0)
    ) == .blocked(.dimensionsTooLarge))
}

@Test
func attachmentPreviewGateRejectsResolvedSymlinkEscapes() throws {
    let vaultURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outsideURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: false)
    try writeTinyPng(to: outsideURL)

    let file = FileTreeItem(relativePath: "attachments/link.png")
    let linkURL = vaultURL.appendingPathComponent(file.relativePath)
    try FileManager.default.createDirectory(
        at: linkURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        atPath: linkURL.path,
        withDestinationPath: outsideURL.path
    )

    let state = FileSystemAttachmentPreviewGate().previewState(
        vaultURL: vaultURL,
        reference: reference(state: .resolved(file))
    )

    #expect(state == .blocked(.outsideVault))
}

private func reference(state: AttachmentResolutionState) -> AttachmentReferenceItem {
    AttachmentReferenceItem(
        id: "test",
        source: .wikiEmbed,
        rawTarget: "test",
        state: state
    )
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private func writeTinyPng(to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
    try data.write(to: url)
}
