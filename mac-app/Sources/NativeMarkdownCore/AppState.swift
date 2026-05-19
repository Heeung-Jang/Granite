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

public struct WorkspaceSearchRequest: Equatable, Sendable {
    public let id: UInt64
    public let query: String
    public let mode: SearchMode

    public init(id: UInt64, query: String, mode: SearchMode) {
        self.id = id
        self.query = query
        self.mode = mode
    }
}

public struct DirtyNavigationWarning: Equatable, Identifiable, Sendable {
    public let dirtyFile: FileTreeItem
    public let requestedFile: FileTreeItem

    public var id: String {
        "\(dirtyFile.id)->\(requestedFile.id)"
    }
}

public final class AppState: ObservableObject {
    @Published public private(set) var vaultSelection: VaultSelectionState
    @Published public private(set) var engineHealth: EngineHealthStatus
    @Published public private(set) var indexLocation: AppOwnedIndexLocation?
    @Published public private(set) var recentVaults: [RecentVault]
    @Published public private(set) var selectedFile: FileTreeItem?
    @Published public private(set) var requestedSearch: WorkspaceSearchRequest?
    @Published public private(set) var dirtyNavigationWarning: DirtyNavigationWarning?

    private let indexDirectoryResolver: any IndexDirectoryResolving
    private let vaultAccessValidator: any VaultAccessValidating
    private let recentVaultStorage: any RecentVaultStoring
    private let maxRecentVaults: Int
    private var nextSearchRequestID: UInt64 = 0
    private var dirtyEditorFile: FileTreeItem?

    public init(
        vaultSelection: VaultSelectionState = .noVault,
        engineHealth: EngineHealthStatus = EngineHealthClient().load(),
        indexDirectoryResolver: any IndexDirectoryResolving = AppOwnedIndexDirectoryResolver(),
        vaultAccessValidator: any VaultAccessValidating = FileSystemVaultAccessValidator(),
        recentVaultStorage: any RecentVaultStoring = UserDefaultsRecentVaultStorage(),
        maxRecentVaults: Int = 10
    ) {
        self.vaultSelection = vaultSelection
        self.engineHealth = engineHealth
        self.indexDirectoryResolver = indexDirectoryResolver
        self.vaultAccessValidator = vaultAccessValidator
        self.recentVaultStorage = recentVaultStorage
        self.maxRecentVaults = max(1, maxRecentVaults)
        self.recentVaults = Self.normalizedRecentVaults(
            from: recentVaultStorage.loadRecentVaultURLs(),
            limit: self.maxRecentVaults
        )
    }

    public func selectVault(_ url: URL) throws {
        let vaultURL = url.standardizedFileURL
        if let issue = vaultAccessValidator.validateVault(at: vaultURL) {
            indexLocation = nil
            selectedFile = nil
            dirtyEditorFile = nil
            dirtyNavigationWarning = nil
            vaultSelection = .unavailable(issue)
            rememberVault(vaultURL)
            return
        }

        indexLocation = try indexDirectoryResolver.prepareIndexLocation(forVaultAt: vaultURL)
        vaultSelection = .selected(vaultURL)
        selectedFile = nil
        dirtyEditorFile = nil
        dirtyNavigationWarning = nil
        rememberVault(vaultURL)
    }

    public func openRecentVault(_ recentVault: RecentVault) throws {
        try selectVault(recentVault.url)
    }

    public func markStaleBookmark(for url: URL) {
        indexLocation = nil
        selectedFile = nil
        dirtyEditorFile = nil
        dirtyNavigationWarning = nil
        let vaultURL = url.standardizedFileURL
        vaultSelection = .unavailable(.staleBookmark(vaultURL))
        rememberVault(vaultURL)
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
        selectedFile = nil
        dirtyEditorFile = nil
        dirtyNavigationWarning = nil
    }

    public func removeRecentVault(_ recentVault: RecentVault) {
        removeRecentVault(at: recentVault.url)
    }

    public func removeRecentVault(at url: URL) {
        let key = RecentVault.storageKey(for: url)
        recentVaults.removeAll { $0.id == key }
        persistRecentVaults()

        if vaultSelection.url.map(RecentVault.storageKey(for:)) == key {
            clearVault()
        }
    }

    public func refreshEngineHealth(using loader: EngineHealthLoading = EngineHealthClient()) {
        engineHealth = loader.load()
    }

    @discardableResult
    public func openFile(_ item: FileTreeItem) -> Bool {
        if let dirtyEditorFile,
           dirtyEditorFile != item,
           selectedFile == dirtyEditorFile {
            dirtyNavigationWarning = DirtyNavigationWarning(
                dirtyFile: dirtyEditorFile,
                requestedFile: item
            )
            return false
        }

        selectedFile = item
        dirtyNavigationWarning = nil
        AppTelemetry.noteOpened(item)
        return true
    }

    public func updateEditorDirtyState(file: FileTreeItem, isDirty: Bool) {
        if isDirty {
            dirtyEditorFile = file
        } else if dirtyEditorFile == file {
            dirtyEditorFile = nil
            dirtyNavigationWarning = nil
        }
    }

    public func dismissDirtyNavigationWarning() {
        dirtyNavigationWarning = nil
    }

    public func discardDirtyChangesAndOpenRequestedFile() {
        guard let warning = dirtyNavigationWarning else {
            return
        }
        dirtyEditorFile = nil
        dirtyNavigationWarning = nil
        selectedFile = warning.requestedFile
        AppTelemetry.noteOpened(warning.requestedFile)
    }

    public func requestSearch(query: String, mode: SearchMode) {
        nextSearchRequestID &+= 1
        requestedSearch = WorkspaceSearchRequest(
            id: nextSearchRequestID,
            query: query,
            mode: mode
        )
    }

    private func rememberVault(_ url: URL) {
        recentVaults.removeAll { $0.id == RecentVault.storageKey(for: url) }
        recentVaults.insert(RecentVault(url: url), at: 0)
        if recentVaults.count > maxRecentVaults {
            recentVaults = Array(recentVaults.prefix(maxRecentVaults))
        }
        persistRecentVaults()
    }

    private func persistRecentVaults() {
        recentVaultStorage.saveRecentVaultURLs(recentVaults.map(\.url))
    }

    private static func normalizedRecentVaults(from urls: [URL], limit: Int) -> [RecentVault] {
        var seen = Set<String>()
        var recents: [RecentVault] = []
        for url in urls {
            let recent = RecentVault(url: url)
            guard seen.insert(recent.id).inserted else {
                continue
            }
            recents.append(recent)
            if recents.count == limit {
                break
            }
        }
        return recents
    }
}
