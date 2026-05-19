import Foundation

public enum VaultSelectionState: Equatable {
    case noVault
    case selected(URL)
}

public final class AppState: ObservableObject {
    @Published public private(set) var vaultSelection: VaultSelectionState
    @Published public private(set) var engineHealth: EngineHealthStatus

    public init(
        vaultSelection: VaultSelectionState = .noVault,
        engineHealth: EngineHealthStatus = EngineHealthClient().load()
    ) {
        self.vaultSelection = vaultSelection
        self.engineHealth = engineHealth
    }

    public func selectVault(_ url: URL) {
        vaultSelection = .selected(url)
    }

    public func clearVault() {
        vaultSelection = .noVault
    }

    public func refreshEngineHealth(using loader: EngineHealthLoading = EngineHealthClient()) {
        engineHealth = loader.load()
    }
}
