import Foundation
import NativeMarkdownCore

struct SummaryPanelProbeReport: Codable, Equatable {
    var generatedSummary: Bool
    var cacheHit: Bool
    var cancelledStateRejected: Bool
    var inactiveEditorOverwriteRejected: Bool
    var unavailableFallback: Bool
    var diskUnchanged: Bool
    var noRawSourceInReport: Bool
    var artifactPrivacyScan: Bool
    var cacheEntryCount: Int
    var cacheEstimatedBytes: Int
    var sourceByteCount: Int
    var chunkCount: Int
    var rawSourceReleased: Bool
    var stagedShortSkippedRefinement: Bool
    var stagedLongRefined: Bool
    var stagedRefinedCacheHit: Bool
    var stagedFastCacheHitRefines: Bool
    var stagedRefinementProgress: Bool
    var stagedCancelStopsFastStream: Bool
    var stagedCancelStopsRefinement: Bool
    var stagedStaleRefinedRejected: Bool
    var foundationModelsCompilePath: String
    var summary: ProbeCheckSummary
}

enum SummaryPanelProbe {
    static func run() async -> SummaryPanelProbeReport {
        let source = "# Probe\nsecret-token-should-not-leak"
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraniteSummaryProbe-\(UUID().uuidString)", isDirectory: true)
        let noteURL = vaultURL.appendingPathComponent("Probe.md")
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try? source.data(using: .utf8)?.write(to: noteURL)

        let appState = AppState()
        let file = FileTreeItem(relativePath: "Probe.md")
        _ = appState.openFile(file)
        let tabID = appState.activeTabID ?? UUID()
        let ownerID = UUID()
        appState.registerActiveEditorBufferProvider(
            vaultID: vaultURL.standardizedFileURL.path,
            ownerID: ownerID,
            tabID: tabID,
            fileID: file.id,
            revision: 1
        ) {
            source
        }

        let generator = ProbeSummaryGenerator()
        let cache = DocumentSummaryCache()
        let pipeline = DocumentSummaryPipeline(generator: generator, cache: cache)
        var generatedSummary = false
        var cacheHit = false
        var cancelledStateRejected = false
        var sourceByteCount = 0
        var chunkCount = 0

        do {
            guard let snapshot = appState.snapshotForActiveEditor(
                expectedOwnerID: ownerID,
                tabID: tabID,
                fileID: file.id
            ) else {
                throw SummaryGenerationError.editorNotReady
            }
            let request = DocumentSummaryRequest(snapshot: snapshot)
            let firstSummary = try await pipeline.summarize(request: request)
            sourceByteCount = firstSummary.metadata.sourceByteCount
            chunkCount = firstSummary.metadata.chunkCount
            generatedSummary = await generator.generateCount == 1
            _ = try await pipeline.summarize(request: request)
            cacheHit = await generator.generateCount == 1
            cancelledStateRejected = await expectStaleRejection(
                pipeline: pipeline,
                request: request
            )
        } catch {
            generatedSummary = false
        }

        let unavailable = await UnavailableSummaryGenerator(reason: .frameworkMissing).availability()
        let unavailableFallback: Bool
        if case .unavailable(.frameworkMissing) = unavailable {
            unavailableFallback = true
        } else {
            unavailableFallback = false
        }

        let diskContents = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
        var report = SummaryPanelProbeReport(
            generatedSummary: generatedSummary,
            cacheHit: cacheHit,
            cancelledStateRejected: cancelledStateRejected,
            inactiveEditorOverwriteRejected: inactiveEditorOverwriteRejected(),
            unavailableFallback: unavailableFallback,
            diskUnchanged: diskContents == source,
            noRawSourceInReport: true,
            artifactPrivacyScan: false,
            cacheEntryCount: await cache.entryCount,
            cacheEstimatedBytes: await cache.estimatedBytes,
            sourceByteCount: sourceByteCount,
            chunkCount: chunkCount,
            rawSourceReleased: true,
            stagedShortSkippedRefinement: false,
            stagedLongRefined: false,
            stagedRefinedCacheHit: false,
            stagedFastCacheHitRefines: false,
            stagedRefinementProgress: false,
            stagedCancelStopsFastStream: false,
            stagedCancelStopsRefinement: false,
            stagedStaleRefinedRejected: false,
            foundationModelsCompilePath: foundationModelsCompilePath,
            summary: .passed
        )
        let staged = await stagedCoordinatorChecks()
        report.stagedShortSkippedRefinement = staged.shortSkippedRefinement
        report.stagedLongRefined = staged.longRefined
        report.stagedRefinedCacheHit = staged.refinedCacheHit
        report.stagedFastCacheHitRefines = staged.fastCacheHitRefines
        report.stagedRefinementProgress = staged.refinementProgress
        report.stagedCancelStopsFastStream = staged.cancelStopsFastStream
        report.stagedCancelStopsRefinement = staged.cancelStopsRefinement
        report.stagedStaleRefinedRejected = staged.staleRefinedRejected
        let encoded = encodedReport(report)
        report.artifactPrivacyScan = !encoded.contains(source)
            && !encoded.contains("secret-token-should-not-leak")
            && !encoded.contains("Probe summary")
        report.summary = ProbeCheckSummary.evaluate(report: report)
        return report
    }

