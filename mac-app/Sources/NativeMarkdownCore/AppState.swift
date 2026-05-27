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
    public let dirtyCount: Int

    public init(dirtyFile: FileTreeItem, action: DirtyLifecycleAction, dirtyCount: Int = 1) {
        self.dirtyFile = dirtyFile
        self.action = action
        self.dirtyCount = max(1, dirtyCount)
    }

    public var id: String {
        "\(action.rawValue)->\(dirtyFile.id)->\(dirtyCount)"
    }

    public var isAggregate: Bool {
        dirtyCount > 1
    }
}

public enum DirtyEditorAction: String, Equatable, Sendable {
    case clearSelection
    case closeVault
}

public struct DirtyEditorActionWarning: Equatable, Identifiable, Sendable {
    public let dirtyFile: FileTreeItem
    public let action: DirtyEditorAction
    public let dirtyCount: Int

    public init(dirtyFile: FileTreeItem, action: DirtyEditorAction, dirtyCount: Int = 1) {
        self.dirtyFile = dirtyFile
        self.action = action
        self.dirtyCount = max(1, dirtyCount)
    }

    public var id: String {
        "\(action.rawValue)->\(dirtyFile.id)->\(dirtyCount)"
    }

    public var isAggregate: Bool {
        dirtyCount > 1
    }
}

public struct DirtyTabCloseWarning: Equatable, Identifiable, Sendable {
    public let tabID: WorkspaceTab.ID
    public let dirtyFile: FileTreeItem

