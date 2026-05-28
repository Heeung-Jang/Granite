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

public typealias ReadClientFactory = @Sendable (URL, URL) throws -> any EngineReading

public protocol ReadIndexRebuilding: Sendable {
    func rebuildIndex(vaultURL: URL, location: AppOwnedIndexLocation) throws
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