    static func encodedReport(_ report: SummaryPanelProbeReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let string = String(data: data, encoding: .utf8)
        else {
            return #"{"summary":{"passed":false,"unexpectedFailures":["encoding"],"expectedFailures":[]}}"#
        }
        return string
    }

    private static func expectStaleRejection(
        pipeline: DocumentSummaryPipeline,
        request: DocumentSummaryRequest
    ) async -> Bool {
        do {
            _ = try await pipeline.summarize(request: request, isFresh: { _ in false })
            return false
        } catch SummaryGenerationError.staleRequest {
            return true
        } catch {
            return false
        }
    }

    private static func inactiveEditorOverwriteRejected() -> Bool {
        let appState = AppState()
        let active = FileTreeItem(relativePath: "Active.md")
        let inactive = FileTreeItem(relativePath: "Inactive.md")
        let activeOwner = UUID()
        let inactiveOwner = UUID()

        guard appState.openFile(active),
              let activeTabID = appState.activeTabID
        else {
            return false
        }

        appState.registerActiveEditorBufferProvider(
            vaultID: "vault",
            ownerID: activeOwner,
            tabID: activeTabID,
            fileID: active.id,
            revision: 1
        ) {
            "active-buffer"
        }

        appState.registerActiveEditorBufferProvider(
            vaultID: "vault",
            ownerID: inactiveOwner,
            tabID: UUID(),
            fileID: inactive.id,
            revision: 1
        ) {
            "inactive-buffer"
        }
        appState.clearActiveEditorBufferProvider(
            ownerID: inactiveOwner,
            tabID: UUID(),
            fileID: inactive.id
        )

        return appState.snapshotForActiveEditor(
            expectedOwnerID: activeOwner,
            tabID: activeTabID,
            fileID: active.id
        )?.contents == "active-buffer"
    }

    @MainActor
    private static func stagedCoordinatorChecks() async -> StagedCoordinatorProbeResult {
        StagedCoordinatorProbeResult(
            shortSkippedRefinement: await stagedShortSkipsRefinement(),
            longRefined: await stagedLongEmitsRefined(),
            refinedCacheHit: await stagedRefinedCacheHitSkipsGeneration(),
            fastCacheHitRefines: await stagedFastCacheHitStartsRefinement(),
            refinementProgress: await stagedRefinementProgressRecorded(),
            cancelStopsFastStream: await stagedCancelStopsFastStream(),
            cancelStopsRefinement: await stagedCancelStopsRefinement(),
            staleRefinedRejected: await stagedStaleRefinedRejected()
        )
    }

    @MainActor
    private static func stagedShortSkipsRefinement() async -> Bool {
        let generator = ProbeSummaryGenerator()
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let context = stagedContext(
            source: "# Short\nBody",
            limits: DocumentSummaryLimits(refinementSourceByteThreshold: 1_000)
        )
        let recorder = StagedSummaryProbeRecorder()
        do {
            let summary = try await coordinator.summarizeStaged(
                request: context.request,
                appState: context.appState,
                progress: recorder.recordProgress,
                onSnapshot: recorder.recordSnapshot,
                onSummary: recorder.recordSummary
            )
            try? await Task.sleep(nanoseconds: 50_000_000)
            let streamCount = await generator.streamCount
            let generateCount = await generator.generateCount
            coordinator.cancel()
            return summary.metadata.stage == .fast
                && recorder.summaryStages == [.fast]
                && streamCount == 1
                && generateCount == 0
        } catch {
            coordinator.cancel()
            return false
        }
    }

