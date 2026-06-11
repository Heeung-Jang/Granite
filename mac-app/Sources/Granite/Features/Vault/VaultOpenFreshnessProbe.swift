import Foundation
import NativeMarkdownCore

struct VaultOpenFreshnessProbeReport: Codable, Equatable {
    let initialIndexOpened: Bool
    let staleFileMissingBeforeRebuild: Bool
    let freshnessCheckStarted: Bool
    let rebuildObserved: Bool
    let staleFileSearchHitAfterRebuild: Bool
    let readyAfterRebuild: Bool
    let idleAfterRebuild: Bool
    let elapsedMilliseconds: Double?
    let temporaryCleanup: Bool
    let failure: String?

    var passed: Bool {
        initialIndexOpened
            && staleFileMissingBeforeRebuild
            && freshnessCheckStarted
            && rebuildObserved
            && staleFileSearchHitAfterRebuild
            && readyAfterRebuild
            && idleAfterRebuild
            && temporaryCleanup
            && failure == nil
    }
}

@MainActor
enum VaultOpenFreshnessProbe {
    private static let query = "granite-vault-open-freshness-token"

    static func run() -> VaultOpenFreshnessProbeReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraniteVaultOpenFreshnessProbe-\(UUID().uuidString)", isDirectory: true)
        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let indexedNoteURL = vaultURL.appendingPathComponent("Indexed.md")
        let staleNoteURL = vaultURL.appendingPathComponent("Stale.md")
        let start = DispatchTime.now().uptimeNanoseconds

        do {
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try "# Indexed\n\ninitial body\n".write(to: indexedNoteURL, atomically: true, encoding: .utf8)

            let resolver = AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL)
            let location = try resolver.prepareIndexLocation(forVaultAt: vaultURL)
            try EngineReadClient.rebuildIndex(
                vaultURL: vaultURL,
                dataDirectory: location.dataDirectory,
                rebuildDirectory: location.rebuildDirectory
            )

            try "# Stale\n\n\(query)\n".write(to: staleNoteURL, atomically: true, encoding: .utf8)

            let state = AppState(
                engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
                indexDirectoryResolver: resolver,
                vaultAccessValidator: VaultOpenFreshnessProbeVaultAccessValidator(),
                recentVaultStorage: VaultOpenFreshnessProbeRecentVaultStorage(),
                startupVaultRestoreStorage: VaultOpenFreshnessProbeStartupVaultRestoreStorage(),
                workspaceTabSessionStore: VaultOpenFreshnessProbeWorkspaceTabSessionStore(),
                readIndexRecoveryScheduler: BackgroundReadIndexRecoveryScheduler(),
                readIndexFreshnessScheduler: BackgroundReadIndexFreshnessScheduler(),
                vaultChangeWatcher: VaultOpenFreshnessProbeChangeWatcher(),
                vaultIndexRefreshScheduler: DispatchVaultIndexRefreshScheduler(),
                vaultIndexRefreshDebounceInterval: 0.05
            )

            try state.selectVault(vaultURL)
            let initialGeneration = state.readGeneration
            let initialIndexOpened = state.readAvailability == .ready && state.readClient != nil
            let freshnessCheckStarted = state.vaultIndexSyncState == .checking
            let staleFileMissingBeforeRebuild = try search(reader: state.readClient, query: query).items.isEmpty

            let deadline = Date().addingTimeInterval(8)
            var staleFileSearchHitAfterRebuild = false
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                guard state.readAvailability == .ready,
                      state.readGeneration > initialGeneration
                else {
                    continue
                }

