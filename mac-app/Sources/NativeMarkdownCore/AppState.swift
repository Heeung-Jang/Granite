import Foundation

public enum VaultSelectionState: Equatable {
    case noVault
    case selected(URL)
}

public final class AppState: ObservableObject {
    @Published public private(set) var vaultSelection: VaultSelectionState

    public init(vaultSelection: VaultSelectionState = .noVault) {
        self.vaultSelection = vaultSelection
    }

    public func selectVault(_ url: URL) {
        vaultSelection = .selected(url)
    }

    public func clearVault() {
        vaultSelection = .noVault
    }
}