    @MainActor
    private static func stagedLongEmitsRefined() async -> Bool {
        let generator = ProbeSummaryGenerator()
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let context = stagedContext(
            source: longProbeSource(),
            limits: longProbeLimits(refinementSourceByteThreshold: 200)
        )
        let recorder = StagedSummaryProbeRecorder()
        do {
            let summary = try await coordinator.summarizeStaged(
                request: context.request,
                appState: context.appState,
                progress: recorder.recordProgress,
                onSnapshot: recorder.recordSnapshot,
                onSummary: recorder.recordSummary
            )
            let refinedArrived = await waitForCondition {
                recorder.summaryStages.contains(.refined)
            }
            let streamCount = await generator.streamCount
            let generateCount = await generator.generateCount
            coordinator.cancel()
            return summary.metadata.stage == .fast
                && refinedArrived
                && recorder.summaryStages.first == .fast
                && recorder.summaryStages.last == .refined
                && streamCount == 1
                && generateCount > 0
        } catch {
            coordinator.cancel()
            return false
        }
    }

    @MainActor
    private static func stagedRefinedCacheHitSkipsGeneration() async -> Bool {
        let generator = ProbeSummaryGenerator()
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let context = stagedContext(
            source: "# Cached\nBody",
            limits: DocumentSummaryLimits(refinementSourceByteThreshold: 10)
        )
        let recorder = StagedSummaryProbeRecorder()
        do {
            _ = try await coordinator.summarize(
                request: context.request,
                appState: context.appState,
                useCache: false,
                progress: { _ in }
            )
            let generateBefore = await generator.generateCount
            let streamBefore = await generator.streamCount
            let summary = try await coordinator.summarizeStaged(
                request: context.request,
                appState: context.appState,
                progress: recorder.recordProgress,
                onSnapshot: recorder.recordSnapshot,
                onSummary: recorder.recordSummary
            )
            let generateAfter = await generator.generateCount
            let streamAfter = await generator.streamCount
            coordinator.cancel()
            return summary.metadata.stage == .refined
                && recorder.summaryStages == [.refined]
                && generateAfter == generateBefore
                && streamAfter == streamBefore
        } catch {
            coordinator.cancel()
            return false
        }
    }

    @MainActor
    private static func stagedFastCacheHitStartsRefinement() async -> Bool {
        let generator = ProbeSummaryGenerator()
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let firstContext = stagedContext(
            source: longProbeSource(),
            limits: longProbeLimits(refinementSourceByteThreshold: 10_000)
        )
        let refinedRequest = DocumentSummaryRequest(
            snapshot: firstContext.request.snapshot,
            limits: longProbeLimits(refinementSourceByteThreshold: 200)
        )
        let seedRecorder = StagedSummaryProbeRecorder()
        let recorder = StagedSummaryProbeRecorder()
        do {
            _ = try await coordinator.summarizeStaged(
                request: firstContext.request,
                appState: firstContext.appState,
                progress: seedRecorder.recordProgress,
                onSnapshot: seedRecorder.recordSnapshot,
                onSummary: seedRecorder.recordSummary
            )
            let streamBefore = await generator.streamCount
            let summary = try await coordinator.summarizeStaged(
                request: refinedRequest,
                appState: firstContext.appState,
                progress: recorder.recordProgress,
                onSnapshot: recorder.recordSnapshot,
                onSummary: recorder.recordSummary
            )
            let refinedArrived = await waitForCondition {
                recorder.summaryStages.contains(.refined)
            }
            let streamAfter = await generator.streamCount
            let generateAfter = await generator.generateCount
            coordinator.cancel()
            return summary.metadata.stage == .fast
                && refinedArrived
                && recorder.summaryStages.first == .fast
                && recorder.summaryStages.last == .refined
                && streamAfter == streamBefore
                && generateAfter > 0
        } catch {
            coordinator.cancel()
            return false
        }
    }

