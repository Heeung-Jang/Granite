import Foundation
import NativeMarkdownCore

struct FoundationModelsSummaryPerformanceProbeReport: Codable, Equatable {
    var skipped: Bool
    var skipReason: String?
    var foundationModelsCompilePath: String
    var macOSVersion: String
    var modelAvailable: Bool
    var availabilityReason: String?
    var firstSnapshotTargetMilliseconds: Double
    var fastCompletionTargetMilliseconds: Double
    var requiredPassingCases: Int
    var passedCaseCount: Int
    var targetPolicyPassed: Bool
    var noRawSourceInReport: Bool
    var noPromptOrSummaryInReport: Bool
    var noAbsoluteVaultPathInReport: Bool
    var cases: [FoundationModelsSummaryPerformanceCaseReport]
    var summary: ProbeCheckSummary
}

struct FoundationModelsSummaryPerformanceCaseReport: Codable, Equatable {
    var caseID: String
    var sourceByteCount: Int
    var compressedByteCount: Int?
    var compressionRatio: Double?
    var firstSnapshotMilliseconds: Double?
    var fastCompletionMilliseconds: Double?
    var refinedCompletionMilliseconds: Double?
    var refinedState: String
    var fastStage: String?
    var passed: Bool
    var skipReason: String?
}

enum FoundationModelsSummaryPerformanceProbe {
    private static let firstSnapshotTargetMilliseconds = 800.0
    private static let fastCompletionTargetMilliseconds = 2_000.0
    private static let requiredPassingCases = 2

    private static let representativeFiles: [(id: String, relativePath: String)] = [
        ("short", "Codex/Daily/2026-05-15.md"),
        (
            "medium",
            "Codex/Conversations/2026/2026-04-24-1014-workflows-brainstorm-https-github-com-requarks-wiki-git-이-프로젝트를-사내-문서-위키로-사용하고-싶.md"
        ),
        (
            "long",
            "Codex/Conversations/2026/2026-01-23-0645-shareinsight-technical-specification-md-을-바탕으로-post-api-v1-share-links-의-구현-plan.md"
        )
    ]

