import Foundation

public enum VaultSelectionState: Equatable {
    case noVault
    case selected(URL)
}

public final class AppState: ObservableObject {
    @Published public private(set) var vaultSelection: VaultSelectionState
    @Published public private(set) var engineHealth: EngineHealthStatus
    @Published public private(set) var indexLocation: AppOwnedIndexLocation?

    private let indexDirectoryResolver: any IndexDirectoryResolving

    public init(
        vaultSelection: VaultSelectionState = .noVault,
        engineHealth: EngineHealthStatus = EngineHealthClient().load(),
        indexDirectoryResolver: any IndexDirectoryResolving = AppOwnedIndexDirectoryResolver()
    ) {
        self.vaultSelection = vaultSelection
        self.engineHealth = engineHealth
        self.indexDirectoryResolver = indexDirectoryResolver
    }

    public func selectVault(_ url: URL) throws {
        indexLocation = try indexDirectoryResolver.prepareIndexLocation(forVaultAt: url)
        vaultSelection = .selected(url)
    }

    public func clearVault() {
        vaultSelection = .noVault
        indexLocation = nil
    }

    public func refreshEngineHealth(using loader: EngineHealthLoading = EngineHealthClient()) {
        engineHealth = loader.load()
    }
}
