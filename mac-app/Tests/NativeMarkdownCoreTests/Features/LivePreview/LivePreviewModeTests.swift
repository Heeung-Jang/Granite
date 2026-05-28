import Testing
@testable import NativeMarkdownCore

@Test
func livePreviewModeHasStableDisplayAndStatusText() {
    #expect(LivePreviewMode.livePreview.displayName == "Live Preview")
    #expect(LivePreviewMode.livePreview.statusText == nil)
    #expect(LivePreviewMode.source.displayName == "Source")
    #expect(LivePreviewMode.source.statusText == "Source mode")

    let fallback = LivePreviewMode.fallbackSource(reason: .fileTooLarge)
    #expect(fallback.displayName == "Source")
    #expect(fallback.statusText == "Live Preview fallback: file is over the safe size limit")
    #expect(fallback.rendersSourceOnly)
}

@Test
func livePreviewFallbackMessagesDoNotExposePrivatePaths() throws {
    for reason in EditorDegradationReason.allCases {
        let message = try #require(LivePreviewMode.fallbackSource(reason: reason).statusText)

        #expect(!message.contains("/"))
        #expect(!message.contains("Users"))
        #expect(!message.contains("Codex Vault"))
    }
}

@Test
func livePreviewFallbackControllerFallsBackImmediatelyForStructuralBreaches() {
    var controller = LivePreviewFallbackController()

    let mode = controller.observe(.degradedSource(reason: .fileTooLarge))

    #expect(mode == .fallbackSource(reason: .fileTooLarge))
    #expect(controller.mode == .fallbackSource(reason: .fileTooLarge))
    #expect(controller.consecutiveTransientBreaches == 0)
}

@Test
func livePreviewFallbackControllerRequiresRepeatedTransientBreaches() {
    var controller = LivePreviewFallbackController(requiredConsecutiveTransientBreaches: 2)

    #expect(controller.observe(.degradedSource(reason: .visibleRenderTooSlow)) == .livePreview)
    #expect(controller.consecutiveTransientBreaches == 1)
    #expect(controller.observe(.decoratedSource) == .livePreview)
    #expect(controller.consecutiveTransientBreaches == 0)
    #expect(controller.observe(.degradedSource(reason: .visibleRenderTooSlow)) == .livePreview)
    #expect(controller.observe(.degradedSource(reason: .visibleRenderTooSlow)) == .fallbackSource(reason: .visibleRenderTooSlow))
}

@Test
func livePreviewFallbackControllerReturnsOnlyOnManualRetryOrReopen() {
    var controller = LivePreviewFallbackController()
    controller.observe(.degradedSource(reason: .fileTooLarge))

    #expect(controller.observe(.decoratedSource) == .fallbackSource(reason: .fileTooLarge))
    #expect(controller.retryLivePreview() == .livePreview)
    controller.observe(.degradedSource(reason: .fileTooLarge))
    #expect(controller.reopenInLivePreview() == .livePreview)
}

@Test
func livePreviewManualSourceModeDoesNotMutateSaveSessionState() {
    let file = FileTreeItem(relativePath: "Note.md")
    var session = EditorSaveSession(file: file, contents: "original")
    session.completeBaseline(EngineSaveBaseline(
        relativePath: file.relativePath,
        fileIdentity: EngineFileIdentity(device: 1, inode: 2),
        sizeBytes: 8,
        modified: EngineSystemTime(secsSinceUnixEpoch: 10, nanos: 20),
        contentHash: "original"
    ))
    session.updateContents("edited")
    let before = session

    var controller = LivePreviewFallbackController()
    controller.selectSourceMode()
    controller.retryLivePreview()
    controller.observe(.degradedSource(reason: .fileTooLarge))

    #expect(session == before)
    #expect(session.isDirty)
    #expect(session.canSave)
}
