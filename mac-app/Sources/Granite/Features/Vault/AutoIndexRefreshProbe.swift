import Foundation
import NativeMarkdownCore

struct AutoIndexRefreshProbeReport: Codable, Equatable {
    let initialIndexOpened: Bool
    let initialSearchMiss: Bool
    let refreshObserved: Bool
    let refreshedSearchHit: Bool
    let generationAdvanced: Bool
    let readyAfterRefresh: Bool
    let elapsedMilliseconds: Double?
    let temporaryCleanup: Bool
    let failure: String?

    var passed: Bool {
        initialIndexOpened
            && initialSearchMiss
            && refreshObserved
            && refreshedSearchHit
            && generationAdvanced
            && readyAfterRefresh
            && temporaryCleanup
            && failure == nil
    }
}

@MainActor
enum AutoIndexRefreshProbe {
    private static let query = "granite-auto-refresh-token"

    static func run() -> AutoIndexRefreshProbeReport {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GraniteAutoIndexRefreshProbe-\(UUID().uuidString)", isDirectory: true)
        let vaultURL = root.appendingPathComponent("vault", isDirectory: true)
        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let noteURL = vaultURL.appendingPathComponent("First.md")
        let start = DispatchTime.now().uptimeNanoseconds

        do {
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try "# First\n\ninitial body only\n".write(to: noteURL, atomically: true, encoding: .utf8)

            let resolver = AppOwnedIndexDirectoryResolver(applicationSupportRoot: supportURL)
            let location = try resolver.prepareIndexLocation(forVaultAt: vaultURL)
            try EngineReadClient.rebuildIndex(
                vaultURL: vaultURL,
                dataDirectory: location.dataDirectory,
                rebuildDirectory: location.rebuildDirectory
            )

            let state = AppState(
                engineHealth: EngineHealthStatus(state: .loaded, abiVersion: 1, message: "probe"),
                indexDirectoryResolver: resolver,
                vaultAccessValidator: AutoIndexRefreshProbeVaultAccessValidator(),
                recentVaultStorage: AutoIndexRefreshProbeRecentVaultStorage(),
                startupVaultRestoreStorage: AutoIndexRefreshProbeStartupVaultRestoreStorage(),
                workspaceTabSessionStore: AutoIndexRefreshProbeWorkspaceTabSessionStore(),
                readIndexRecoveryScheduler: BackgroundReadIndexRecoveryScheduler(),
                vaultChangeWatcher: FSEventsVaultChangeWatcher(latency: 0.05),
                vaultIndexRefreshScheduler: DispatchVaultIndexRefreshScheduler(),
                vaultIndexRefreshDebounceInterval: 0.05
            )

            try state.selectVault(vaultURL)
            let initialGeneration = state.readGeneration
            let initialIndexOpened = state.readAvailability == ReadAvailability.ready && state.readClient != nil
            let initialSearchMiss = try search(reader: state.readClient, query: query).items.isEmpty

            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            try "# First\n\ninitial body plus \(query)\n".write(to: noteURL, atomically: true, encoding: .utf8)

            let deadline = Date().addingTimeInterval(8)
            var refreshedSearchHit = false
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                guard state.readAvailability == ReadAvailability.ready,
                      state.readGeneration > initialGeneration
                else {
                    continue
                }

                let page = try search(reader: state.readClient, query: query)
                refreshedSearchHit = page.items.contains { $0.file.relativePath == "First.md" }
                if refreshedSearchHit {
                    break
                }
            }

            let finalGeneration = state.readGeneration
            let readyAfterRefresh = state.readAvailability == ReadAvailability.ready && state.readClient != nil
            state.clearVault()

            return AutoIndexRefreshProbeReport(
                initialIndexOpened: initialIndexOpened,
                initialSearchMiss: initialSearchMiss,
                refreshObserved: finalGeneration > initialGeneration,
                refreshedSearchHit: refreshedSearchHit,
                generationAdvanced: finalGeneration > initialGeneration,
                readyAfterRefresh: readyAfterRefresh,
                elapsedMilliseconds: milliseconds(since: start).rounded(toPlaces: 3),
                temporaryCleanup: cleanup(root),
                failure: nil
            )
        } catch {
            return AutoIndexRefreshProbeReport(
                initialIndexOpened: false,
                initialSearchMiss: false,
                refreshObserved: false,
                refreshedSearchHit: false,
                generationAdvanced: false,
                readyAfterRefresh: false,
                elapsedMilliseconds: milliseconds(since: start).rounded(toPlaces: 3),
                temporaryCleanup: cleanup(root),
                failure: String(describing: error)
            )
        }
    }

    static func encodedReport(_ report: AutoIndexRefreshProbeReport = run()) -> String {
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

        let box = AutoIndexRefreshProbeSearchBox()
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

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private enum ProbeError: Error {
        case missingReadClient
        case missingSearchResult
    }
}

private final class AutoIndexRefreshProbeSearchBox: @unchecked Sendable {
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

private struct AutoIndexRefreshProbeVaultAccessValidator: VaultAccessValidating {
    func validateVault(at url: URL) -> VaultAccessIssue? { nil }
}

private struct AutoIndexRefreshProbeRecentVaultStorage: RecentVaultStoring {
    func loadRecentVaultURLs() -> [URL] { [] }
    func saveRecentVaultURLs(_ urls: [URL]) {}
}

private struct AutoIndexRefreshProbeStartupVaultRestoreStorage: StartupVaultRestoreStoring {
    func loadSuppressesLastVaultRestore() -> Bool { false }
    func saveSuppressesLastVaultRestore(_ value: Bool) {}
}

private struct AutoIndexRefreshProbeWorkspaceTabSessionStore: WorkspaceTabSessionStoring {
    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? { nil }
    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {}
    func clearSession(forVaultAt vaultURL: URL) {}
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