    public var id: String {
        "\(tabID.uuidString)->\(dirtyFile.id)"
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

public struct ActiveEditorBufferDescriptor: Equatable, Sendable {
    public let vaultID: String
    public let fileID: String
    public let tabID: WorkspaceTab.ID
    public let ownerID: UUID
    public let revision: UInt64

    public init(
        vaultID: String,
        fileID: String,
        tabID: WorkspaceTab.ID,
        ownerID: UUID,
        revision: UInt64
    ) {
        self.vaultID = vaultID
        self.fileID = fileID
        self.tabID = tabID
        self.ownerID = ownerID
        self.revision = revision
    }
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
    @Published public private(set) var workspaceTabs: [WorkspaceTab]
    @Published public private(set) var activeTabID: WorkspaceTab.ID?
    @Published public private(set) var recentlyClosedTabs: [WorkspaceTabClosedEntry]
    @Published public private(set) var workspacePaneLayout: WorkspacePaneLayout
    @Published public private(set) var selectedFile: FileTreeItem?
    @Published public private(set) var requestedSearch: WorkspaceSearchRequest?
    @Published public private(set) var dirtyNavigationWarning: DirtyNavigationWarning?
    @Published public private(set) var dirtyLifecycleWarning: DirtyLifecycleWarning?
    @Published public private(set) var dirtyEditorActionWarning: DirtyEditorActionWarning?
    @Published public private(set) var dirtyTabCloseWarning: DirtyTabCloseWarning?

    private let indexDirectoryResolver: any IndexDirectoryResolving
    private let vaultAccessValidator: any VaultAccessValidating
    private let recentVaultStorage: any RecentVaultStoring
    private let startupVaultRestoreStorage: any StartupVaultRestoreStoring
    private let workspaceTabSessionStore: any WorkspaceTabSessionStoring
    private let paneLayoutStore: PaneLayoutStore
    private let readClientFactory: ReadClientFactory
    private let readIndexRebuilder: any ReadIndexRebuilding
    private let maxRecentVaults: Int
    private var nextSearchRequestID: UInt64 = 0
    private var didAttemptLastVaultAutoRestore = false
    private var dirtyEditorFiles: [String: FileTreeItem] = [:]
    private var activeEditorBufferProvider: ActiveEditorBufferProvider?

    public init(
        vaultSelection: VaultSelectionState = .noVault,
        engineHealth: EngineHealthStatus = EngineHealthClient().load(),
        indexDirectoryResolver: any IndexDirectoryResolving = AppOwnedIndexDirectoryResolver(),
        vaultAccessValidator: any VaultAccessValidating = FileSystemVaultAccessValidator(),
        recentVaultStorage: any RecentVaultStoring = UserDefaultsRecentVaultStorage(),
        startupVaultRestoreStorage: any StartupVaultRestoreStoring = UserDefaultsStartupVaultRestoreStorage(),
        workspaceTabSessionStore: any WorkspaceTabSessionStoring = UserDefaultsWorkspaceTabSessionStore(),
        workspacePaneLayoutStore: any WorkspacePaneLayoutStoring = UserDefaultsWorkspacePaneLayoutStore(),
        readClientFactory: @escaping ReadClientFactory = { metadataURL, tantivyURL in
            try EngineReadClient.open(metadataURL: metadataURL, tantivyURL: tantivyURL)
        },
        readIndexRebuilder: any ReadIndexRebuilding = EngineReadIndexRebuilder(),
        maxRecentVaults: Int = 10
    ) {
        let paneLayoutStore = PaneLayoutStore(
            initialVaultURL: vaultSelection.url,
            storage: workspacePaneLayoutStore
        )

        self.vaultSelection = vaultSelection
        self.engineHealth = engineHealth
        self.indexDirectoryResolver = indexDirectoryResolver
        self.vaultAccessValidator = vaultAccessValidator
        self.recentVaultStorage = recentVaultStorage
        self.startupVaultRestoreStorage = startupVaultRestoreStorage
        self.workspaceTabSessionStore = workspaceTabSessionStore
        self.paneLayoutStore = paneLayoutStore
        self.readClientFactory = readClientFactory
        self.readIndexRebuilder = readIndexRebuilder
        self.maxRecentVaults = max(1, maxRecentVaults)
        self.readAvailability = .unavailable
        self.readGeneration = 0
        self.workspaceSelection = .empty
        self.workspaceTabs = []
        self.activeTabID = nil
        self.recentlyClosedTabs = []
        self.workspacePaneLayout = paneLayoutStore.layout
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
            resetWorkspaceState()
            clearAllDirtyWarnings()
            vaultSelection = .unavailable(issue)
            restoreWorkspacePaneLayout(for: vaultURL)
            rememberVault(vaultURL)
            startupVaultRestoreStorage.saveSuppressesLastVaultRestore(false)
            return
        }

        let preparedIndexLocation = try indexDirectoryResolver.prepareIndexLocation(forVaultAt: vaultURL)
        resetReadClient(availability: .opening)
        indexLocation = preparedIndexLocation
        openReadClient(vaultURL: vaultURL, location: preparedIndexLocation)
        vaultSelection = .selected(vaultURL)
        resetWorkspaceState()
        restoreWorkspacePaneLayout(for: vaultURL)
        restoreWorkspaceTabSession(for: vaultURL)
        clearAllDirtyWarnings()
        rememberVault(vaultURL)
        startupVaultRestoreStorage.saveSuppressesLastVaultRestore(false)
    }

    public func openRecentVault(_ recentVault: RecentVault) throws {
        try selectVault(recentVault.url)
    }

    @discardableResult
    public func restoreLastVaultOnLaunchIfNeeded() throws -> Bool {
        guard !didAttemptLastVaultAutoRestore,
              vaultSelection.url == nil,
              !startupVaultRestoreStorage.loadSuppressesLastVaultRestore(),
              let recentVault = recentVaults.first
        else {
            return false
        }

        didAttemptLastVaultAutoRestore = true
        try openRecentVault(recentVault)
        return true
    }

    public func markStaleBookmark(for url: URL) {
        resetReadClient(availability: .stale)
        indexLocation = nil
        resetWorkspaceState()
        clearAllDirtyWarnings()
        let vaultURL = url.standardizedFileURL
        vaultSelection = .unavailable(.staleBookmark(vaultURL))
        restoreWorkspacePaneLayout(for: vaultURL)
        rememberVault(vaultURL)
        startupVaultRestoreStorage.saveSuppressesLastVaultRestore(false)
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
        resetWorkspaceState()
        workspacePaneLayout = paneLayoutStore.resetToDefault()
        clearAllDirtyWarnings()
    }

    public func removeRecentVault(_ recentVault: RecentVault) {
        removeRecentVault(at: recentVault.url)
    }

    public func removeRecentVault(at url: URL) {
        let key = RecentVault.storageKey(for: url)
        let removedCurrentVault = vaultSelection.url.map(RecentVault.storageKey(for:)) == key
        recentVaults.removeAll { $0.id == key }
        persistRecentVaults()
        workspaceTabSessionStore.clearSession(forVaultAt: url)
        paneLayoutStore.clearStoredLayout(forVaultAt: url)

        if removedCurrentVault {
            startupVaultRestoreStorage.saveSuppressesLastVaultRestore(true)
            clearVault()
        }
    }

    public func setWorkspacePaneLayout(_ layout: WorkspacePaneLayout, availableWidth: Double? = nil) {
        workspacePaneLayout = paneLayoutStore.setLayout(
            layout,
            availableWidth: availableWidth,
            vaultURL: vaultSelection.url
        )
    }

    public func setLeftSidebarWidth(_ width: Double, availableWidth: Double) {
        workspacePaneLayout = paneLayoutStore.setLeftSidebarWidth(
            width,
            availableWidth: availableWidth,
            vaultURL: vaultSelection.url
        )
    }

    public func setRightSidebarWidth(_ width: Double, availableWidth: Double) {
        workspacePaneLayout = paneLayoutStore.setRightSidebarWidth(
            width,
            availableWidth: availableWidth,
            vaultURL: vaultSelection.url
        )
    }

    public func toggleLeftSidebarCollapsed() {
        workspacePaneLayout = paneLayoutStore.toggleLeftSidebarCollapsed(vaultURL: vaultSelection.url)
    }

    public func toggleRightSidebarCollapsed() {
        workspacePaneLayout = paneLayoutStore.toggleRightSidebarCollapsed(vaultURL: vaultSelection.url)
    }

    public func refreshEngineHealth(using loader: EngineHealthLoading = EngineHealthClient()) {
        engineHealth = loader.load()
    }

    public var activeEditorBufferDescriptor: ActiveEditorBufferDescriptor? {
        activeEditorBufferProvider.map(\.descriptor)
    }

    public func registerActiveEditorBufferProvider(
        vaultID: String,
        ownerID: UUID,
        tabID: WorkspaceTab.ID,
        fileID: String,
        revision: UInt64,
        provider: @escaping () -> String
    ) {
        guard activeTabID == tabID,
              selectedFile?.id == fileID
        else {
            return
        }
        activeEditorBufferProvider = ActiveEditorBufferProvider(
            descriptor: ActiveEditorBufferDescriptor(
                vaultID: vaultID,
                fileID: fileID,
                tabID: tabID,
                ownerID: ownerID,
                revision: revision
            ),
            provider: provider
        )
    }

    public func updateActiveEditorBufferRevision(
        ownerID: UUID,
        tabID: WorkspaceTab.ID,
        fileID: String,
        revision: UInt64
    ) {
        guard let current = activeEditorBufferProvider,
              current.descriptor.ownerID == ownerID,
              current.descriptor.tabID == tabID,
              current.descriptor.fileID == fileID,
              activeTabID == tabID,
              selectedFile?.id == fileID
        else {
            return
        }
        activeEditorBufferProvider = ActiveEditorBufferProvider(
            descriptor: ActiveEditorBufferDescriptor(
                vaultID: current.descriptor.vaultID,
                fileID: fileID,
                tabID: tabID,
                ownerID: ownerID,
                revision: revision
            ),
            provider: current.provider
        )
    }

    public func clearActiveEditorBufferProvider(
        ownerID: UUID,
        tabID: WorkspaceTab.ID,
        fileID: String
    ) {
        guard let current = activeEditorBufferProvider,
              current.descriptor.ownerID == ownerID,
              current.descriptor.tabID == tabID,
              current.descriptor.fileID == fileID
        else {
            return
        }
        activeEditorBufferProvider = nil
    }

    public func snapshotForActiveEditor(
        expectedOwnerID ownerID: UUID,
        tabID: WorkspaceTab.ID,
        fileID: String
    ) -> EditorBufferSnapshot? {
        guard let current = activeEditorBufferProvider,
              current.descriptor.ownerID == ownerID,
              current.descriptor.tabID == tabID,
              current.descriptor.fileID == fileID,
              activeTabID == tabID,
              selectedFile?.id == fileID
        else {
            return nil
        }
        return EditorBufferSnapshot(
            vaultID: current.descriptor.vaultID,
            fileID: fileID,
            tabID: tabID,
            ownerID: ownerID,
            revision: current.descriptor.revision,
            contents: current.provider()
        )
    }

    @discardableResult
    public func openFile(_ item: FileTreeItem) -> Bool {
        openFile(item, disposition: .currentTab)
    }

    @discardableResult
    public func openFile(
        _ item: FileTreeItem,
        disposition: WorkspaceTabOpenDisposition
    ) -> Bool {
        guard let requestedKey = WorkspacePathIdentity.key(for: item) else {
            return false
        }

        let previousActiveID = activeTabID
        let shouldRemoveActiveEmpty = activeTab?.isEmpty == true
        if let existingIndex = workspaceTabs.firstIndex(where: { $0.relativePathKey == requestedKey }) {
            let existingTabID = workspaceTabs[existingIndex].id
            let didChangeActiveTab = activeTabID != existingTabID
            activateTab(id: existingTabID, persist: false)
            if shouldRemoveActiveEmpty,
               let previousActiveID,
               previousActiveID != activeTabID {
                removeEmptyTab(id: previousActiveID)
            }
            clearAllDirtyWarnings()
            AppTelemetry.noteOpened(item)
            if didChangeActiveTab || shouldRemoveActiveEmpty {
                persistWorkspaceTabSession()
            }
            return true
        }

        switch disposition {
        case .newTab:
            appendFileTab(item)
            clearAllDirtyWarnings()
            AppTelemetry.noteOpened(item)
            persistWorkspaceTabSession()
            return true
        case .currentTab:
            if let activeIndex = activeTabIndex {
                if let dirtyFile = dirtyFile(for: workspaceTabs[activeIndex]) {
                    setDirtyNavigationWarning(DirtyNavigationWarning(
                        dirtyFile: dirtyFile,
                        requestedFile: item
                    ))
                    return false
                }
                workspaceTabs[activeIndex].replaceFile(item)
                activeTabID = workspaceTabs[activeIndex].id
                selectedFile = item
                workspaceSelection = .note(item)
            } else {
                appendFileTab(item)
            }
            clearAllDirtyWarnings()
            AppTelemetry.noteOpened(item)
            persistWorkspaceTabSession()
            return true
        }
    }

    public var activeTab: WorkspaceTab? {
        guard let activeTabIndex else {
            return nil
        }
        return workspaceTabs[activeTabIndex]
    }

    public var activeFile: FileTreeItem? {
        activeTab?.file
    }

    public func newEmptyTab() {
        if activeTab?.isEmpty == true {
            selectedFile = nil
            workspaceSelection = .empty
            clearAllDirtyWarnings()
            return
        }
        let tab = WorkspaceTab()
        workspaceTabs.append(tab)
        activeTabID = tab.id
        self.selectedFile = nil
        workspaceSelection = .empty
        clearAllDirtyWarnings()
        persistWorkspaceTabSession()
    }

    public func activateTab(id: WorkspaceTab.ID) {
        activateTab(id: id, persist: true)
    }

    private func activateTab(id: WorkspaceTab.ID, persist: Bool) {
        guard let index = workspaceTabs.firstIndex(where: { $0.id == id }) else {
            return
        }
        let tab = workspaceTabs[index]
        guard activeTabID != tab.id || selectedFile != tab.file else {
            clearAllDirtyWarnings()
            return
        }
        activeTabID = tab.id
        selectedFile = tab.file
        workspaceSelection = tab.file.map(WorkspaceSelection.note) ?? .empty
        clearAllDirtyWarnings()
        if persist {
            persistWorkspaceTabSession()
        }
    }

    public func activateNextTab() {
        guard !workspaceTabs.isEmpty else {
            return
        }
        let currentIndex = activeTabIndex ?? 0
        let nextIndex = (currentIndex + 1) % workspaceTabs.count
        activateTab(id: workspaceTabs[nextIndex].id)
    }

    public func activatePreviousTab() {
        guard !workspaceTabs.isEmpty else {
            return
        }
        let currentIndex = activeTabIndex ?? 0
        let previousIndex = (currentIndex - 1 + workspaceTabs.count) % workspaceTabs.count
        activateTab(id: workspaceTabs[previousIndex].id)
    }

    public func activateTab(atShortcutIndex shortcutIndex: Int) {
        guard !workspaceTabs.isEmpty else {
            return
        }
        let targetIndex: Int
        if shortcutIndex == 9 {
            targetIndex = workspaceTabs.count - 1
        } else {
            targetIndex = shortcutIndex - 1
        }
        guard workspaceTabs.indices.contains(targetIndex) else {
            return
        }
        activateTab(id: workspaceTabs[targetIndex].id)
    }

    public func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard workspaceTabs.indices.contains(sourceIndex),
              sourceIndex != destinationIndex
        else {
            return
        }
        let boundedDestination = min(max(0, destinationIndex), workspaceTabs.count - 1)
        let tab = workspaceTabs.remove(at: sourceIndex)
        workspaceTabs.insert(tab, at: boundedDestination)
        persistWorkspaceTabSession()
    }

