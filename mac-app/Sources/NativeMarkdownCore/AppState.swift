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

public enum ReadAvailability: Equatable, Sendable {
    case unavailable
    case opening
    case ready
    case stale
    case error(String)
}

public typealias ReadClientFactory = @Sendable (URL, URL) throws -> any EngineReading

public struct DirtyNavigationWarning: Equatable, Identifiable, Sendable {
    public let dirtyFile: FileTreeItem
    public let requestedFile: FileTreeItem

    public var id: String {
        "\(dirtyFile.id)->\(requestedFile.id)"
    }
}

public enum DirtyLifecycleAction: String, Equatable, Sendable {
    case closeWindow
    case quitApp
}

public struct DirtyLifecycleWarning: Equatable, Identifiable, Sendable {
    public let dirtyFile: FileTreeItem
    public let action: DirtyLifecycleAction

    public var id: String {
        "\(action.rawValue)->\(dirtyFile.id)"
    }
}

public enum DirtyEditorAction: String, Equatable, Sendable {
    case clearSelection
    case closeVault
}

public struct DirtyEditorActionWarning: Equatable, Identifiable, Sendable {
    public let dirtyFile: FileTreeItem
    public let action: DirtyEditorAction

    public var id: String {
        "\(action.rawValue)->\(dirtyFile.id)"
    }
}

public enum WorkspaceSelection: Equatable, Sendable {
    case empty
    case note(FileTreeItem)
    case graph
}

public enum GraphOpenSource: String, Equatable, Sendable {
    case ribbon
    case keyboard
}

public final class AppState: ObservableObject {
    @Published public private(set) var vaultSelection: VaultSelectionState
    @Published public private(set) var engineHealth: EngineHealthStatus
    @Published public private(set) var indexLocation: AppOwnedIndexLocation?
    @Published public private(set) var readClient: (any EngineReading)?
    @Published public private(set) var readAvailability: ReadAvailability
    @Published public private(set) var readGeneration: UInt64
    @Published public private(set) var recentVaults: [RecentVault]
    @Published public private(set) var workspaceSelection: WorkspaceSelection
    @Published public private(set) var selectedFile: FileTreeItem?
    @Published public private(set) var requestedSearch: WorkspaceSearchRequest?
    @Published public private(set) var dirtyNavigationWarning: DirtyNavigationWarning?
    @Published public private(set) var dirtyLifecycleWarning: DirtyLifecycleWarning?
    @Published public private(set) var dirtyEditorActionWarning: DirtyEditorActionWarning?

    private let indexDirectoryResolver: any IndexDirectoryResolving
    private let vaultAccessValidator: any VaultAccessValidating
    private let recentVaultStorage: any RecentVaultStoring
    private let readClientFactory: ReadClientFactory
    private let maxRecentVaults: Int
    private var nextSearchRequestID: UInt64 = 0
    private var dirtyEditorFile: FileTreeItem?

    public init(
        vaultSelection: VaultSelectionState = .noVault,
        engineHealth: EngineHealthStatus = EngineHealthClient().load(),
        indexDirectoryResolver: any IndexDirectoryResolving = AppOwnedIndexDirectoryResolver(),
        vaultAccessValidator: any VaultAccessValidating = FileSystemVaultAccessValidator(),
        recentVaultStorage: any RecentVaultStoring = UserDefaultsRecentVaultStorage(),
        readClientFactory: @escaping ReadClientFactory = { metadataURL, tantivyURL in
            try EngineReadClient.open(metadataURL: metadataURL, tantivyURL: tantivyURL)
        },
        maxRecentVaults: Int = 10
    ) {
        self.vaultSelection = vaultSelection
        self.engineHealth = engineHealth
        self.indexDirectoryResolver = indexDirectoryResolver
        self.vaultAccessValidator = vaultAccessValidator
        self.recentVaultStorage = recentVaultStorage
        self.readClientFactory = readClientFactory
        self.maxRecentVaults = max(1, maxRecentVaults)
        self.readAvailability = .unavailable
        self.readGeneration = 0
        self.workspaceSelection = .empty
        self.recentVaults = Self.normalizedRecentVaults(
            from: recentVaultStorage.loadRecentVaultURLs(),
            limit: self.maxRecentVaults
        )
    }

