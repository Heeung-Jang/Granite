import Foundation

public enum VaultSelectionState: Equatable {
    case noVault
    case selected(URL)
    case unavailable(VaultAccessIssue)
}

public final class AppState: ObservableObject {
    @Published public private(set) var vaultSelection: VaultSelectionState
    @Published public private(set) var engineHealth: EngineHealthStatus
    @Published public private(set) var indexLocation: AppOwnedIndexLocation?

    private let indexDirectoryResolver: any IndexDirectoryResolving
    private let vaultAccessValidator: any VaultAccessValidating

    public init(
        vaultSelection: VaultSelectionState = .noVault,
        engineHealth: EngineHealthStatus = EngineHealthClient().load(),
        indexDirectoryResolver: any IndexDirectoryResolving = AppOwnedIndexDirectoryResolver(),
        vaultAccessValidator: any VaultAccessValidating = FileSystemVaultAccessValidator()
    ) {
        self.vaultSelection = vaultSelection
        self.engineHealth = engineHealth
        self.indexDirectoryResolver = indexDirectoryResolver
        self.vaultAccessValidator = vaultAccessValidator
    }

    public func selectVault(_ url: URL) throws {
        if let issue = vaultAccessValidator.validateVault(at: url) {
            indexLocation = nil
            vaultSelection = .unavailable(issue)
            return
        }

        indexLocation = try indexDirectoryResolver.prepareIndexLocation(forVaultAt: url)
        vaultSelection = .selected(url)
    }

    public func markStaleBookmark(for url: URL) {
        indexLocation = nil
        vaultSelection = .unavailable(.staleBookmark(url))
    }

    public func reconnectVault() throws {
        guard case .unavailable(let issue) = vaultSelection else {
            return
        }
        try selectVault(issue.url)
    }

    public func clearVault() {
        vaultSelection = .noVault
        indexLocation = nil
    }

    public func refreshEngineHealth(using loader: EngineHealthLoading = EngineHealthClient()) {
        engineHealth = loader.load()
    }
}
