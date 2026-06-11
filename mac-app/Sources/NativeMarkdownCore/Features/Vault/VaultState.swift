import Foundation

public enum VaultSelectionState: Equatable {
    case noVault
    case selected(URL)
    case unavailable(VaultAccessIssue)

    public var url: URL? {
        switch self {
        case .noVault:
            return nil
        case .selected(let url):
            return url
        case .unavailable(let issue):
            return issue.url
        }
    }
}

public enum ReadAvailability: Equatable, Sendable {
    case unavailable
    case opening
    case ready
    case stale
    case error(String)
}

public enum VaultIndexSyncState: Equatable, Sendable {
    case idle
    case checking
    case updating
    case failed(String)
}

public typealias ReadClientFactory = @Sendable (URL, URL) throws -> any EngineReading

public protocol ReadIndexRebuilding: Sendable {
    func rebuildIndex(vaultURL: URL, location: AppOwnedIndexLocation) throws
}

public protocol ReadIndexFreshnessChecking: Sendable {
    func checkIndexFreshness(vaultURL: URL, location: AppOwnedIndexLocation) throws -> EngineIndexFreshnessReport
}

public protocol ReadIndexRecoveryScheduling: Sendable {
    func schedule(
        _ work: @escaping @Sendable () -> Result<Void, any Error>,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    )
}

public protocol ReadIndexFreshnessScheduling: Sendable {
    func schedule(
        _ work: @escaping @Sendable () -> Result<EngineIndexFreshnessReport, any Error>,
        completion: @escaping @Sendable (Result<EngineIndexFreshnessReport, any Error>) -> Void
    )
}

public final class BackgroundReadIndexRecoveryScheduler: ReadIndexRecoveryScheduling, @unchecked Sendable {
    private let queue: OperationQueue

    public init() {
        let queue = OperationQueue()
        queue.name = "Granite read index recovery"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        self.queue = queue
    }

    public func schedule(
        _ work: @escaping @Sendable () -> Result<Void, any Error>,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        queue.addOperation {
            let result = work()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

public final class BackgroundReadIndexFreshnessScheduler: ReadIndexFreshnessScheduling, @unchecked Sendable {
    private let queue: OperationQueue

    public init() {
        let queue = OperationQueue()
        queue.name = "Granite read index freshness"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        self.queue = queue
    }

    public func schedule(
        _ work: @escaping @Sendable () -> Result<EngineIndexFreshnessReport, any Error>,
        completion: @escaping @Sendable (Result<EngineIndexFreshnessReport, any Error>) -> Void
    ) {
        queue.addOperation {
            let result = work()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

public struct EngineReadIndexRebuilder: ReadIndexRebuilding {
    public init() {}

    public func rebuildIndex(vaultURL: URL, location: AppOwnedIndexLocation) throws {
        try EngineReadClient.rebuildIndex(
            vaultURL: vaultURL,
            dataDirectory: location.dataDirectory,
            rebuildDirectory: location.rebuildDirectory
        )
    }
}

public struct EngineReadIndexFreshnessChecker: ReadIndexFreshnessChecking {
    public init() {}

    public func checkIndexFreshness(
        vaultURL: URL,
        location: AppOwnedIndexLocation
    ) throws -> EngineIndexFreshnessReport {
        try EngineReadClient.checkIndexFreshness(
            vaultURL: vaultURL,
            metadataURL: location.metadataStoreFile
        )
    }
}