    public func selectVault(_ url: URL) throws {
        let vaultURL = url.standardizedFileURL
        if let issue = vaultAccessValidator.validateVault(at: vaultURL) {
            resetReadClient(availability: readAvailability(for: issue))
            indexLocation = nil
            workspaceSelection = .empty
            selectedFile = nil
            dirtyEditorFile = nil
            clearAllDirtyWarnings()
            vaultSelection = .unavailable(issue)
            rememberVault(vaultURL)
            return
        }

        let preparedIndexLocation = try indexDirectoryResolver.prepareIndexLocation(forVaultAt: vaultURL)
        resetReadClient(availability: .opening)
        indexLocation = preparedIndexLocation
        do {
            readClient = try readClientFactory(
                preparedIndexLocation.metadataStoreFile,
                preparedIndexLocation.tantivyIndexDirectory
            )
            readAvailability = .ready
        } catch {
            readAvailability = .error(Self.readErrorMessage(error))
        }
        vaultSelection = .selected(vaultURL)
        workspaceSelection = .empty
        selectedFile = nil
        dirtyEditorFile = nil
        clearAllDirtyWarnings()
        rememberVault(vaultURL)
    }

    public func openRecentVault(_ recentVault: RecentVault) throws {
        try selectVault(recentVault.url)
    }

    public func markStaleBookmark(for url: URL) {
        resetReadClient(availability: .stale)
        indexLocation = nil
        workspaceSelection = .empty
        selectedFile = nil
        dirtyEditorFile = nil
        clearAllDirtyWarnings()
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
        resetReadClient(availability: .unavailable)
        vaultSelection = .noVault
        indexLocation = nil
        workspaceSelection = .empty
        selectedFile = nil
        dirtyEditorFile = nil
        clearAllDirtyWarnings()
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
            setDirtyNavigationWarning(DirtyNavigationWarning(
                dirtyFile: dirtyEditorFile,
                requestedFile: item
            ))
            return false
        }

