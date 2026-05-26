import Foundation
import NativeMarkdownCore

struct FoundationModelsSummarySmokeProbeReport: Codable, Equatable {
    var skipped: Bool
    var skipReason: String?
    var foundationModelsCompilePath: String
    var macOSVersion: String
    var modelAvailable: Bool
    var availabilityReason: String?
    var contextSize: Int?
    var shortSummaryGenerated: Bool
    var shortElapsedMilliseconds: Double?
    var longProgressObserved: Bool
    var longSummaryGenerated: Bool
    var longElapsedMilliseconds: Double?
    var diskUnchanged: Bool
    var noRawSourceInReport: Bool
    var summary: ProbeCheckSummary
}

enum FoundationModelsSummarySmokeProbe {
    static func run() async -> FoundationModelsSummarySmokeProbeReport {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return await runAvailableSDKSmoke()
        }
        return skippedReport(reason: "osUnsupported")
        #else
        return skippedReport(reason: "frameworkMissing")
        #endif
    }

    static func encodedReport(_ report: FoundationModelsSummarySmokeProbeReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let string = String(data: data, encoding: .utf8)
        else {
            return #"{"summary":{"passed":false,"unexpectedFailures":["encoding"],"expectedFailures":[]}}"#
        }
        return string
    }

    private static func skippedReport(reason: String) -> FoundationModelsSummarySmokeProbeReport {
        FoundationModelsSummarySmokeProbeReport(
            skipped: true,
            skipReason: reason,
            foundationModelsCompilePath: foundationModelsCompilePath,
            macOSVersion: macOSVersion,
            modelAvailable: false,
            availabilityReason: reason,
            contextSize: nil,
            shortSummaryGenerated: false,
            shortElapsedMilliseconds: nil,
            longProgressObserved: false,
            longSummaryGenerated: false,
            longElapsedMilliseconds: nil,
            diskUnchanged: true,
            noRawSourceInReport: true,
            summary: ProbeCheckSummary(
                passed: true,
                unexpectedFailures: [],
                expectedFailures: [reason]
            )
        )
    }

    @available(macOS 26.0, *)
    private static func runAvailableSDKSmoke() async -> FoundationModelsSummarySmokeProbeReport {
        let generator = SummaryGeneratorFactory.make()
        let availability = await generator.availability()
        let contextSize = await generator.contextSize()
        guard case .available = availability else {
            let reason = availabilityReason(availability)
            return FoundationModelsSummarySmokeProbeReport(
                skipped: true,
                skipReason: reason,
                foundationModelsCompilePath: foundationModelsCompilePath,
                macOSVersion: macOSVersion,
                modelAvailable: false,
                availabilityReason: reason,
                contextSize: contextSize,
                shortSummaryGenerated: false,
                shortElapsedMilliseconds: nil,
                longProgressObserved: false,
                longSummaryGenerated: false,
                longElapsedMilliseconds: nil,
                diskUnchanged: true,
                noRawSourceInReport: true,
                summary: ProbeCheckSummary(
                    passed: true,
                    unexpectedFailures: [],
                    expectedFailures: [reason]
                )
            )
        }

        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraniteFoundationModelsSmoke-\(UUID().uuidString)", isDirectory: true)
        let noteURL = vaultURL.appendingPathComponent("Smoke.md")
        let diskSource = "# Smoke\nThis file must not be changed by summary generation."
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try? diskSource.data(using: .utf8)?.write(to: noteURL)

        let shortSource = """
        # Granite Summary Smoke
        Granite is a native Markdown app. Summarize this current editor buffer without writing to disk.
        """
        let short = await summarize(
            source: shortSource,
            vaultURL: vaultURL,
            fileID: "Smoke.md",
            generator: generator,
            limits: smokeLimits(fallbackInputCharacters: 2_000)
        )

        let longSource = (1...6)
            .map { index in
                """
                ## Section \(index)
                Granite keeps notes local, avoids writing summaries into documents, shows progress while chunking long files, and should stay responsive during model work.
                """
            }
            .joined(separator: "\n\n")
        let long = await summarize(
            source: longSource,
            vaultURL: vaultURL,
            fileID: "LongSmoke.md",
            generator: generator,
            limits: smokeLimits(fallbackInputCharacters: 500)
        )

        let diskContents = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
        var report = FoundationModelsSummarySmokeProbeReport(
            skipped: false,
            skipReason: nil,
            foundationModelsCompilePath: foundationModelsCompilePath,
            macOSVersion: macOSVersion,
            modelAvailable: true,
            availabilityReason: nil,
            contextSize: contextSize,
            shortSummaryGenerated: short.generated,
            shortElapsedMilliseconds: short.elapsedMilliseconds,
            longProgressObserved: long.progressObserved,
            longSummaryGenerated: long.generated,
            longElapsedMilliseconds: long.elapsedMilliseconds,
            diskUnchanged: diskContents == diskSource,
            noRawSourceInReport: true,
            summary: .passed
        )
        let encoded = encodedReport(report)
        report.noRawSourceInReport = !encoded.contains(shortSource)
            && !encoded.contains(longSource)
            && !encoded.contains(diskSource)
        report.summary = ProbeCheckSummary.evaluate(report: report)
        return report
    }

    private static func summarize(
        source: String,
        vaultURL: URL,
        fileID: String,
        generator: any DocumentSummaryGenerating,
        limits: DocumentSummaryLimits
    ) async -> (generated: Bool, progressObserved: Bool, elapsedMilliseconds: Double?) {
        let snapshot = EditorBufferSnapshot(
            vaultID: vaultURL.standardizedFileURL.path,
            fileID: fileID,
            tabID: UUID(),
            ownerID: UUID(),
            revision: 1,
            contents: source
        )
        let request = DocumentSummaryRequest(snapshot: snapshot, limits: limits)
        let pipeline = DocumentSummaryPipeline(generator: generator, cache: DocumentSummaryCache())
        let progressFlag = SummarySmokeProgressFlag()
        let start = Date()
        do {
            let summary = try await pipeline.summarize(
                request: request,
                progress: { state in
                    if case .summarizingChunk(_, let total) = state, total > 1 {
                        await progressFlag.markObserved()
                    }
                }
            )
            let progressObserved = await progressFlag.observed
            return (
                generated: !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                progressObserved: progressObserved || summary.metadata.chunkCount > 1,
                elapsedMilliseconds: Date().timeIntervalSince(start) * 1_000
            )
        } catch {
            let progressObserved = await progressFlag.observed
            return (generated: false, progressObserved: progressObserved, elapsedMilliseconds: nil)
        }
    }

    private static func smokeLimits(fallbackInputCharacters: Int) -> DocumentSummaryLimits {
        DocumentSummaryLimits(
            maxSourceBytes: 64 * 1024,
            maxChunks: 12,
            maxModelCalls: 16,
            maxReduceInputTokens: 1_600,
            fallbackInputCharacters: fallbackInputCharacters,
            chunkOutputTokens: 96,
            finalOutputTokens: 180
        )
    }

    private static func availabilityReason(_ availability: SummaryModelAvailability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return reason.rawValue
        }
    }

    private static var foundationModelsCompilePath: String {
        #if canImport(FoundationModels)
        "frameworkAvailable"
        #else
        "frameworkMissing"
        #endif
    }

    private static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

private actor SummarySmokeProgressFlag {
    private(set) var observed = false

    func markObserved() {
        observed = true
    }
}
