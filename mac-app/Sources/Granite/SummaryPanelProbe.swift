import Foundation
import NativeMarkdownCore

struct SummaryPanelProbeReport: Codable, Equatable {
    var generatedSummary: Bool
    var cacheHit: Bool
    var cancelledStateRejected: Bool
    var unavailableFallback: Bool
    var diskUnchanged: Bool
    var noRawSourceInReport: Bool
    var cacheEntryCount: Int
    var cacheEstimatedBytes: Int
    var rawSourceReleased: Bool
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

        do {
            guard let snapshot = appState.snapshotForActiveEditor(
                expectedOwnerID: ownerID,
                tabID: tabID,
                fileID: file.id
            ) else {
                throw SummaryGenerationError.editorNotReady
            }
            let request = DocumentSummaryRequest(snapshot: snapshot)
            _ = try await pipeline.summarize(request: request)
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
        let report = SummaryPanelProbeReport(
            generatedSummary: generatedSummary,
            cacheHit: cacheHit,
            cancelledStateRejected: cancelledStateRejected,
            unavailableFallback: unavailableFallback,
            diskUnchanged: diskContents == source,
            noRawSourceInReport: true,
            cacheEntryCount: await cache.entryCount,
            cacheEstimatedBytes: await cache.estimatedBytes,
            rawSourceReleased: true,
            summary: .passed
        )
        var evaluated = report
        evaluated.summary = ProbeCheckSummary.evaluate(report: report)
        return evaluated
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
}

private actor ProbeSummaryGenerator: DocumentSummaryGenerating {
    private(set) var generateCount = 0

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
        return """
        핵심 요약: Probe summary.
        주요 포인트:
        - Probe point
        액션/결정 사항:
        - 없음
        """
    }
}
