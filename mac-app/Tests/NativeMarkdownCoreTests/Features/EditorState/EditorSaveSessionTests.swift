import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func editorSaveSessionTracksDirtyStateAfterBaseline() {
    let file = FileTreeItem(relativePath: "Home.md")
    var session = EditorSaveSession(file: file, contents: "# Home\n")

    #expect(session.status == .baselinePending)
    #expect(session.canEdit == false)
    #expect(session.canSave == false)

    session.completeBaseline(makeBaseline(relativePath: file.relativePath, hash: "old"))
    #expect(session.status == .clean)
    #expect(session.canEdit)

    session.updateContents("# Home\n\nEdited\n")
    #expect(session.status == .dirty)
    #expect(session.isDirty)
    #expect(session.canSave)
}

@Test
func editorSaveSessionClearsDirtyStateAfterSuccessfulSave() {
    let file = FileTreeItem(relativePath: "Home.md")
    var session = EditorSaveSession(file: file, contents: "before")
    session.completeBaseline(makeBaseline(relativePath: file.relativePath, hash: "old"))
    session.updateContents("after")

    guard let request = session.beginSave() else {
        Issue.record("expected save request")
        return
    }
    #expect(session.status == .saving)

    session.completeSave(
        EngineSaveOutcome(
            baseline: makeBaseline(relativePath: file.relativePath, hash: "new"),
            bytesWritten: UInt64(request.contents.utf8.count)
        ),
        savedContents: request.contents
    )

    #expect(session.status == .clean)
    #expect(session.isDirty == false)
    #expect(session.baseline?.contentHash == "new")
}

@Test
func editorSaveSessionKeepsNewTypingDirtyAfterSaveCompletes() {
    let file = FileTreeItem(relativePath: "Home.md")
    var session = EditorSaveSession(file: file, contents: "before")
    session.completeBaseline(makeBaseline(relativePath: file.relativePath, hash: "old"))
    session.updateContents("first edit")

    guard let request = session.beginSave() else {
        Issue.record("expected save request")
        return
    }
    session.updateContents("second edit")
    session.completeSave(
        EngineSaveOutcome(
            baseline: makeBaseline(relativePath: file.relativePath, hash: "new"),
            bytesWritten: UInt64(request.contents.utf8.count)
        ),
        savedContents: request.contents
    )

    #expect(session.status == .dirty)
    #expect(session.savedContents == "first edit")
    #expect(session.currentContents == "second edit")
    #expect(session.canSave)
}

@Test
func editorSaveSessionPreservesDirtyBufferAfterConflict() {
    let file = FileTreeItem(relativePath: "Home.md")
    var session = EditorSaveSession(file: file, contents: "before")
    session.completeBaseline(makeBaseline(relativePath: file.relativePath, hash: "old"))
    session.updateContents("after")
    _ = session.beginSave()

    session.failSave(EngineSaveClientError.engine(EngineSaveErrorPayload(
        code: "save_conflict",
        message: "changed outside app",
        conflictKind: "ContentChanged"
    )))

    #expect(session.isDirty)
    #expect(session.currentContents == "after")
    #expect(session.canSave)
    #expect(session.status == .failed(EditorSaveFailure(
        title: "External Change Detected",
        message: "changed outside app",
        conflictKind: "ContentChanged"
    )))
}

@Test
func editorSaveSessionAppliesReloadOutcomeAsCleanDiskState() {
    let file = FileTreeItem(relativePath: "Home.md")
    var session = EditorSaveSession(file: file, contents: "before")
    session.completeBaseline(makeBaseline(relativePath: file.relativePath, hash: "old"))
    session.updateContents("dirty buffer")
    _ = session.beginSave()
    session.failSave(EngineSaveClientError.engine(EngineSaveErrorPayload(
        code: "save_conflict",
        message: "changed outside app",
        conflictKind: "ContentChanged",
        conflict: makeConflict(relativePath: file.relativePath)
    )))

    session.completeReload(EngineSaveReloadOutcome(
        baseline: makeBaseline(relativePath: file.relativePath, hash: "external"),
        contents: "external contents",
        queuedItem: makeQueuedItem(relativePath: file.relativePath),
        dirty: false
    ))

    #expect(session.status == .clean)
    #expect(session.isDirty == false)
    #expect(session.currentContents == "external contents")
    #expect(session.savedContents == "external contents")
    #expect(session.conflict == nil)
}

@Test
func editorSaveSessionAppliesOverwriteChoiceForSavedSnapshotOnly() {
    let file = FileTreeItem(relativePath: "Home.md")
    var session = EditorSaveSession(file: file, contents: "before")
    session.completeBaseline(makeBaseline(relativePath: file.relativePath, hash: "old"))
    session.updateContents("first edit")
    let savedSnapshot = session.beginSave()?.contents ?? ""
    session.updateContents("second edit")

    session.completeChoice(
        EngineSaveChoiceOutcome(
            choice: "Overwrite",
            baseline: makeBaseline(relativePath: file.relativePath, hash: "saved"),
            bytesWritten: UInt64(savedSnapshot.utf8.count),
            queuedItem: makeQueuedItem(relativePath: file.relativePath),
            dirty: false
        ),
        savedContents: savedSnapshot
    )

    #expect(session.status == .dirty)
    #expect(session.savedContents == "first edit")
    #expect(session.currentContents == "second edit")
}

private func makeBaseline(relativePath: String, hash: String) -> EngineSaveBaseline {
    EngineSaveBaseline(
        relativePath: relativePath,
        fileIdentity: EngineFileIdentity(device: 1, inode: 2),
        sizeBytes: 6,
        modified: EngineSystemTime(secsSinceUnixEpoch: 10, nanos: 20),
        contentHash: hash
    )
}

private func makeQueuedItem(relativePath: String) -> EngineQueuedSaveItem {
    EngineQueuedSaveItem(
        relativePath: relativePath,
        generation: 1,
        reason: "OwnSave",
        status: "Pending"
    )
}

private func makeConflict(relativePath: String) -> EngineSaveConflict {
    EngineSaveConflict(
        relativePath: relativePath,
        kind: "ContentChanged",
        expected: makeBaseline(relativePath: relativePath, hash: "old"),
        actual: EngineSaveConflictSnapshot(
            fileIdentity: EngineFileIdentity(device: 1, inode: 2),
            sizeBytes: 12,
            modified: EngineSystemTime(secsSinceUnixEpoch: 11, nanos: 22),
            contentHash: "external"
        )
    )
}
