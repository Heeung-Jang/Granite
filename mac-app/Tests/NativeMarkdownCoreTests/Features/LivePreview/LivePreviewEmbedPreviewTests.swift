import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func livePreviewEmbedParserKeepsSourceRangesAndSizing() throws {
    let source = """
    ![[image.png|100]]
    ![[wide.png|640x480]]
    ![Alt](nested/photo.jpg)
    """

    let spans = LivePreviewEmbedParser.parse(source)

    #expect(spans.count == 3)
    #expect(spans[0].rawTarget == "image.png")
    #expect(spans[0].requestedSize == LivePreviewEmbedSize(width: 100))
    #expect(spans[1].rawTarget == "wide.png")
    #expect(spans[1].requestedSize == LivePreviewEmbedSize(width: 640, height: 480))
    #expect(spans[2].source == .markdownImage)
    #expect(spans[2].rawTarget == "nested/photo.jpg")
    #expect(string(for: spans[0].targetRange, in: source) == "image.png")
}

@Test
func livePreviewEmbedPreviewMapConsumesGateStatesWithoutMarkdownLinks() {
    let source = """
    ![[image.png|100]]
    [attachment](file.pdf)
    ![[missing.png]]
    ![[Note]]
    ![[doc.pdf]]
    """
    let references = [
        AttachmentReferenceItem(
            id: "0-wikiEmbed-image.png",
            source: .wikiEmbed,
            rawTarget: "image.png",
            state: .resolved(FileTreeItem(relativePath: "image.png"))
        ),
        AttachmentReferenceItem(
            id: "1-markdownLink-file.pdf",
            source: .markdownLink,
            rawTarget: "file.pdf",
            state: .resolved(FileTreeItem(relativePath: "file.pdf"))
        ),
        AttachmentReferenceItem(
            id: "2-wikiEmbed-missing.png",
            source: .wikiEmbed,
            rawTarget: "missing.png",
            state: .missing
        ),
        AttachmentReferenceItem(
            id: "3-wikiEmbed-Note",
            source: .wikiEmbed,
            rawTarget: "Note",
            state: .unsupported
        ),
        AttachmentReferenceItem(
            id: "4-wikiEmbed-doc.pdf",
            source: .wikiEmbed,
            rawTarget: "doc.pdf",
            state: .resolved(FileTreeItem(relativePath: "doc.pdf"))
        )
    ]
    let states: [String: AttachmentPreviewState] = [
        references[0].id: .eligible(AttachmentPreviewInfo(
            file: FileTreeItem(relativePath: "image.png"),
            url: URL(fileURLWithPath: "/tmp/vault/image.png"),
            byteSize: 68,
            pixelWidth: 1,
            pixelHeight: 1
        )),
        references[2].id: .blocked(.missing),
        references[3].id: .blocked(.unsupportedResolution),
        references[4].id: .blocked(.unsupportedType)
    ]
    let plan = LivePreviewEmbedPreviewPlan(source: source, references: references)
    let map = plan.previewMap(previewStatesByID: states)
    let blocks = LivePreviewParser.parse(source).blocks.filter { $0.kind == .embed }

    #expect(map.preview(for: blocks[0])?.status == .imageReady)
    #expect(map.preview(for: blocks[0])?.previewInfo?.url.path == "/tmp/vault/image.png")
    #expect(map.preview(for: blocks[0])?.span.requestedSize == LivePreviewEmbedSize(width: 100))
    #expect(map.preview(for: blocks[1])?.status == .blocked(.missing))
    #expect(map.preview(for: blocks[2])?.status == .nonImage)
    #expect(map.preview(for: blocks[3])?.status == .nonImage)
}

@Test
func livePreviewEmbedPreviewMapKeepsBlockEmbedOrderAfterFrontmatterAndInlineImages() {
    let source = """
    ---
    cover: ![[front.png]]
    ---

    Paragraph ![Inline](inline.png)
    ![[block.png|100]]
    """
    let references = [
        AttachmentReferenceItem(
            id: "0-markdownImage-inline.png",
            source: .markdownImage,
            rawTarget: "inline.png",
            state: .resolved(FileTreeItem(relativePath: "inline.png"))
        ),
        AttachmentReferenceItem(
            id: "1-wikiEmbed-block.png",
            source: .wikiEmbed,
            rawTarget: "block.png",
            state: .resolved(FileTreeItem(relativePath: "block.png"))
        )
    ]
    let states: [String: AttachmentPreviewState] = [
        references[0].id: .blocked(.missing),
        references[1].id: .eligible(AttachmentPreviewInfo(
            file: FileTreeItem(relativePath: "block.png"),
            url: URL(fileURLWithPath: "/tmp/vault/block.png"),
            byteSize: 68,
            pixelWidth: 320,
            pixelHeight: 240
        ))
    ]
    let plan = LivePreviewEmbedPreviewPlan(source: source, references: references)
    let map = plan.previewMap(previewStatesByID: states)
    let blocks = LivePreviewParser.parse(source).blocks.filter { $0.kind == .embed }

    #expect(blocks.count == 1)
    #expect(plan.referenceIDs == [references[1].id])
    #expect(map.preview(for: blocks[0])?.span.rawTarget == "block.png")
    #expect(map.preview(for: blocks[0])?.status == .imageReady)
    #expect(map.preview(for: blocks[0])?.previewInfo?.pixelWidth == 320)
    #expect(map.preview(for: blocks[0])?.span.requestedSize == LivePreviewEmbedSize(width: 100))
}

@Test
func livePreviewEmbedPreviewPlanMatchesReferencesByTargetInsteadOfIndex() {
    let source = """
    ![[evil.png
    ]]
    ![[safe.png]]
    """
    let references = [
        AttachmentReferenceItem(
            id: "0-wikiEmbed-evil.png",
            source: .wikiEmbed,
            rawTarget: "evil.png",
            state: .resolved(FileTreeItem(relativePath: "evil.png"))
        ),
        AttachmentReferenceItem(
            id: "1-wikiEmbed-safe.png",
            source: .wikiEmbed,
            rawTarget: "safe.png",
            state: .missing
        )
    ]
    let states: [String: AttachmentPreviewState] = [
        references[0].id: .eligible(AttachmentPreviewInfo(
            file: FileTreeItem(relativePath: "evil.png"),
            url: URL(fileURLWithPath: "/tmp/vault/evil.png"),
            byteSize: 68,
            pixelWidth: 1,
            pixelHeight: 1
        )),
        references[1].id: .blocked(.missing)
    ]
    let plan = LivePreviewEmbedPreviewPlan(source: source, references: references)
    let map = plan.previewMap(previewStatesByID: states)
    let blocks = LivePreviewParser.parse(source).blocks.filter { $0.kind == .embed }
    let previewBlocks = blocks.filter { map.preview(for: $0) != nil }

    #expect(plan.referenceIDs == [references[1].id])
    #expect(previewBlocks.count == 1)
    #expect(map.preview(for: previewBlocks[0])?.span.rawTarget == "safe.png")
    #expect(map.preview(for: previewBlocks[0])?.status == .blocked(.missing))
}

@Test
func livePreviewMetadataFreshnessRejectsStaleContents() {
    #expect(LivePreviewMetadataFreshness.accepts(candidateContents: "A", currentContents: "A"))
    #expect(!LivePreviewMetadataFreshness.accepts(candidateContents: "A", currentContents: "B"))
}

private func string(for sourceRange: LivePreviewSourceRange, in source: String) -> String? {
    guard let range = LivePreviewRangeMapper.stringRange(for: sourceRange, in: source) else {
        return nil
    }
    return String(source[range])
}
