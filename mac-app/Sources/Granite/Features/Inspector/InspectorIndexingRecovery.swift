import Foundation
import NativeMarkdownCore

enum InspectorReadErrorKind: Equatable {
    case indexedTargetNotFound
    case userFacingFailure(String)

    static func classify(_ error: any Error) -> InspectorReadErrorKind {
        guard case EngineReadClientError.engine(let payload) = error else {
            return .userFacingFailure("Inspector failed")
        }
        if payload.code == "not_found" {
            return .indexedTargetNotFound
        }

        let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .userFacingFailure(message.isEmpty ? "Inspector failed" : message)
    }
}

enum InspectorFilePresence: Equatable {
    case existingVaultFile
    case missing

    static func resolve(
        vaultURL: URL,
        file: FileTreeItem,
        fileManager: FileManager = .default
    ) -> InspectorFilePresence {
        guard let key = WorkspacePathIdentity.key(for: file) else {
            return .missing
        }

        let rootURL = vaultURL.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = rootURL
            .appendingPathComponent(key, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard fileURL.path.hasPrefix("\(rootURL.path)/") else {
            return .missing
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return .missing
        }
        return .existingVaultFile
    }
}

struct InspectorRetryKey: Hashable {
    let fileID: String
    let relativePathKey: String
    let panel: NoteInspectorPanel

    init(file: FileTreeItem, panel: NoteInspectorPanel) {
        self.fileID = file.id
        self.relativePathKey = WorkspacePathIdentity.key(for: file) ?? file.relativePath
        self.panel = panel
    }
}

enum InspectorIndexingDecision: Equatable {
    case requestRebuild
    case waitForExistingRebuild
    case limitExceeded
}

struct InspectorIndexingRetryState {
    var maxAutomaticAttempts = 3
    var maxAutomaticDuration: TimeInterval = 10
    private var entries: [InspectorRetryKey: Entry] = [:]

    mutating func decision(
        for key: InspectorRetryKey,
        readGeneration: UInt64,
        now: Date
    ) -> InspectorIndexingDecision {
        var entry = entries[key] ?? Entry(firstDetected: now)
        guard !entry.exceedsLimit(
            now: now,
            maxAttempts: maxAutomaticAttempts,
            maxDuration: maxAutomaticDuration
        ) else {
            entries[key] = entry
            return .limitExceeded
        }

        if entry.lastRebuildGeneration == readGeneration {
            entries[key] = entry
            return .waitForExistingRebuild
        }

        entry.automaticAttempts += 1
        entry.lastRebuildGeneration = readGeneration
        entries[key] = entry
        return .requestRebuild
    }

    func limitExceeded(for key: InspectorRetryKey, now: Date) -> Bool {
        guard let entry = entries[key] else {
            return false
        }
        return entry.exceedsLimit(
            now: now,
            maxAttempts: maxAutomaticAttempts,
            maxDuration: maxAutomaticDuration
        )
    }

    mutating func reset(for key: InspectorRetryKey) {
        entries.removeValue(forKey: key)
    }

    mutating func resetAll() {
        entries.removeAll()
    }

    private struct Entry {
        let firstDetected: Date
        var automaticAttempts = 0
        var lastRebuildGeneration: UInt64?

        func exceedsLimit(
            now: Date,
            maxAttempts: Int,
            maxDuration: TimeInterval
        ) -> Bool {
            automaticAttempts >= maxAttempts
                || now.timeIntervalSince(firstDetected) >= maxDuration
        }
    }
}
