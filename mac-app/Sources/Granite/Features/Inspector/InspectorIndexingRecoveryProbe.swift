import Foundation
import NativeMarkdownCore

struct InspectorIndexingRecoveryProbeReport: Codable, Equatable {
    let notFoundClassifiedAsIndexing: Bool
    let nonNotFoundUsesUserFacingFailure: Bool
    let rawPayloadHidden: Bool
    let existingFileDetected: Bool
    let missingFileDetected: Bool
    let directoryRejected: Bool
    let escapingPathRejected: Bool
    let sameGenerationGuarded: Bool
    let retryAttemptsBounded: Bool
    let retryDurationBounded: Bool
    let manualRetryResets: Bool
    let panelCoverage: Bool
    let temporaryCleanup: Bool

    var passed: Bool {
        notFoundClassifiedAsIndexing
            && nonNotFoundUsesUserFacingFailure
            && rawPayloadHidden
            && existingFileDetected
            && missingFileDetected
            && directoryRejected
            && escapingPathRejected
            && sameGenerationGuarded
            && retryAttemptsBounded
            && retryDurationBounded
            && manualRetryResets
            && panelCoverage
            && temporaryCleanup
    }
}

enum InspectorIndexingRecoveryProbe {
    static func run() -> InspectorIndexingRecoveryProbeReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraniteInspectorIndexingProbe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "Probe".write(to: root.appendingPathComponent("Existing.md"), atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Folder", isDirectory: true),
                withIntermediateDirectories: true
            )

            let notFoundError = EngineReadClientError.engine(EngineReadErrorPayload(
                code: "not_found",
                message: "read target not found",
                state: 5
            ))
            let missingMetadataError = EngineReadClientError.engine(EngineReadErrorPayload(
                code: "missing_metadata",
                message: "metadata store is missing",
                state: 5
            ))
            let notFoundClassifiedAsIndexing = InspectorReadErrorKind.classify(notFoundError) == .indexedTargetNotFound

            let nonNotFoundKind = InspectorReadErrorKind.classify(missingMetadataError)
            let nonNotFoundUsesUserFacingFailure: Bool
            let rawPayloadHidden: Bool
            if case .userFacingFailure(let message) = nonNotFoundKind {
                nonNotFoundUsesUserFacingFailure = message == "metadata store is missing"
                rawPayloadHidden = !message.contains("EngineReadErrorPayload")
                    && !message.contains("engine(")
            } else {
                nonNotFoundUsesUserFacingFailure = false
                rawPayloadHidden = false
            }

            let existingFileDetected = InspectorFilePresence.resolve(
                vaultURL: root,
                file: FileTreeItem(relativePath: "Existing.md")
            ) == .existingVaultFile
            let missingFileDetected = InspectorFilePresence.resolve(
                vaultURL: root,
                file: FileTreeItem(relativePath: "Missing.md")
            ) == .missing
            let directoryRejected = InspectorFilePresence.resolve(
                vaultURL: root,
                file: FileTreeItem(relativePath: "Folder")
            ) == .missing
            let escapingPathRejected = InspectorFilePresence.resolve(
                vaultURL: root,
                file: FileTreeItem(relativePath: "../Outside.md")
            ) == .missing

            let key = InspectorRetryKey(
                file: FileTreeItem(relativePath: "Existing.md"),
                panel: .backlinks
            )
            let start = Date(timeIntervalSince1970: 100)
            var retryState = InspectorIndexingRetryState()
            let firstDecision = retryState.decision(for: key, readGeneration: 0, now: start)
            let sameGenerationDecision = retryState.decision(for: key, readGeneration: 0, now: start)
            let secondGenerationDecision = retryState.decision(for: key, readGeneration: 1, now: start)
            let thirdGenerationDecision = retryState.decision(for: key, readGeneration: 2, now: start)
            let fourthGenerationDecision = retryState.decision(for: key, readGeneration: 3, now: start)
            let sameGenerationGuarded = firstDecision == .requestRebuild
                && sameGenerationDecision == .waitForExistingRebuild
            let retryAttemptsBounded = secondGenerationDecision == .requestRebuild
                && thirdGenerationDecision == .requestRebuild
                && fourthGenerationDecision == .limitExceeded

            var durationState = InspectorIndexingRetryState()
            let durationFirstDecision = durationState.decision(for: key, readGeneration: 0, now: start)
            let durationLimitDecision = durationState.decision(
                for: key,
                readGeneration: 1,
                now: start.addingTimeInterval(11)
            )
            let retryDurationBounded = durationFirstDecision == .requestRebuild
                && durationLimitDecision == .limitExceeded

            retryState.reset(for: key)
            let manualRetryResets = retryState.decision(for: key, readGeneration: 3, now: start) == .requestRebuild

            let readIndexPanels: Set<NoteInspectorPanel> = [.backlinks, .outgoing, .tags, .attachments]
            let panelCoverage = Set(NoteInspectorPanel.allCases).subtracting([.summary]) == readIndexPanels

            return InspectorIndexingRecoveryProbeReport(
                notFoundClassifiedAsIndexing: notFoundClassifiedAsIndexing,
                nonNotFoundUsesUserFacingFailure: nonNotFoundUsesUserFacingFailure,
                rawPayloadHidden: rawPayloadHidden,
                existingFileDetected: existingFileDetected,
                missingFileDetected: missingFileDetected,
                directoryRejected: directoryRejected,
                escapingPathRejected: escapingPathRejected,
                sameGenerationGuarded: sameGenerationGuarded,
                retryAttemptsBounded: retryAttemptsBounded,
                retryDurationBounded: retryDurationBounded,
                manualRetryResets: manualRetryResets,
                panelCoverage: panelCoverage,
                temporaryCleanup: cleanup(root)
            )
        } catch {
            return InspectorIndexingRecoveryProbeReport(
                notFoundClassifiedAsIndexing: false,
                nonNotFoundUsesUserFacingFailure: false,
                rawPayloadHidden: false,
                existingFileDetected: false,
                missingFileDetected: false,
                directoryRejected: false,
                escapingPathRejected: false,
                sameGenerationGuarded: false,
                retryAttemptsBounded: false,
                retryDurationBounded: false,
                manualRetryResets: false,
                panelCoverage: false,
                temporaryCleanup: cleanup(root)
            )
        }
    }

    static func encodedReport(_ report: InspectorIndexingRecoveryProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func cleanup(_ root: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: root)
            return !FileManager.default.fileExists(atPath: root.path)
        } catch {
            return false
        }
    }
}