        selectedFile = item
        workspaceSelection = .note(item)
        clearAllDirtyWarnings()
        AppTelemetry.noteOpened(item)
        return true
    }

    public func openGraph(source: GraphOpenSource) {
        workspaceSelection = .graph
        dirtyNavigationWarning = nil
        AppTelemetry.graphOpened(source: source)
    }

    @discardableResult
    public func closeWorkspaceSelection() -> Bool {
        switch workspaceSelection {
        case .graph:
            workspaceSelection = selectedFile.map(WorkspaceSelection.note) ?? .empty
            return true
        case .note:
            return requestClearSelectedFile()
        case .empty:
            return true
        }
    }

    public func updateEditorDirtyState(file: FileTreeItem, isDirty: Bool) {
        if isDirty {
            dirtyEditorFile = file
        } else if dirtyEditorFile == file {
            dirtyEditorFile = nil
            clearAllDirtyWarnings()
        }
    }

    public func isEditorDirty(file: FileTreeItem) -> Bool {
        dirtyEditorFile == file
    }

    public func dismissDirtyNavigationWarning() {
        dirtyNavigationWarning = nil
    }

    public func discardDirtyChangesAndOpenRequestedFile() {
        guard let warning = dirtyNavigationWarning else {
            return
        }
        dirtyEditorFile = nil
        clearAllDirtyWarnings()
        selectedFile = warning.requestedFile
        workspaceSelection = .note(warning.requestedFile)
        AppTelemetry.noteOpened(warning.requestedFile)
    }

    @discardableResult
    public func requestClearSelectedFile() -> Bool {
        guard let selectedFile else {
            workspaceSelection = .empty
            dirtyEditorActionWarning = nil
            return true
        }

        guard !isSelectedEditorDirty else {
            setDirtyEditorActionWarning(DirtyEditorActionWarning(
                dirtyFile: selectedFile,
                action: .clearSelection
            ))
            return false
        }

        self.selectedFile = nil
        workspaceSelection = .empty
        clearAllDirtyWarnings()
        return true
    }

    @discardableResult
    public func requestCloseVault() -> Bool {
        guard vaultSelection.url != nil else {
            dirtyEditorActionWarning = nil
            return true
        }

        if let dirtyEditorFile {
            setDirtyEditorActionWarning(DirtyEditorActionWarning(
                dirtyFile: dirtyEditorFile,
                action: .closeVault
            ))
            return false
        }

        clearVault()
        return true
    }

    public func requestWindowClose() -> Bool {
        requestLifecycleAction(.closeWindow)
    }

    public func requestAppQuit() -> Bool {
        requestLifecycleAction(.quitApp)
    }

    public func dismissDirtyLifecycleWarning() {
        dirtyLifecycleWarning = nil
    }

    public func discardDirtyChangesForLifecycleWarning() -> DirtyLifecycleAction? {
        guard let warning = dirtyLifecycleWarning else {
            return nil
        }
        dirtyEditorFile = nil
        clearAllDirtyWarnings()
        return warning.action
    }

    public func dismissDirtyEditorActionWarning() {
        dirtyEditorActionWarning = nil
    }

    @discardableResult
    public func discardDirtyChangesForEditorActionWarning() -> DirtyEditorAction? {
        guard let warning = dirtyEditorActionWarning else {
            return nil
        }

        dirtyEditorFile = nil
        switch warning.action {
        case .clearSelection:
            selectedFile = nil
            workspaceSelection = .empty
            clearAllDirtyWarnings()
        case .closeVault:
            clearVault()
        }
        return warning.action
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

    private func requestLifecycleAction(_ action: DirtyLifecycleAction) -> Bool {
        guard let dirtyEditorFile else {
            dirtyLifecycleWarning = nil
            return true
        }
        setDirtyLifecycleWarning(DirtyLifecycleWarning(dirtyFile: dirtyEditorFile, action: action))
        return false
    }

    private var isSelectedEditorDirty: Bool {
        guard let dirtyEditorFile else {
            return false
        }
        return selectedFile == dirtyEditorFile
    }

    private func clearAllDirtyWarnings() {
        dirtyNavigationWarning = nil
        dirtyLifecycleWarning = nil
        dirtyEditorActionWarning = nil
    }

    private func setDirtyNavigationWarning(_ warning: DirtyNavigationWarning) {
        dirtyNavigationWarning = warning
        dirtyLifecycleWarning = nil
        dirtyEditorActionWarning = nil
    }

    private func setDirtyLifecycleWarning(_ warning: DirtyLifecycleWarning) {
        dirtyNavigationWarning = nil
        dirtyLifecycleWarning = warning
        dirtyEditorActionWarning = nil
    }

    private func setDirtyEditorActionWarning(_ warning: DirtyEditorActionWarning) {
        dirtyNavigationWarning = nil
        dirtyLifecycleWarning = nil
        dirtyEditorActionWarning = warning
    }

    private func resetReadClient(availability: ReadAvailability) {
        readClient?.close()
        readClient = nil
        readGeneration &+= 1
        readAvailability = availability
    }

    private func readAvailability(for issue: VaultAccessIssue) -> ReadAvailability {
        if case .staleBookmark = issue {
            return .stale
        }
        return .unavailable
    }

    private static func readErrorMessage(_ error: any Error) -> String {
        let description = String(describing: error)
        return description.isEmpty ? "read client unavailable" : description
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