    @discardableResult
    public func requestCloseActiveTab() -> Bool {
        guard let activeTabID else {
            return true
        }
        return requestCloseTab(activeTabID)
    }

    @discardableResult
    public func requestCloseTab(_ tabID: WorkspaceTab.ID) -> Bool {
        guard let index = workspaceTabs.firstIndex(where: { $0.id == tabID }) else {
            dirtyTabCloseWarning = nil
            return true
        }
        let tab = workspaceTabs[index]
        if let dirtyFile = dirtyFile(for: tab) {
            setDirtyTabCloseWarning(DirtyTabCloseWarning(tabID: tab.id, dirtyFile: dirtyFile))
            return false
        }
        closeTab(at: index)
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

    public func dismissDirtyTabCloseWarning() {
        dirtyTabCloseWarning = nil
    }

    @discardableResult
    public func discardDirtyChangesForTabCloseWarning() -> Bool {
        guard let warning = dirtyTabCloseWarning,
              let index = workspaceTabs.firstIndex(where: { $0.id == warning.tabID })
        else {
            return false
        }
        clearDirtyState(for: warning.dirtyFile)
        dirtyTabCloseWarning = nil
        closeTab(at: index)
        return true
    }

    public func restoreRecentlyClosedTab() {
        guard let entry = recentlyClosedTabs.popLast() else {
            return
        }
        if let existingIndex = workspaceTabs.firstIndex(where: { $0.relativePathKey == entry.relativePathKey }) {
            activateTab(id: workspaceTabs[existingIndex].id)
            return
        }
        let tab = WorkspaceTab(file: FileTreeItem(relativePath: entry.relativePathKey))
        let insertionIndex = min(entry.originalIndex, workspaceTabs.count)
        workspaceTabs.insert(tab, at: insertionIndex)
        activeTabID = tab.id
        selectedFile = tab.file
        workspaceSelection = tab.file.map(WorkspaceSelection.note) ?? .empty
        clearAllDirtyWarnings()
        persistWorkspaceTabSession()
    }

    public func updateEditorDirtyState(file: FileTreeItem, isDirty: Bool) {
        guard let key = WorkspacePathIdentity.key(for: file) else {
            return
        }
        if isDirty {
            dirtyEditorFiles[key] = file
        } else if dirtyEditorFiles[key] != nil {
            dirtyEditorFiles.removeValue(forKey: key)
            clearAllDirtyWarnings()
        }
    }

    public func isEditorDirty(file: FileTreeItem) -> Bool {
        guard let key = WorkspacePathIdentity.key(for: file) else {
            return false
        }
        return dirtyEditorFiles[key] != nil
    }

    public func dismissDirtyNavigationWarning() {
        dirtyNavigationWarning = nil
    }

    public func discardDirtyChangesAndOpenRequestedFile() {
        guard let warning = dirtyNavigationWarning else {
            return
        }
        clearDirtyState(for: warning.dirtyFile)
        clearAllDirtyWarnings()
        if let activeTabIndex {
            workspaceTabs[activeTabIndex].replaceFile(warning.requestedFile)
            activeTabID = workspaceTabs[activeTabIndex].id
        } else {
            appendFileTab(warning.requestedFile)
        }
        selectedFile = warning.requestedFile
        workspaceSelection = .note(warning.requestedFile)
        AppTelemetry.noteOpened(warning.requestedFile)
        persistWorkspaceTabSession()
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

        if let activeTabIndex {
            workspaceTabs[activeTabIndex].replaceFile(nil)
        }
        self.selectedFile = nil
        workspaceSelection = .empty
        clearAllDirtyWarnings()
        persistWorkspaceTabSession()
        return true
    }

    @discardableResult
    public func requestCloseVault() -> Bool {
        guard vaultSelection.url != nil else {
            dirtyEditorActionWarning = nil
            return true
        }

        if let dirtyEditorFile = firstDirtyEditorFile {
            setDirtyEditorActionWarning(DirtyEditorActionWarning(
                dirtyFile: dirtyEditorFile,
                action: .closeVault,
                dirtyCount: dirtyEditorFileCount
            ))
            return false
        }

        startupVaultRestoreStorage.saveSuppressesLastVaultRestore(true)
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
        dirtyEditorFiles.removeAll()
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

        clearDirtyState(for: warning.dirtyFile)
        switch warning.action {
        case .clearSelection:
            if let activeTabIndex {
                workspaceTabs[activeTabIndex].replaceFile(nil)
            }
            selectedFile = nil
            workspaceSelection = .empty
            clearAllDirtyWarnings()
            persistWorkspaceTabSession()
        case .closeVault:
            startupVaultRestoreStorage.saveSuppressesLastVaultRestore(true)
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
        guard let dirtyEditorFile = firstDirtyEditorFile else {
            dirtyLifecycleWarning = nil
            return true
        }
        setDirtyLifecycleWarning(DirtyLifecycleWarning(
            dirtyFile: dirtyEditorFile,
            action: action,
            dirtyCount: dirtyEditorFileCount
        ))
        return false
    }

    private var isSelectedEditorDirty: Bool {
        guard let selectedFile,
              let key = WorkspacePathIdentity.key(for: selectedFile)
        else {
            return false
        }
        return dirtyEditorFiles[key] != nil
    }

    private var activeTabIndex: Int? {
        guard let activeTabID else {
            return nil
        }
        return workspaceTabs.firstIndex { $0.id == activeTabID }
    }

    private var firstDirtyEditorFile: FileTreeItem? {
        for tab in workspaceTabs {
            guard let file = dirtyFile(for: tab) else {
                continue
            }
            return file
        }
        return dirtyEditorFiles.values.first
    }

    private var dirtyEditorFileCount: Int {
        dirtyEditorFiles.count
    }

    private func dirtyFile(for tab: WorkspaceTab) -> FileTreeItem? {
        guard let key = tab.relativePathKey else {
            return nil
        }
        return dirtyEditorFiles[key]
    }

    private func clearDirtyState(for file: FileTreeItem) {
        guard let key = WorkspacePathIdentity.key(for: file) else {
            return
        }
        dirtyEditorFiles.removeValue(forKey: key)
    }

    private func appendFileTab(_ file: FileTreeItem) {
        let tab = WorkspaceTab(file: file)
        workspaceTabs.append(tab)
        activeTabID = tab.id
        selectedFile = file
        workspaceSelection = .note(file)
    }

    private func closeTab(at index: Int) {
        guard workspaceTabs.indices.contains(index) else {
            return
        }
        let tab = workspaceTabs.remove(at: index)
        if let key = tab.relativePathKey {
            recentlyClosedTabs.append(WorkspaceTabClosedEntry(relativePathKey: key, originalIndex: index))
            if recentlyClosedTabs.count > Self.maxRecentlyClosedTabs {
                recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.maxRecentlyClosedTabs)
            }
        }

        if activeTabID == tab.id {
            if workspaceTabs.indices.contains(index) {
                activeTabID = workspaceTabs[index].id
            } else if let last = workspaceTabs.last {
                activeTabID = last.id
            } else {
                activeTabID = nil
            }
            selectedFile = activeTab?.file
            if workspaceSelection != .graph {
                workspaceSelection = selectedFile.map(WorkspaceSelection.note) ?? .empty
            }
        }

        clearAllDirtyWarnings()
        persistWorkspaceTabSession()
    }

    private func removeEmptyTab(id: WorkspaceTab.ID) {
        guard let index = workspaceTabs.firstIndex(where: { $0.id == id && $0.isEmpty }) else {
            return
        }
        workspaceTabs.remove(at: index)
    }

    private func resetWorkspaceState() {
        selectedFile = nil
        workspaceSelection = .empty
        workspaceTabs = []
        activeTabID = nil
        recentlyClosedTabs = []
        dirtyEditorFiles.removeAll()
        activeEditorBufferProvider = nil
    }

    private func restoreWorkspaceTabSession(for vaultURL: URL) {
        guard let session = workspaceTabSessionStore.loadSession(forVaultAt: vaultURL) else {
            return
        }

        let restoredKeys = cappedRestoreKeys(from: session)
            .filter { fileExistsInVault(relativePathKey: $0, vaultURL: vaultURL) }
        guard !restoredKeys.isEmpty else {
            return
        }

        workspaceTabs = restoredKeys.map { WorkspaceTab(file: FileTreeItem(relativePath: $0)) }
        if let activeKey = session.activeRelativePath,
           let activeTab = workspaceTabs.first(where: { $0.relativePathKey == activeKey }) {
            activeTabID = activeTab.id
        } else {
            activeTabID = workspaceTabs.first?.id
        }
        selectedFile = activeTab?.file
        workspaceSelection = selectedFile.map(WorkspaceSelection.note) ?? .empty
    }

    private func cappedRestoreKeys(from session: WorkspaceTabSession) -> [String] {
        let keys = session.tabs
        guard keys.count > Self.maxRestoredTabs else {
            return keys
        }
        guard let activeKey = session.activeRelativePath,
              let activeIndex = keys.firstIndex(of: activeKey)
        else {
            return Array(keys.prefix(Self.maxRestoredTabs))
        }

        let halfWindow = Self.maxRestoredTabs / 2
        let start = max(0, min(activeIndex - halfWindow, keys.count - Self.maxRestoredTabs))
        return Array(keys[start..<(start + Self.maxRestoredTabs)])
    }

    private func fileExistsInVault(relativePathKey: String, vaultURL: URL) -> Bool {
        guard let key = WorkspacePathIdentity.canonicalRelativePath(relativePathKey) else {
            return false
        }
        let rootURL = vaultURL.standardizedFileURL
        let fileURL = rootURL.appendingPathComponent(key, isDirectory: false).standardizedFileURL
        guard fileURL.path.hasPrefix("\(rootURL.path)/") else {
            return false
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private func persistWorkspaceTabSession() {
        guard let vaultURL = vaultSelection.url else {
            return
        }
        let keys = workspaceTabs.compactMap(\.relativePathKey)
        guard !keys.isEmpty else {
            workspaceTabSessionStore.clearSession(forVaultAt: vaultURL)
            return
        }
        let session = WorkspaceTabSession(
            tabs: keys,
            activeRelativePath: activeTab?.relativePathKey
        )
        workspaceTabSessionStore.saveSession(session, forVaultAt: vaultURL)
    }

    private func restoreWorkspacePaneLayout(for vaultURL: URL) {
        workspacePaneLayout = paneLayoutStore.restoreLayout(forVaultAt: vaultURL)
    }

    private func clearAllDirtyWarnings() {
        dirtyNavigationWarning = nil
        dirtyLifecycleWarning = nil
        dirtyEditorActionWarning = nil
        dirtyTabCloseWarning = nil
    }

    private func setDirtyNavigationWarning(_ warning: DirtyNavigationWarning) {
        dirtyNavigationWarning = warning
        dirtyLifecycleWarning = nil
        dirtyEditorActionWarning = nil
        dirtyTabCloseWarning = nil
    }

    private func setDirtyLifecycleWarning(_ warning: DirtyLifecycleWarning) {
        dirtyNavigationWarning = nil
        dirtyLifecycleWarning = warning
        dirtyEditorActionWarning = nil
        dirtyTabCloseWarning = nil
    }

    private func setDirtyEditorActionWarning(_ warning: DirtyEditorActionWarning) {
        dirtyNavigationWarning = nil
        dirtyLifecycleWarning = nil
        dirtyEditorActionWarning = warning
        dirtyTabCloseWarning = nil
    }

    private func setDirtyTabCloseWarning(_ warning: DirtyTabCloseWarning) {
        dirtyNavigationWarning = nil
        dirtyLifecycleWarning = nil
        dirtyEditorActionWarning = nil
        dirtyTabCloseWarning = warning
    }

    private func resetReadClient(availability: ReadAvailability) {
        readClient?.close()
        readClient = nil
        readGeneration &+= 1
        readAvailability = availability
    }

    private func openReadClient(vaultURL: URL, location: AppOwnedIndexLocation) {
        do {
            readClient = try readClientFactory(
                location.metadataStoreFile,
                location.tantivyIndexDirectory
            )
            readAvailability = .ready
        } catch {
            guard Self.shouldRebuildReadIndex(after: error) else {
                readAvailability = .error(Self.readErrorMessage(error))
                return
            }

            do {
                try readIndexRebuilder.rebuildIndex(vaultURL: vaultURL, location: location)
                readClient = try readClientFactory(
                    location.metadataStoreFile,
                    location.tantivyIndexDirectory
                )
                readAvailability = .ready
            } catch {
                readClient = nil
                readAvailability = .error(Self.readIndexRecoveryErrorMessage(error))
            }
        }
    }

    private func readAvailability(for issue: VaultAccessIssue) -> ReadAvailability {
        if case .staleBookmark = issue {
            return .stale
        }
        return .unavailable
    }

    private static func shouldRebuildReadIndex(after error: any Error) -> Bool {
        guard case EngineReadClientError.engine(let payload) = error else {
            return false
        }
        return recoverableReadOpenErrorCodes.contains(payload.code)
    }

    private static func readErrorMessage(_ error: any Error) -> String {
        let description = String(describing: error)
        return description.isEmpty ? "read client unavailable" : description
    }

    private static func readIndexRecoveryErrorMessage(_ error: any Error) -> String {
        if case EngineReadClientError.engine(let payload) = error {
            return "read index rebuild failed: \(payload.message)"
        }
        let description = String(describing: error)
        if description.isEmpty {
            return "read index rebuild failed"
        }
        return "read index rebuild failed: \(description)"
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

    private static let maxRecentlyClosedTabs = 25
    private static let maxRestoredTabs = 25
    private static let recoverableReadOpenErrorCodes: Set<String> = [
        "missing_metadata",
        "missing_tantivy_index",
        "schema_mismatch",
        "backend_mismatch"
    ]
}

private struct ActiveEditorBufferProvider {
    let descriptor: ActiveEditorBufferDescriptor
    let provider: () -> String
}
