import Foundation
import NativeMarkdownCore

@MainActor
final class SummaryCoordinator: @unchecked Sendable {
    private let cache = DocumentSummaryCache()
    private let generatorFactory: @Sendable () -> any DocumentSummaryGenerating
    private var activeKey: DocumentSummaryRequestKey?

    init(generatorFactory: @escaping @Sendable () -> any DocumentSummaryGenerating = { SummaryGeneratorFactory.make() }) {
        self.generatorFactory = generatorFactory
    }

    func cancel() {
        activeKey = nil
    }

    func request(appState: AppState, file: FileTreeItem) throws -> DocumentSummaryRequest {
        guard let descriptor = appState.activeEditorBufferDescriptor,
              descriptor.fileID == file.id
        else {
            throw SummaryGenerationError.editorNotReady
        }
        guard let snapshot = appState.snapshotForActiveEditor(
            expectedOwnerID: descriptor.ownerID,
            tabID: descriptor.tabID,
            fileID: descriptor.fileID
        ) else {
            throw SummaryGenerationError.editorNotReady
        }
        return DocumentSummaryRequest(snapshot: snapshot)
    }

    func summarize(
        request: DocumentSummaryRequest,
        appState: AppState,
        useCache: Bool = true,
        progress: @escaping @MainActor (SummaryProgressState) -> Void
    ) async throws -> DocumentSummary {
        activeKey = request.key
        let appStateBox = SummaryAppStateBox(appState)
        let pipeline = DocumentSummaryPipeline(
            generator: generatorFactory(),
            cache: cache
        )
        return try await pipeline.summarize(
            request: request,
            useCache: useCache,
            progress: { state in
                await MainActor.run {
                    progress(state)
                }
            },
            isFresh: { [weak self, appStateBox] key in
                await MainActor.run {
                    guard let self,
                          let appState = appStateBox.appState
                    else {
                        return false
                    }
                    return self.isFresh(key, appState: appState)
                }
            }
        )
    }

    private func isFresh(_ key: DocumentSummaryRequestKey, appState: AppState) -> Bool {
        guard activeKey == key,
              let descriptor = appState.activeEditorBufferDescriptor
        else {
            return false
        }
        return descriptor.vaultID == key.vaultID
            && descriptor.fileID == key.fileID
            && descriptor.tabID == key.tabID
            && descriptor.ownerID == key.ownerID
            && descriptor.revision == key.bufferRevision
    }
}

private final class SummaryAppStateBox: @unchecked Sendable {
    weak var appState: AppState?

    init(_ appState: AppState) {
        self.appState = appState
    }
}
