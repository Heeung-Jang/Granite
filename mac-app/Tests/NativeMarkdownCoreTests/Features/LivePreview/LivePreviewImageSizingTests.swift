import Testing
@testable import NativeMarkdownCore

@Test
func livePreviewImageSizingFitsOriginalInsideEditorWidth() {
    let size = LivePreviewImageSizing.displaySize(
        pixelWidth: 800,
        pixelHeight: 400,
        requestedSize: nil,
        maxWidth: 320
    )

    #expect(size.width == 320)
    #expect(size.height == 160)
}

@Test
func livePreviewImageSizingKeepsSmallOriginalSize() {
    let size = LivePreviewImageSizing.displaySize(
        pixelWidth: 120,
        pixelHeight: 80,
        requestedSize: nil,
        maxWidth: 500
    )

    #expect(size.width == 120)
    #expect(size.height == 80)
}

@Test
func livePreviewImageSizingUsesRequestedWidthWithAspectRatio() {
    let size = LivePreviewImageSizing.displaySize(
        pixelWidth: 1000,
        pixelHeight: 500,
        requestedSize: LivePreviewEmbedSize(width: 200),
        maxWidth: 800
    )

    #expect(size.width == 200)
    #expect(size.height == 100)
}

@Test
func livePreviewImageSizingUsesRequestedWidthAndHeight() {
    let size = LivePreviewImageSizing.displaySize(
        pixelWidth: 1000,
        pixelHeight: 500,
        requestedSize: LivePreviewEmbedSize(width: 200, height: 160),
        maxWidth: 800
    )

    #expect(size.width == 200)
    #expect(size.height == 160)
}

@Test
func livePreviewImageSizingClampsRequestedWidthToEditorWidth() {
    let size = LivePreviewImageSizing.displaySize(
        pixelWidth: 1000,
        pixelHeight: 500,
        requestedSize: LivePreviewEmbedSize(width: 900),
        maxWidth: 300
    )

    #expect(size.width == 300)
    #expect(size.height == 150)
}