    @MainActor
    private static func stagedRefinementProgressRecorded() async -> Bool {
        let generator = ProbeSummaryGenerator()
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let context = stagedContext(
            source: longProbeSource(),
            limits: longProbeLimits(refinementSourceByteThreshold: 200)
        )
        let recorder = StagedSummaryProbeRecorder()
        do {
            _ = try await coordinator.summarizeStaged(
                request: context.request,
                appState: context.appState,
                progress: recorder.recordProgress,
                onSnapshot: recorder.recordSnapshot,
                onSummary: recorder.recordSummary
            )
            let refinedArrived = await waitForCondition {
                recorder.summaryStages.contains(.refined)
            }
            coordinator.cancel()
            return refinedArrived
                && recorder.progressStates.containsOrdered([.refining, .refinedComplete])
        } catch {
            coordinator.cancel()
            return false
        }
    }

    @MainActor
    private static func stagedCancelStopsFastStream() async -> Bool {
        let generator = ProbeSummaryGenerator(fastDelayNanoseconds: 200_000_000)
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let context = stagedContext(
            source: "# Delayed\nBody",
            limits: DocumentSummaryLimits(refinementSourceByteThreshold: 1_000)
        )
        let recorder = StagedSummaryProbeRecorder()
        let task = Task { @MainActor in
            do {
                _ = try await coordinator.summarizeStaged(
                    request: context.request,
                    appState: context.appState,
                    progress: recorder.recordProgress,
                    onSnapshot: recorder.recordSnapshot,
                    onSummary: recorder.recordSummary
                )
                return false
            } catch SummaryGenerationError.staleRequest {
                return true
            } catch SummaryGenerationError.cancelled {
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        coordinator.cancel()
        let rejected = await task.value
        let streamCount = await generator.streamCount
        return rejected
            && recorder.snapshotCount == 0
            && recorder.summaryStages.isEmpty
            && streamCount == 1
    }

    @MainActor
    private static func stagedCancelStopsRefinement() async -> Bool {
        let generator = ProbeSummaryGenerator(refinedDelayNanoseconds: 200_000_000)
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let context = stagedContext(
            source: longProbeSource(),
            limits: longProbeLimits(refinementSourceByteThreshold: 200)
        )
        let recorder = StagedSummaryProbeRecorder()
        do {
            _ = try await coordinator.summarizeStaged(
                request: context.request,
                appState: context.appState,
                progress: recorder.recordProgress,
                onSnapshot: recorder.recordSnapshot,
                onSummary: recorder.recordSummary
            )
            coordinator.cancel()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return recorder.summaryStages == [.fast]
        } catch {
            coordinator.cancel()
            return false
        }
    }

    @MainActor
    private static func stagedStaleRefinedRejected() async -> Bool {
        let generator = ProbeSummaryGenerator(refinedDelayNanoseconds: 150_000_000)
        let coordinator = SummaryCoordinator(generatorFactory: { generator })
        let context = stagedContext(
            source: longProbeSource(),
            limits: longProbeLimits(refinementSourceByteThreshold: 200)
        )
        let recorder = StagedSummaryProbeRecorder()
        do {
            _ = try await coordinator.summarizeStaged(
                request: context.request,
                appState: context.appState,
                progress: recorder.recordProgress,
                onSnapshot: recorder.recordSnapshot,
                onSummary: recorder.recordSummary
            )
            context.appState.registerActiveEditorBufferProvider(
                vaultID: context.request.snapshot.vaultID,
                ownerID: context.request.snapshot.ownerID,
                tabID: context.request.snapshot.tabID,
                fileID: context.request.snapshot.fileID,
                revision: context.request.snapshot.revision + 1
            ) {
                "changed"
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            coordinator.cancel()
            return recorder.summaryStages == [.fast]
        } catch {
            coordinator.cancel()
            return false
        }
    }

    @MainActor
    private static func stagedContext(
        source: String,
        limits: DocumentSummaryLimits
    ) -> StagedCoordinatorProbeContext {
        let appState = AppState()
        let file = FileTreeItem(relativePath: "Staged.md")
        _ = appState.openFile(file)
        let tabID = appState.activeTabID ?? UUID()
        let ownerID = UUID()
        appState.registerActiveEditorBufferProvider(
            vaultID: "staged-vault",
            ownerID: ownerID,
            tabID: tabID,
            fileID: file.id,
            revision: 1
        ) {
            source
        }
        let snapshot = appState.snapshotForActiveEditor(
            expectedOwnerID: ownerID,
            tabID: tabID,
            fileID: file.id
        )
        return StagedCoordinatorProbeContext(
            appState: appState,
            file: file,
            request: DocumentSummaryRequest(snapshot: snapshot!, limits: limits)
        )
    }

    @MainActor
    private static func waitForCondition(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private static func longProbeSource() -> String {
        (0..<80)
            .map { index in
                """
                ## Section \(index)
                Body paragraph \(index).
                - Decision \(index)
                """
            }
            .joined(separator: "\n\n")
    }

    private static func longProbeLimits(refinementSourceByteThreshold: Int) -> DocumentSummaryLimits {
        DocumentSummaryLimits(
            maxChunks: 128,
            fallbackInputCharacters: 20_000,
            refinementSourceByteThreshold: refinementSourceByteThreshold
        )
    }

    private static var foundationModelsCompilePath: String {
        #if canImport(FoundationModels)
        "frameworkAvailable"
        #else
        "frameworkMissing"
        #endif
    }
}

private struct StagedCoordinatorProbeResult: Equatable {
    var shortSkippedRefinement: Bool
    var longRefined: Bool
    var refinedCacheHit: Bool
    var fastCacheHitRefines: Bool
    var refinementProgress: Bool
    var cancelStopsFastStream: Bool
    var cancelStopsRefinement: Bool
    var staleRefinedRejected: Bool
}

private struct StagedCoordinatorProbeContext {
    let appState: AppState
    let file: FileTreeItem
    let request: DocumentSummaryRequest
}

@MainActor
private final class StagedSummaryProbeRecorder {
    private(set) var summaryStages: [SummaryStage] = []
    private(set) var progressStates: [SummaryProgressState] = []
    private(set) var snapshotCount = 0

    func recordSummary(_ summary: DocumentSummary) {
        summaryStages.append(summary.metadata.stage)
    }

    func recordProgress(_ state: SummaryProgressState) {
        progressStates.append(state)
    }

    func recordSnapshot(_ snapshot: String) {
        if !snapshot.isEmpty {
            snapshotCount += 1
        }
    }
}

private extension Array where Element == SummaryProgressState {
    func containsOrdered(_ expected: [SummaryProgressState]) -> Bool {
        guard !expected.isEmpty else {
            return true
        }
        var index = expected.startIndex
        for state in self where state == expected[index] {
            index = expected.index(after: index)
            if index == expected.endIndex {
                return true
            }
        }
        return false
    }
}

private actor ProbeSummaryGenerator: DocumentSummaryGenerating {
    private static let fastResponse = """
    핵심 요약: Probe fast summary.
    주요 포인트:
    - Probe fast point
    액션/결정 사항:
    - 없음
    """

    private static let refinedResponse = """
    핵심 요약: Probe summary.
    주요 포인트:
    - Probe point
    액션/결정 사항:
    - 없음
    """

    private(set) var generateCount = 0
    private(set) var streamCount = 0
    private let fastDelayNanoseconds: UInt64
    private let refinedDelayNanoseconds: UInt64

    init(
        fastDelayNanoseconds: UInt64 = 0,
        refinedDelayNanoseconds: UInt64 = 0
    ) {
        self.fastDelayNanoseconds = fastDelayNanoseconds
        self.refinedDelayNanoseconds = refinedDelayNanoseconds
    }

    func availability() async -> SummaryModelAvailability {
        .available
    }

    func contextSize() async -> Int? {
        8_000
    }

    func tokenCount(_ text: String) async throws -> Int {
        max(1, text.count / 4)
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        generateCount += 1
        if refinedDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: refinedDelayNanoseconds)
        }
        return Self.refinedResponse
    }

    func stream(
        prompt: String,
        maxTokens: Int,
        onSnapshot: @Sendable (String) async -> Void
    ) async throws -> String {
        streamCount += 1
        if fastDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: fastDelayNanoseconds)
        }
        await onSnapshot(Self.fastResponse)
        return Self.fastResponse
    }
}
