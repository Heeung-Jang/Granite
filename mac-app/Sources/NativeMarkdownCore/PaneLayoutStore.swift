import Foundation

public final class PaneLayoutStore {
    public private(set) var layout: WorkspacePaneLayout

    private let storage: any WorkspacePaneLayoutStoring

    public init(
        initialVaultURL: URL? = nil,
        storage: any WorkspacePaneLayoutStoring = UserDefaultsWorkspacePaneLayoutStore()
    ) {
        self.storage = storage
        self.layout = initialVaultURL
            .flatMap { storage.loadLayout(forVaultAt: $0) }
            ?? .default
    }

    public func restoreLayout(forVaultAt vaultURL: URL) -> WorkspacePaneLayout {
        layout = storage.loadLayout(forVaultAt: vaultURL) ?? .default
        return layout
    }

    public func resetToDefault() -> WorkspacePaneLayout {
        layout = .default
        return layout
    }

    public func clearStoredLayout(forVaultAt vaultURL: URL) {
        storage.clearLayout(forVaultAt: vaultURL)
    }

    public func setLayout(
        _ layout: WorkspacePaneLayout,
        availableWidth: Double?,
        vaultURL: URL?
    ) -> WorkspacePaneLayout {
        self.layout = layout.clampedToAvailableWidth(availableWidth)
        persistIfNeeded(vaultURL: vaultURL)
        return self.layout
    }

    public func setLeftSidebarWidth(
        _ width: Double,
        availableWidth: Double,
        vaultURL: URL?
    ) -> WorkspacePaneLayout {
        layout = layout.settingLeftSidebarWidth(width, availableWidth: availableWidth)
        persistIfNeeded(vaultURL: vaultURL)
        return layout
    }

    public func setRightSidebarWidth(
        _ width: Double,
        availableWidth: Double,
        vaultURL: URL?
    ) -> WorkspacePaneLayout {
        layout = layout.settingRightSidebarWidth(width, availableWidth: availableWidth)
        persistIfNeeded(vaultURL: vaultURL)
        return layout
    }

    public func toggleLeftSidebarCollapsed(vaultURL: URL?) -> WorkspacePaneLayout {
        layout = layout.togglingLeftSidebarCollapsed()
        persistIfNeeded(vaultURL: vaultURL)
        return layout
    }

    public func toggleRightSidebarCollapsed(vaultURL: URL?) -> WorkspacePaneLayout {
        layout = layout.togglingRightSidebarCollapsed()
        persistIfNeeded(vaultURL: vaultURL)
        return layout
    }

    private func persistIfNeeded(vaultURL: URL?) {
        guard let vaultURL else {
            return
        }
        storage.saveLayout(layout, forVaultAt: vaultURL)
    }
}
