import Foundation
import NativeMarkdownCore

@MainActor
final class SummaryCoordinator: @unchecked Sendable {
    private let cache = DocumentSummaryCache()
    private let generatorFactory: @Sendable () -> any DocumentSummaryGenerating
    private var activeKey: DocumentSummaryRequestKey?
    private var refinementTask: Task<Void, Never>?

    init(generatorFactory: @escaping @Sendable () -> any DocumentSummaryGenerating = { SummaryGeneratorFactory.make() }) {
        self.generatorFactory = generatorFactory
    }

    func cancel() {
        activeKey = nil
        refinementTask?.cancel()
        refinementTask = nil
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
                    guard let self else {
                        return false
                    }
                    return self.isFresh(key, appState: appStateBox.appState)
                }
            }
        )
    }

    func summarizeStaged(
        request: DocumentSummaryRequest,
        appState: AppState,
        useCache: Bool = true,
        progress: @escaping @MainActor (SummaryProgressState) -> Void,
        onSnapshot: @escaping @MainActor (String) -> Void,
        onSummary: @escaping @MainActor (DocumentSummary) -> Void
    ) async throws -> DocumentSummary {
        activeKey = request.key
        refinementTask?.cancel()
        refinementTask = nil

        if useCache, let refined = await cache.value(for: request.refinedCacheKey) {
            progress(.refinedComplete)
            onSummary(refined.summary)
            return refined.summary
        }

        let appStateBox = SummaryAppStateBox(appState)
        let fastSummary: DocumentSummary
        if useCache, let cachedFast = await cache.value(for: request.fastCacheKey) {
            fastSummary = cachedFast.summary
            progress(.fastComplete)
        } else {
            let pipeline = DocumentSummaryPipeline(
                generator: generatorFactory(),
                cache: cache
            )
            fastSummary = try await pipeline.summarizeFast(
                request: request,
                useCache: false,
                progress: { state in
                    await MainActor.run {
                        progress(state)
                    }
                },
                onSnapshot: { snapshot in
                    await MainActor.run {
                        onSnapshot(snapshot)
                    }
                },
                isFresh: freshnessCheck(appStateBox: appStateBox)
            )
        }

        onSummary(fastSummary)
        guard fastSummary.metadata.stage == .fast,
              request.limits.shouldRunBackgroundRefinement(sourceByteCount: request.snapshot.byteCount)
        else {
            return fastSummary
        }

        startRefinement(
            request: request,
            appStateBox: appStateBox,
            useCache: useCache,
            progress: progress,
            onSummary: onSummary
        )
        return fastSummary
    }

    private func startRefinement(
        request: DocumentSummaryRequest,
        appStateBox: SummaryAppStateBox,
        useCache: Bool,
        progress: @escaping @MainActor (SummaryProgressState) -> Void,
        onSummary: @escaping @MainActor (DocumentSummary) -> Void
    ) {
        let generatorFactory = generatorFactory
        let cache = cache
        refinementTask = Task.detached { [weak self, appStateBox, generatorFactory, cache] in
            await progress(.refining)
            let pipeline = DocumentSummaryPipeline(
                generator: generatorFactory(),
                cache: cache
            )
            do {
                let refined = try await pipeline.summarize(
                    request: request,
                    useCache: useCache,
                    isFresh: { [weak self, appStateBox] key in
                        guard let self else {
                            return false
                        }
                        return await self.isFreshForRefinement(key, appStateBox: appStateBox)
                    }
                )
                guard let self else {
                    return
                }
                let fresh = await self.isFreshForRefinement(request.key, appStateBox: appStateBox)
                guard fresh else {
                    return
                }
                await onSummary(refined)
                await progress(.refinedComplete)
            } catch SummaryGenerationError.cancelled,
                    SummaryGenerationError.staleRequest {
                return
            } catch is CancellationError {
                return
            } catch {
                guard let self else {
                    return
                }
                let fresh = await self.isFreshForRefinement(request.key, appStateBox: appStateBox)
                if fresh {
                    await progress(.fastComplete)
                }
                return
            }
        }
    }

    private func isFreshForRefinement(
        _ key: DocumentSummaryRequestKey,
        appStateBox: SummaryAppStateBox
    ) -> Bool {
        isFresh(key, appState: appStateBox.appState)
    }

    private func freshnessCheck(appStateBox: SummaryAppStateBox) -> DocumentSummaryPipeline.FreshnessCheck {
        { [weak self, appStateBox] key in
            await MainActor.run {
                guard let self else {
                    return false
                }
                return self.isFresh(key, appState: appStateBox.appState)
            }
        }
    }

    private func isFresh(_ key: DocumentSummaryRequestKey, appState: AppState) -> Bool {
        isFresh(key, appState: Optional(appState))
    }

    private func isFresh(_ key: DocumentSummaryRequestKey, appState: AppState?) -> Bool {
        guard activeKey == key,
              let descriptor = appState?.activeEditorBufferDescriptor
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
    let appState: AppState

    init(_ appState: AppState) {
        self.appState = appState
    }
}