    static func run(arguments: [String]) async -> FoundationModelsSummaryPerformanceProbeReport {
        let configuration: ProbeConfiguration
        do {
            configuration = try parse(arguments: Array(arguments.dropFirst()))
        } catch let error as ProbeArgumentError {
            return skippedReport(reason: error.rawValue, vaultURL: nil)
        } catch {
            return skippedReport(reason: "argumentError", vaultURL: nil)
        }

        guard let vaultURL = configuration.vaultURL else {
            return skippedReport(reason: "missingVault", vaultURL: nil)
        }

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return skippedReport(reason: "osUnsupported", vaultURL: vaultURL)
        }
        let generator = SummaryGeneratorFactory.make()
        let availability = await generator.availability()
        let contextSize = await generator.contextSize()
        guard case .available = availability else {
            return skippedReport(
                reason: availabilityReason(availability),
                vaultURL: vaultURL,
                modelAvailable: false,
                availabilityReason: availabilityReason(availability)
            )
        }
        return await runAvailableProbe(
            vaultURL: vaultURL,
            generator: generator,
            contextSize: contextSize
        )
        #else
        return skippedReport(reason: "frameworkMissing", vaultURL: vaultURL)
        #endif
    }

    static func encodedReport(_ report: FoundationModelsSummaryPerformanceProbeReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let string = String(data: data, encoding: .utf8)
        else {
            return #"{"summary":{"passed":false,"unexpectedFailures":["encoding"],"expectedFailures":[]}}"#
        }
        return string
    }

    private static func runAvailableProbe(
        vaultURL: URL,
        generator: any DocumentSummaryGenerating,
        contextSize: Int?
    ) async -> FoundationModelsSummaryPerformanceProbeReport {
        var sensitiveValues: [String] = []
        var caseReports: [FoundationModelsSummaryPerformanceCaseReport] = []
        caseReports.reserveCapacity(representativeFiles.count)
        for item in representativeFiles {
            let report = await measureCase(
                id: item.id,
                relativePath: item.relativePath,
                vaultURL: vaultURL,
                generator: generator,
                contextSize: contextSize,
                sensitiveValues: &sensitiveValues
            )
            caseReports.append(report)
        }
        var report = baseReport(
            skipped: false,
            skipReason: nil,
            modelAvailable: true,
            availabilityReason: nil,
            cases: caseReports,
            vaultURL: vaultURL
        )
        report.passedCaseCount = caseReports.filter(\.passed).count
        report.targetPolicyPassed = report.passedCaseCount >= requiredPassingCases
        applyPrivacyChecks(
            to: &report,
            vaultURL: vaultURL,
            sensitiveValues: sensitiveValues
        )
        report.summary = evaluate(report)
        return report
    }

    private static func measureCase(
        id: String,
        relativePath: String,
        vaultURL: URL,
        generator: any DocumentSummaryGenerating,
        contextSize: Int?,
        sensitiveValues: inout [String]
    ) async -> FoundationModelsSummaryPerformanceCaseReport {
        let fileURL = vaultURL.appendingPathComponent(relativePath)
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return caseSkipped(id: id, reason: "missingFile")
        }
        sensitiveValues.append(source)

        let limits = performanceLimits(contextSize: contextSize)
        let compressed = DocumentSummaryCompressor(maxCharacters: limits.fastSourceCharacters)
            .compress(source)
        sensitiveValues.append(compressed.text)
        let snapshot = EditorBufferSnapshot(
            vaultID: vaultURL.standardizedFileURL.path,
            fileID: relativePath,
            tabID: UUID(),
            ownerID: UUID(),
            revision: 1,
            contents: source
        )
        let request = DocumentSummaryRequest(snapshot: snapshot, limits: limits)
        let pipeline = DocumentSummaryPipeline(generator: generator, cache: DocumentSummaryCache())
        let timer = AppTelemetryTimer()
        let firstSnapshot = FirstSnapshotRecorder()
        do {
            let fastSummary = try await pipeline.summarizeFast(
                request: request,
                useCache: false,
                onSnapshot: { _ in
                    await firstSnapshot.recordIfNeeded(timer.elapsedMilliseconds())
                }
            )
            sensitiveValues.append(fastSummary.overview)
            sensitiveValues.append(contentsOf: fastSummary.keyPoints)
            sensitiveValues.append(contentsOf: fastSummary.actionItems)

            let fastCompletion = timer.elapsedMilliseconds()
            let refined = await measureRefinementIfNeeded(
                request: request,
                pipeline: pipeline,
                sensitiveValues: &sensitiveValues
            )
            let firstSnapshotMilliseconds = await firstSnapshot.value
            let passed = fastSummary.metadata.stage == .fast
                && (firstSnapshotMilliseconds ?? .infinity) <= firstSnapshotTargetMilliseconds
                && fastCompletion <= fastCompletionTargetMilliseconds
            return FoundationModelsSummaryPerformanceCaseReport(
                caseID: id,
                sourceByteCount: request.snapshot.byteCount,
                compressedByteCount: compressed.compressedByteCount,
                compressionRatio: compressionRatio(compressed),
                firstSnapshotMilliseconds: firstSnapshotMilliseconds,
                fastCompletionMilliseconds: fastCompletion,
                refinedCompletionMilliseconds: refined.elapsedMilliseconds,
                refinedState: refined.state,
                fastStage: fastSummary.metadata.stage.rawValue,
                passed: passed,
                skipReason: nil
            )
        } catch {
            return FoundationModelsSummaryPerformanceCaseReport(
                caseID: id,
                sourceByteCount: request.snapshot.byteCount,
                compressedByteCount: compressed.compressedByteCount,
                compressionRatio: compressionRatio(compressed),
                firstSnapshotMilliseconds: await firstSnapshot.value,
                fastCompletionMilliseconds: nil,
                refinedCompletionMilliseconds: nil,
                refinedState: "notStarted",
                fastStage: nil,
                passed: false,
                skipReason: safeErrorReason(error)
            )
        }
    }

    private static func measureRefinementIfNeeded(
        request: DocumentSummaryRequest,
        pipeline: DocumentSummaryPipeline,
        sensitiveValues: inout [String]
    ) async -> (state: String, elapsedMilliseconds: Double?) {
        guard request.limits.shouldRunBackgroundRefinement(sourceByteCount: request.snapshot.byteCount) else {
            return ("skippedShortDocument", nil)
        }
        let timer = AppTelemetryTimer()
        do {
            let summary = try await pipeline.summarize(request: request, useCache: false)
            sensitiveValues.append(summary.overview)
            sensitiveValues.append(contentsOf: summary.keyPoints)
            sensitiveValues.append(contentsOf: summary.actionItems)
            return ("complete", timer.elapsedMilliseconds())
        } catch {
            return (safeErrorReason(error), nil)
        }
    }

    private static func caseSkipped(id: String, reason: String) -> FoundationModelsSummaryPerformanceCaseReport {
        FoundationModelsSummaryPerformanceCaseReport(
            caseID: id,
            sourceByteCount: 0,
            compressedByteCount: nil,
            compressionRatio: nil,
            firstSnapshotMilliseconds: nil,
            fastCompletionMilliseconds: nil,
            refinedCompletionMilliseconds: nil,
            refinedState: "notStarted",
            fastStage: nil,
            passed: false,
            skipReason: reason
        )
    }

    private static func skippedReport(
        reason: String,
        vaultURL: URL?,
        modelAvailable: Bool = false,
        availabilityReason: String? = nil
    ) -> FoundationModelsSummaryPerformanceProbeReport {
        var report = baseReport(
            skipped: true,
            skipReason: reason,
            modelAvailable: modelAvailable,
            availabilityReason: availabilityReason ?? reason,
            cases: [],
            vaultURL: vaultURL
        )
        applyPrivacyChecks(to: &report, vaultURL: vaultURL, sensitiveValues: [])
        report.summary = ProbeCheckSummary(
            passed: true,
            unexpectedFailures: [],
            expectedFailures: [reason]
        )
        return report
    }

    private static func baseReport(
        skipped: Bool,
        skipReason: String?,
        modelAvailable: Bool,
        availabilityReason: String?,
        cases: [FoundationModelsSummaryPerformanceCaseReport],
        vaultURL: URL?
    ) -> FoundationModelsSummaryPerformanceProbeReport {
        FoundationModelsSummaryPerformanceProbeReport(
            skipped: skipped,
            skipReason: skipReason,
            foundationModelsCompilePath: foundationModelsCompilePath,
            macOSVersion: macOSVersion,
            modelAvailable: modelAvailable,
            availabilityReason: availabilityReason,
            firstSnapshotTargetMilliseconds: firstSnapshotTargetMilliseconds,
            fastCompletionTargetMilliseconds: fastCompletionTargetMilliseconds,
            requiredPassingCases: requiredPassingCases,
            passedCaseCount: cases.filter(\.passed).count,
            targetPolicyPassed: skipped ? true : cases.filter(\.passed).count >= requiredPassingCases,
            noRawSourceInReport: true,
            noPromptOrSummaryInReport: true,
            noAbsoluteVaultPathInReport: true,
            cases: cases,
            summary: .passed
        )
    }

    private static func applyPrivacyChecks(
        to report: inout FoundationModelsSummaryPerformanceProbeReport,
        vaultURL: URL?,
        sensitiveValues: [String]
    ) {
        let encoded = encodedReport(report)
        report.noRawSourceInReport = sensitiveValues
            .filter { !$0.isEmpty }
            .allSatisfy { !encoded.contains($0) }
        report.noPromptOrSummaryInReport = report.noRawSourceInReport
        if let vaultPath = vaultURL?.standardizedFileURL.path, !vaultPath.isEmpty {
            report.noAbsoluteVaultPathInReport = !encoded.contains(vaultPath)
        } else {
            report.noAbsoluteVaultPathInReport = true
        }
    }

    private static func evaluate(_ report: FoundationModelsSummaryPerformanceProbeReport) -> ProbeCheckSummary {
        if report.skipped {
            return ProbeCheckSummary(
                passed: true,
                unexpectedFailures: [],
                expectedFailures: [report.skipReason ?? "skipped"]
            )
        }
        var failures: [String] = []
        if !report.modelAvailable { failures.append("modelAvailable") }
        if !report.targetPolicyPassed { failures.append("targetPolicyPassed") }
        if !report.noRawSourceInReport { failures.append("noRawSourceInReport") }
        if !report.noPromptOrSummaryInReport { failures.append("noPromptOrSummaryInReport") }
        if !report.noAbsoluteVaultPathInReport { failures.append("noAbsoluteVaultPathInReport") }
        return ProbeCheckSummary(
            passed: failures.isEmpty,
            unexpectedFailures: failures.sorted(),
            expectedFailures: []
        )
    }

    private static func parse(arguments: [String]) throws -> ProbeConfiguration {
        var vaultURL: URL?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--foundation-models-performance-probe":
                index += 1
            case "--vault":
                guard arguments.indices.contains(index + 1) else {
                    throw ProbeArgumentError.missingVaultValue
                }
                vaultURL = URL(fileURLWithPath: arguments[index + 1])
                index += 2
            default:
                throw ProbeArgumentError.unknownArgument
            }
        }
        return ProbeConfiguration(vaultURL: vaultURL)
    }

    private static func performanceLimits(contextSize: Int?) -> DocumentSummaryLimits {
        DocumentSummaryLimits(
            maxSourceBytes: 600 * 1024,
            maxChunks: 128,
            maxModelCalls: 160,
            maxReduceInputTokens: 3_000,
            fallbackInputCharacters: min(12_000, max(6_000, (contextSize ?? 4_096) * 2)),
            fastSourceCharacters: 1_000,
            chunkOutputTokens: 220,
            fastOutputTokens: 64,
            finalOutputTokens: 500,
            refinementSourceByteThreshold: 48 * 1024
        )
    }

    private static func compressionRatio(_ result: DocumentSummaryCompressionResult) -> Double {
        guard result.originalByteCount > 0 else {
            return 0
        }
        return Double(result.compressedByteCount) / Double(result.originalByteCount)
    }

    private static func safeErrorReason(_ error: any Error) -> String {
        if let summaryError = error as? SummaryGenerationError {
            switch summaryError {
            case .contextWindowExceeded:
                return "contextWindowExceeded"
            case .rateLimited:
                return "rateLimited"
            case .unsupportedLanguageOrLocale:
                return "unsupportedLanguageOrLocale"
            case .malformedResponse:
                return "malformedResponse"
            case .unavailable(let reason):
                return reason.rawValue
            case .cancelled:
                return "cancelled"
            case .tooLarge:
                return "tooLarge"
            case .editorNotReady:
                return "editorNotReady"
            case .staleRequest:
                return "staleRequest"
            case .unknown:
                return "unknown"
            }
        }
        return "unknown"
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

private struct ProbeConfiguration {
    var vaultURL: URL?
}

private enum ProbeArgumentError: String, Error {
    case missingVaultValue
    case unknownArgument
}

private actor FirstSnapshotRecorder {
    private(set) var value: Double?

    func recordIfNeeded(_ milliseconds: Double) {
        if value == nil {
            value = milliseconds
        }
    }
}
