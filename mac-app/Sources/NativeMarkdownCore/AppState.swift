import Foundation

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
    @Published public private(set) var fileTreeOverlayRevision: UInt64
    @Published public private(set) var fileTreeOverlayItems: [FileTreeItem]
    @Published public private(set) var fileTreeOverlayFolderPaths: [String]
    @Published public private(set) var fileTreeOverlayRemovedItemIDs: Set<String>
    @Published public private(set) var fileTreeOverlayRemovedFolderPaths: Set<String>
    @Published public private(set) var fileTreeCollapseRequestID: UInt64
    @Published public private(set) var fileTreeSortMode: FileTreeSortMode

    private let indexDirectoryResolver: any IndexDirectoryResolving
    private let vaultAccessValidator: any VaultAccessValidating
    private let recentVaultStorage: any RecentVaultStoring
    private let startupVaultRestoreStorage: any StartupVaultRestoreStoring
    private let workspaceTabSessionStore: any WorkspaceTabSessionStoring
    private let paneLayoutStore: PaneLayoutStore
    private let fileTreeSortModeStore: any FileTreeSortModeStoring
    private let readClientFactory: ReadClientFactory
    private let readIndexRebuilder: any ReadIndexRebuilding
    private let readIndexRecoveryScheduler: any ReadIndexRecoveryScheduling
    private let vaultChangeWatcher: any VaultChangeWatching
    private let vaultIndexRefreshScheduler: any VaultIndexRefreshScheduling
    private let vaultIndexRefreshDebounceInterval: TimeInterval
    private let maxRecentVaults: Int
    private static let maxNavigationHistoryEntries = 100
    private var nextSearchRequestID: UInt64 = 0
    private var didAttemptLastVaultAutoRestore = false
    private var dirtyEditorFiles: [String: FileTreeItem] = [:]
    private var activeEditorBufferProvider: ActiveEditorBufferProvider?
    private var activeVaultChangeWatch: (any VaultChangeWatch)?
    private var readIndexRecoveryInProgress = false
    private var pendingReadIndexRefresh = false

    public init(
        vaultSelection: VaultSelectionState = .noVault,
        engineHealth: EngineHealthStatus = EngineHealthClient().load(),
        indexDirectoryResolver: any IndexDirectoryResolving = AppOwnedIndexDirectoryResolver(),
        vaultAccessValidator: any VaultAccessValidating = FileSystemVaultAccessValidator(),
        recentVaultStorage: any RecentVaultStoring = UserDefaultsRecentVaultStorage(),
        startupVaultRestoreStorage: any StartupVaultRestoreStoring = UserDefaultsStartupVaultRestoreStorage(),
        workspaceTabSessionStore: any WorkspaceTabSessionStoring = UserDefaultsWorkspaceTabSessionStore(),
        workspacePaneLayoutStore: any WorkspacePaneLayoutStoring = UserDefaultsWorkspacePaneLayoutStore(),
        fileTreeSortModeStore: any FileTreeSortModeStoring = UserDefaultsFileTreeSortModeStore(),
        readClientFactory: @escaping ReadClientFactory = { metadataURL, tantivyURL in
            try EngineReadClient.open(metadataURL: metadataURL, tantivyURL: tantivyURL)
        },
        readIndexRebuilder: any ReadIndexRebuilding = EngineReadIndexRebuilder(),
        readIndexRecoveryScheduler: any ReadIndexRecoveryScheduling = BackgroundReadIndexRecoveryScheduler(),
        vaultChangeWatcher: any VaultChangeWatching = FSEventsVaultChangeWatcher(),
        vaultIndexRefreshScheduler: any VaultIndexRefreshScheduling = DispatchVaultIndexRefreshScheduler(),
        vaultIndexRefreshDebounceInterval: TimeInterval = 1.0,
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
        self.fileTreeSortModeStore = fileTreeSortModeStore
        self.readClientFactory = readClientFactory
        self.readIndexRebuilder = readIndexRebuilder
        self.readIndexRecoveryScheduler = readIndexRecoveryScheduler
        self.vaultChangeWatcher = vaultChangeWatcher
        self.vaultIndexRefreshScheduler = vaultIndexRefreshScheduler
        self.vaultIndexRefreshDebounceInterval = vaultIndexRefreshDebounceInterval
        self.maxRecentVaults = max(1, maxRecentVaults)
        self.readAvailability = .unavailable
        self.readGeneration = 0
        self.workspaceSelection = .empty
        self.workspaceTabs = []
        self.activeTabID = nil
        self.recentlyClosedTabs = []
        self.workspacePaneLayout = paneLayoutStore.layout
        self.fileTreeOverlayRevision = 0
        self.fileTreeOverlayItems = []
        self.fileTreeOverlayFolderPaths = []
        self.fileTreeOverlayRemovedItemIDs = []
        self.fileTreeOverlayRemovedFolderPaths = []
        self.fileTreeCollapseRequestID = 0
        self.fileTreeSortMode = vaultSelection.url.map(fileTreeSortModeStore.loadSortMode(forVaultAt:)) ?? .nameAscending
        self.recentVaults = Self.normalizedRecentVaults(
            from: recentVaultStorage.loadRecentVaultURLs(),
            limit: self.maxRecentVaults
        )
    }

    deinit {
        stopVaultChangeWatcher()
        vaultIndexRefreshScheduler.cancel()
        readClient?.close()
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
            fileTreeSortMode = fileTreeSortModeStore.loadSortMode(forVaultAt: vaultURL)
            rememberVault(vaultURL)
            startupVaultRestoreStorage.saveSuppressesLastVaultRestore(false)
            return
        }

        let preparedIndexLocation = try indexDirectoryResolver.prepareIndexLocation(forVaultAt: vaultURL)
        resetReadClient(availability: .opening)
        let readOpenGeneration = readGeneration
        indexLocation = preparedIndexLocation
        openReadClient(vaultURL: vaultURL, location: preparedIndexLocation, generation: readOpenGeneration)
        vaultSelection = .selected(vaultURL)
        startVaultChangeWatcher(for: vaultURL)
        resetWorkspaceState()
        restoreWorkspacePaneLayout(for: vaultURL)
        fileTreeSortMode = fileTreeSortModeStore.loadSortMode(forVaultAt: vaultURL)
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

    @discardableResult
    public func requestCurrentVaultIndexRebuild() -> Bool {
        guard let vaultURL = vaultSelection.url,
              let location = indexLocation
        else {
            return false
        }

        let timer = AppTelemetryTimer()
        scheduleReadIndexRecovery(
            vaultURL: vaultURL,
            location: location,
            generation: readGeneration,
            incrementsGenerationOnSuccess: true,
            telemetryTimer: timer
        )
        return true
    }

    @discardableResult
    public func scheduleCurrentVaultIndexRefresh() -> Bool {
        guard vaultSelection.url != nil,
              indexLocation != nil
        else {
            return false
        }

        vaultIndexRefreshScheduler.schedule(after: vaultIndexRefreshDebounceInterval) { [weak self] in
            self?.performScheduledVaultIndexRefresh()
        }
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
        fileTreeSortMode = fileTreeSortModeStore.loadSortMode(forVaultAt: vaultURL)
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
        fileTreeSortMode = .nameAscending
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
        fileTreeSortModeStore.clearSortMode(forVaultAt: url)

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

    public func setFileTreeSortMode(_ mode: FileTreeSortMode) {
        guard fileTreeSortMode != mode else {
            return
        }
        fileTreeSortMode = mode
        if let vaultURL = vaultSelection.url {
            fileTreeSortModeStore.saveSortMode(mode, forVaultAt: vaultURL)
        }
    }

    public func requestFileTreeCollapseAll() {
        fileTreeCollapseRequestID &+= 1
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
        openFile(item, disposition: disposition, recordsHistory: true)
    }

    private func openFile(
        _ item: FileTreeItem,
        disposition: WorkspaceTabOpenDisposition,
        recordsHistory: Bool
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
                if recordsHistory,
                   let currentFile = workspaceTabs[activeIndex].file,
                   WorkspacePathIdentity.key(for: currentFile) != requestedKey {
                    appendNavigationHistory(currentFile, toTabAt: activeIndex)
                    workspaceTabs[activeIndex].forwardStack = []
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

    public var activeTabCanNavigateBack: Bool {
        activeTab?.backStack.isEmpty == false
    }

    public var activeTabCanNavigateForward: Bool {
        activeTab?.forwardStack.isEmpty == false
    }

    public var activeTabViewMode: WorkspaceTabViewMode {
        activeTab?.viewMode ?? .livePreview
    }

    public func navigateActiveTabBack() {
        guard let activeIndex = activeTabIndex,
              let currentFile = workspaceTabs[activeIndex].file,
              let previousFile = workspaceTabs[activeIndex].backStack.popLast()
        else {
            return
        }
        appendForwardHistory(currentFile, toTabAt: activeIndex)
        workspaceTabs[activeIndex].replaceFile(previousFile)
        activeTabID = workspaceTabs[activeIndex].id
        selectedFile = previousFile
        workspaceSelection = .note(previousFile)
        clearAllDirtyWarnings()
        persistWorkspaceTabSession()
    }

    public func navigateActiveTabForward() {
        guard let activeIndex = activeTabIndex,
              let currentFile = workspaceTabs[activeIndex].file,
              let nextFile = workspaceTabs[activeIndex].forwardStack.popLast()
        else {
            return
        }
        appendNavigationHistory(currentFile, toTabAt: activeIndex)
        workspaceTabs[activeIndex].replaceFile(nextFile)
        activeTabID = workspaceTabs[activeIndex].id
        selectedFile = nextFile
        workspaceSelection = .note(nextFile)
        clearAllDirtyWarnings()
        persistWorkspaceTabSession()
    }

    public func toggleActiveTabReadingView() {
        guard let activeIndex = activeTabIndex else {
            return
        }
        workspaceTabs[activeIndex].viewMode = workspaceTabs[activeIndex].viewMode == .reading
            ? .livePreview
            : .reading
    }

    public var hasDirtyEditors: Bool {
        firstDirtyEditorFile != nil
    }

    public var isActiveEditorDirty: Bool {
        guard let activeTab else {
            return false
        }
        return dirtyFile(for: activeTab) != nil
    }

    public func discardDirtyChangesForVaultSwitch() {
        dirtyEditorFiles.removeAll()
        clearAllDirtyWarnings()
    }

    public func registerCreatedFileTreeItem(_ item: FileTreeItem) {
        guard !fileTreeOverlayItems.contains(where: { $0.id == item.id }) else {
            return
        }
        fileTreeOverlayItems.append(item)
        fileTreeOverlayRevision &+= 1
    }

    public func registerCreatedFileTreeFolder(path: String) {
        guard !path.isEmpty,
              !fileTreeOverlayFolderPaths.contains(path)
        else {
            return
        }
        fileTreeOverlayFolderPaths.append(path)
        fileTreeOverlayRevision &+= 1
    }

    private func clearFileTreeCreationOverlays() {
        guard !fileTreeOverlayItems.isEmpty ||
            !fileTreeOverlayFolderPaths.isEmpty ||
            !fileTreeOverlayRemovedItemIDs.isEmpty ||
            !fileTreeOverlayRemovedFolderPaths.isEmpty
        else {
            return
        }
        fileTreeOverlayItems = []
        fileTreeOverlayFolderPaths = []
        fileTreeOverlayRemovedItemIDs = []
        fileTreeOverlayRemovedFolderPaths = []
        fileTreeOverlayRevision &+= 1
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

    public func dirtyFileBlockingOperation(file: FileTreeItem) -> FileTreeItem? {
        guard let key = WorkspacePathIdentity.key(for: file) else {
            return nil
        }
        return dirtyEditorFiles[key]
    }

    public func dirtyFileBlockingOperation(folderPath: String) -> FileTreeItem? {
        let prefix = folderPath.isEmpty ? "" : "\(folderPath)/"
        return dirtyEditorFiles.values.first { file in
            file.relativePath == folderPath || file.relativePath.hasPrefix(prefix)
        }
    }

    public func applyRenamedFile(_ result: VaultFileOperationResult) {
        applyFilePathChange(oldFile: result.oldFile, newFile: result.newFile)
    }

    public func applyMovedFile(_ result: VaultFileOperationResult) {
        applyFilePathChange(oldFile: result.oldFile, newFile: result.newFile)
    }

    public func applyDeletedFile(_ file: FileTreeItem) {
        guard let oldKey = WorkspacePathIdentity.key(for: file) else {
            return
        }
        fileTreeOverlayItems.removeAll { $0.id == oldKey }
        fileTreeOverlayRemovedItemIDs.insert(oldKey)
        removeTabs { $0 == file }
        removeDeletedFileFromHistory(file)
        dirtyEditorFiles.removeValue(forKey: oldKey)
        if selectedFile?.id == oldKey {
            selectedFile = activeTab?.file
            workspaceSelection = selectedFile.map(WorkspaceSelection.note) ?? .empty
        }
        clearActiveEditorBufferIfNeeded(fileID: oldKey)
        fileTreeOverlayRevision &+= 1
        _ = requestCurrentVaultIndexRebuild()
    }

    public func applyRenamedFolder(oldPath: String, newPath: String, movedFiles: [FileTreeItem] = []) {
        applyFolderPathChange(oldPath: oldPath, newPath: newPath, movedFiles: movedFiles)
    }

    public func applyMovedFolder(oldPath: String, newPath: String, movedFiles: [FileTreeItem] = []) {
        applyFolderPathChange(oldPath: oldPath, newPath: newPath, movedFiles: movedFiles)
    }

    public func applyDeletedFolder(path: String) {
        guard !path.isEmpty else {
            return
        }
        let prefix = "\(path)/"
        fileTreeOverlayItems.removeAll { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }
        fileTreeOverlayFolderPaths.removeAll { $0 == path || $0.hasPrefix(prefix) }
        fileTreeOverlayRemovedFolderPaths.insert(path)
        removeTabs { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }
        removeDeletedFolderFromHistory(path: path)
        dirtyEditorFiles = dirtyEditorFiles.filter { _, file in
            !(file.relativePath == path || file.relativePath.hasPrefix(prefix))
        }
        if selectedFile.map({ $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }) == true {
            selectedFile = activeTab?.file
            workspaceSelection = selectedFile.map(WorkspaceSelection.note) ?? .empty
        }
        activeEditorBufferProvider = nil
        fileTreeOverlayRevision &+= 1
        _ = requestCurrentVaultIndexRebuild()
        persistWorkspaceTabSession()
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

    private func applyFilePathChange(oldFile: FileTreeItem, newFile: FileTreeItem) {
        guard let oldKey = WorkspacePathIdentity.key(for: oldFile),
              let newKey = WorkspacePathIdentity.key(for: newFile),
              oldKey != newKey
        else {
            return
        }

        fileTreeOverlayRemovedItemIDs.insert(oldKey)
        fileTreeOverlayItems.removeAll { $0.id == oldKey || $0.id == newKey }
        fileTreeOverlayItems.append(newFile)
        replaceFileReferences(oldFile: oldFile, newFile: newFile)
        if let dirtyFile = dirtyEditorFiles.removeValue(forKey: oldKey) {
            dirtyEditorFiles[newKey] = FileTreeItem(relativePath: newKey)
            if dirtyFile.id == selectedFile?.id {
                selectedFile = newFile
            }
        }
        if selectedFile?.id == oldKey {
            selectedFile = newFile
            workspaceSelection = .note(newFile)
        }
        clearActiveEditorBufferIfNeeded(fileID: oldKey)
        fileTreeOverlayRevision &+= 1
        _ = requestCurrentVaultIndexRebuild()
        persistWorkspaceTabSession()
    }

    private func applyFolderPathChange(oldPath: String, newPath: String, movedFiles: [FileTreeItem]) {
        guard !oldPath.isEmpty,
              let oldKey = WorkspacePathIdentity.canonicalRelativePath(oldPath),
              let newKey = WorkspacePathIdentity.canonicalRelativePath(newPath),
              oldKey != newKey
        else {
            return
        }

        fileTreeOverlayRemovedFolderPaths.insert(oldKey)
        fileTreeOverlayFolderPaths.removeAll { $0 == oldKey || $0.hasPrefix("\(oldKey)/") || $0 == newKey }
        fileTreeOverlayFolderPaths.append(newKey)

        let oldPrefix = "\(oldKey)/"
        let newPrefix = "\(newKey)/"
        fileTreeOverlayItems = fileTreeOverlayItems.compactMap { item in
            if item.relativePath == oldKey {
                return nil
            }
            guard item.relativePath.hasPrefix(oldPrefix) else {
                return item
            }
            return FileTreeItem(relativePath: newPrefix + String(item.relativePath.dropFirst(oldPrefix.count)))
        }
        for movedFile in movedFiles where !fileTreeOverlayItems.contains(where: { $0.id == movedFile.id }) {
            fileTreeOverlayItems.append(movedFile)
        }

        workspaceTabs = workspaceTabs.map { tab in
            rewriteTab(tab, oldPrefix: oldPrefix, newPrefix: newPrefix)
        }
        dirtyEditorFiles = Dictionary(uniqueKeysWithValues: dirtyEditorFiles.values.map { file in
            let updated = rewriteFile(file, oldPrefix: oldPrefix, newPrefix: newPrefix)
            return (WorkspacePathIdentity.key(for: updated) ?? updated.relativePath, updated)
        })
        if let selectedFile {
            let updated = rewriteFile(selectedFile, oldPrefix: oldPrefix, newPrefix: newPrefix)
            if updated != selectedFile {
                self.selectedFile = updated
                workspaceSelection = .note(updated)
            }
        }
        activeEditorBufferProvider = nil
        fileTreeOverlayRevision &+= 1
        _ = requestCurrentVaultIndexRebuild()
        persistWorkspaceTabSession()
    }

    private func replaceFileReferences(oldFile: FileTreeItem, newFile: FileTreeItem) {
        workspaceTabs = workspaceTabs.map { tab in
            var updated = tab
            if tab.file == oldFile {
                updated.replaceFile(newFile)
            }
            updated.backStack = tab.backStack.map { $0 == oldFile ? newFile : $0 }
            updated.forwardStack = tab.forwardStack.map { $0 == oldFile ? newFile : $0 }
            return updated
        }
    }

    private func rewriteTab(_ tab: WorkspaceTab, oldPrefix: String, newPrefix: String) -> WorkspaceTab {
        var updated = tab
        if let file = tab.file {
            updated.replaceFile(rewriteFile(file, oldPrefix: oldPrefix, newPrefix: newPrefix))
        }
        updated.backStack = tab.backStack.map { rewriteFile($0, oldPrefix: oldPrefix, newPrefix: newPrefix) }
        updated.forwardStack = tab.forwardStack.map { rewriteFile($0, oldPrefix: oldPrefix, newPrefix: newPrefix) }
        return updated
    }

    private func rewriteFile(_ file: FileTreeItem, oldPrefix: String, newPrefix: String) -> FileTreeItem {
        guard file.relativePath.hasPrefix(oldPrefix) else {
            return file
        }
        return FileTreeItem(relativePath: newPrefix + String(file.relativePath.dropFirst(oldPrefix.count)))
    }

    private func removeTabs(matching shouldRemove: (FileTreeItem) -> Bool) {
        let previousActiveID = activeTabID
        let previousActiveIndex = activeTabIndex
        workspaceTabs.removeAll { tab in
            guard let file = tab.file else {
                return false
            }
            return shouldRemove(file)
        }

        if workspaceTabs.isEmpty {
            activeTabID = nil
            selectedFile = nil
            workspaceSelection = .empty
            persistWorkspaceTabSession()
            return
        }

        if previousActiveID.map({ id in workspaceTabs.contains { $0.id == id } }) == true {
            activeTabID = previousActiveID
        } else {
            let fallbackIndex = min(previousActiveIndex ?? 0, workspaceTabs.count - 1)
            activeTabID = workspaceTabs[fallbackIndex].id
        }
        selectedFile = activeTab?.file
        if workspaceSelection != .graph {
            workspaceSelection = selectedFile.map(WorkspaceSelection.note) ?? .empty
        }
        persistWorkspaceTabSession()
    }

    private func removeDeletedFileFromHistory(_ file: FileTreeItem) {
        workspaceTabs = workspaceTabs.map { tab in
            var updated = tab
            updated.backStack.removeAll { $0 == file }
            updated.forwardStack.removeAll { $0 == file }
            return updated
        }
    }

    private func removeDeletedFolderFromHistory(path: String) {
        let prefix = "\(path)/"
        workspaceTabs = workspaceTabs.map { tab in
            var updated = tab
            updated.backStack.removeAll { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }
            updated.forwardStack.removeAll { $0.relativePath == path || $0.relativePath.hasPrefix(prefix) }
            return updated
        }
    }

    private func clearActiveEditorBufferIfNeeded(fileID: String) {
        guard activeEditorBufferProvider?.descriptor.fileID == fileID else {
            return
        }
        activeEditorBufferProvider = nil
    }

    private func appendNavigationHistory(_ file: FileTreeItem, toTabAt index: Int) {
        guard workspaceTabs.indices.contains(index) else {
            return
        }
        if workspaceTabs[index].backStack.last != file {
            workspaceTabs[index].backStack.append(file)
        }
        capNavigationHistory(&workspaceTabs[index].backStack)
    }

    private func appendForwardHistory(_ file: FileTreeItem, toTabAt index: Int) {
        guard workspaceTabs.indices.contains(index) else {
            return
        }
        if workspaceTabs[index].forwardStack.last != file {
            workspaceTabs[index].forwardStack.append(file)
        }
        capNavigationHistory(&workspaceTabs[index].forwardStack)
    }

    private func capNavigationHistory(_ stack: inout [FileTreeItem]) {
        guard stack.count > Self.maxNavigationHistoryEntries else {
            return
        }
        stack.removeFirst(stack.count - Self.maxNavigationHistoryEntries)
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
        fileTreeOverlayItems = []
        fileTreeOverlayFolderPaths = []
        fileTreeOverlayRemovedItemIDs = []
        fileTreeOverlayRemovedFolderPaths = []
        fileTreeOverlayRevision &+= 1
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
        stopVaultChangeWatcher()
        vaultIndexRefreshScheduler.cancel()
        readIndexRecoveryInProgress = false
        pendingReadIndexRefresh = false
        readClient?.close()
        readClient = nil
        readGeneration &+= 1
        readAvailability = availability
    }

    private func startVaultChangeWatcher(for vaultURL: URL) {
        stopVaultChangeWatcher()
        do {
            activeVaultChangeWatch = try vaultChangeWatcher.startWatching(vaultURL: vaultURL) { [weak self] in
                _ = self?.scheduleCurrentVaultIndexRefresh()
            }
        } catch {
            activeVaultChangeWatch = nil
        }
    }

    private func stopVaultChangeWatcher() {
        activeVaultChangeWatch?.cancel()
        activeVaultChangeWatch = nil
    }

    private func performScheduledVaultIndexRefresh() {
        _ = requestCurrentVaultIndexRebuild()
    }

    private func openReadClient(
        vaultURL: URL,
        location: AppOwnedIndexLocation,
        generation: UInt64
    ) {
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

            scheduleReadIndexRecovery(
                vaultURL: vaultURL,
                location: location,
                generation: generation,
                incrementsGenerationOnSuccess: false,
                telemetryTimer: nil
            )
        }
    }

    private func scheduleReadIndexRecovery(
        vaultURL: URL,
        location: AppOwnedIndexLocation,
        generation: UInt64,
        incrementsGenerationOnSuccess: Bool,
        telemetryTimer: AppTelemetryTimer?
    ) {
        if readIndexRecoveryInProgress {
            pendingReadIndexRefresh = true
            return
        }

        readIndexRecoveryInProgress = true
        let completionSink = ReadIndexRecoveryCompletionSink(owner: self)
        readIndexRecoveryScheduler.schedule { [readIndexRebuilder] in
            Result {
                try readIndexRebuilder.rebuildIndex(vaultURL: vaultURL, location: location)
            }
        } completion: { [completionSink] result in
            completionSink.finish(
                result,
                vaultURL: vaultURL,
                location: location,
                generation: generation,
                incrementsGenerationOnSuccess: incrementsGenerationOnSuccess,
                telemetryTimer: telemetryTimer
            )
        }
    }

    fileprivate func finishReadIndexRecovery(
        _ result: Result<Void, any Error>,
        vaultURL: URL,
        location: AppOwnedIndexLocation,
        generation: UInt64,
        incrementsGenerationOnSuccess: Bool,
        telemetryTimer: AppTelemetryTimer?
    ) {
        guard readGeneration == generation,
              vaultSelection == .selected(vaultURL),
              indexLocation == location
        else {
            return
        }

        readIndexRecoveryInProgress = false
        do {
            try result.get()
            readClient?.close()
            readClient = try readClientFactory(
                location.metadataStoreFile,
                location.tantivyIndexDirectory
            )
            readAvailability = .ready
            if incrementsGenerationOnSuccess {
                readGeneration &+= 1
                clearFileTreeCreationOverlays()
            }
            if let telemetryTimer {
                AppTelemetry.vaultCreationCompleted(
                    operation: .indexRebuild,
                    result: "success",
                    durationMilliseconds: telemetryTimer.elapsedMilliseconds()
                )
            }
        } catch {
            if !incrementsGenerationOnSuccess {
                readClient = nil
                readAvailability = .error(Self.readIndexRecoveryErrorMessage(error))
            }
            if let telemetryTimer {
                AppTelemetry.vaultCreationCompleted(
                    operation: .indexRebuild,
                    result: "failure",
                    durationMilliseconds: telemetryTimer.elapsedMilliseconds()
                )
            }
        }

        schedulePendingReadIndexRefreshIfNeeded()
    }

    private func schedulePendingReadIndexRefreshIfNeeded() {
        guard pendingReadIndexRefresh,
              let vaultURL = vaultSelection.url,
              let location = indexLocation
        else {
            pendingReadIndexRefresh = false
            return
        }

        pendingReadIndexRefresh = false
        scheduleReadIndexRecovery(
            vaultURL: vaultURL,
            location: location,
            generation: readGeneration,
            incrementsGenerationOnSuccess: true,
            telemetryTimer: AppTelemetryTimer()
        )
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

private final class ReadIndexRecoveryCompletionSink: @unchecked Sendable {
    private weak var owner: AppState?

    init(owner: AppState) {
        self.owner = owner
    }

    func finish(
        _ result: Result<Void, any Error>,
        vaultURL: URL,
        location: AppOwnedIndexLocation,
        generation: UInt64,
        incrementsGenerationOnSuccess: Bool,
        telemetryTimer: AppTelemetryTimer?
    ) {
        owner?.finishReadIndexRecovery(
            result,
            vaultURL: vaultURL,
            location: location,
            generation: generation,
            incrementsGenerationOnSuccess: incrementsGenerationOnSuccess,
            telemetryTimer: telemetryTimer
        )
    }
}