                let page = try search(reader: state.readClient, query: query)
                staleFileSearchHitAfterRebuild = page.items.contains { $0.file.relativePath == "Stale.md" }
                if staleFileSearchHitAfterRebuild {
                    break
                }
            }

            let rebuildObserved = state.readGeneration > initialGeneration
            let readyAfterRebuild = state.readAvailability == .ready && state.readClient != nil
            let idleAfterRebuild = state.vaultIndexSyncState == .idle
            state.clearVault()

            return VaultOpenFreshnessProbeReport(
                initialIndexOpened: initialIndexOpened,
                staleFileMissingBeforeRebuild: staleFileMissingBeforeRebuild,
                freshnessCheckStarted: freshnessCheckStarted,
                rebuildObserved: rebuildObserved,
                staleFileSearchHitAfterRebuild: staleFileSearchHitAfterRebuild,
                readyAfterRebuild: readyAfterRebuild,
                idleAfterRebuild: idleAfterRebuild,
                elapsedMilliseconds: milliseconds(since: start).rounded(toPlaces: 3),
                temporaryCleanup: cleanup(root),
                failure: nil
            )
        } catch {
            return VaultOpenFreshnessProbeReport(
                initialIndexOpened: false,
                staleFileMissingBeforeRebuild: false,
                freshnessCheckStarted: false,
                rebuildObserved: false,
                staleFileSearchHitAfterRebuild: false,
                readyAfterRebuild: false,
                idleAfterRebuild: false,
                elapsedMilliseconds: milliseconds(since: start).rounded(toPlaces: 3),
                temporaryCleanup: cleanup(root),
                failure: sanitizedFailure(error, root: root)
            )
        }
    }

    static func encodedReport(_ report: VaultOpenFreshnessProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func search(reader: (any EngineReading)?, query: String) throws -> SearchPage {
        guard let reader else {
            throw ProbeError.missingReadClient
        }

        let box = VaultOpenFreshnessProbeSearchBox()
        Task.detached {
            do {
                let page = try await EngineVaultSearchLoader(reader: reader).search(
                    query: query,
                    mode: .body,
                    page: SearchPageRequest(requestID: 1, offset: 0, limit: 10)
                )
                box.set(.success(page))
            } catch {
                box.set(.failure(error))
            }
        }

        while box.get() == nil {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        guard let result = box.get() else {
            throw ProbeError.missingSearchResult
        }
        return try result.get()
    }

    private static func cleanup(_ root: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: root)
            return !FileManager.default.fileExists(atPath: root.path)
        } catch {
            return false
        }
    }

    private static func sanitizedFailure(_ error: any Error, root: URL) -> String {
        String(describing: error)
            .replacingOccurrences(of: root.path, with: "<probe-root>")
            .replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private enum ProbeError: Error {
        case missingReadClient
        case missingSearchResult
    }
}

private final class VaultOpenFreshnessProbeSearchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<SearchPage, Error>?

    func set(_ result: Result<SearchPage, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<SearchPage, Error>? {
        lock.lock()
        let result = result
        lock.unlock()
        return result
    }
}

private struct VaultOpenFreshnessProbeVaultAccessValidator: VaultAccessValidating {
    func validateVault(at url: URL) -> VaultAccessIssue? { nil }
}

private struct VaultOpenFreshnessProbeRecentVaultStorage: RecentVaultStoring {
    func loadRecentVaultURLs() -> [URL] { [] }
    func saveRecentVaultURLs(_ urls: [URL]) {}
}

private struct VaultOpenFreshnessProbeStartupVaultRestoreStorage: StartupVaultRestoreStoring {
    func loadSuppressesLastVaultRestore() -> Bool { false }
    func saveSuppressesLastVaultRestore(_ value: Bool) {}
}

private struct VaultOpenFreshnessProbeWorkspaceTabSessionStore: WorkspaceTabSessionStoring {
    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? { nil }
    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {}
    func clearSession(forVaultAt vaultURL: URL) {}
}

private struct VaultOpenFreshnessProbeChangeWatcher: VaultChangeWatching {
    func startWatching(vaultURL: URL, onChange: @escaping () -> Void) throws -> any VaultChangeWatch {
        VaultOpenFreshnessProbeWatch()
    }
}

private final class VaultOpenFreshnessProbeWatch: VaultChangeWatch {
    func cancel() {}
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
