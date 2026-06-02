import AppKit
import NativeMarkdownCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppContentZoom.storageKey) private var rawAppContentZoomScale = AppContentZoom.defaultScale
    @State private var leftPanel: ObsidianLeftPanel = .files
    @State private var selectedInspectorPanel: NoteInspectorPanel = .backlinks
    @State private var vaultSelectionError: String?
    @State private var presentedSheet: RootSheet?
    @State private var selectedFileTreeFolderPath: String?
    @State private var vaultCreationError: String?
    @State private var vaultItemCreationError: String?
    @State private var pendingVaultCreationRequest: VaultCreationRequest?

    var body: some View {
        GeometryReader { geometry in
            let appZoomScale = appContentZoomScale
            HStack(spacing: 0) {
                ObsidianRibbonView(
                    selectedPanel: $leftPanel,
                    graphIsActive: appState.workspaceSelection == .graph,
                    selectLeftPanel: selectLeftPanel,
                    openVault: openVaultPanel,
                    openGraph: openGraphFromRibbon,
                    showHelp: showHelp,
                    showSettings: showSettings
                )

                Divider()

                if !appState.workspacePaneLayout.isLeftSidebarCollapsed {
                    ObsidianLeftSidebar(
                        selectedPanel: $leftPanel,
                        showVaultPicker: showVaultPicker,
                        revealVaultInFinder: revealVaultInFinder,
                        createNote: { presentVaultItemCreation(.note) },
                        createFolder: { presentVaultItemCreation(.folder) },
                        closeVault: closeVault,
                        collapseSidebar: appState.toggleLeftSidebarCollapsed,
                        vaultSelectionError: vaultSelectionError,
                        selectedFolderPath: $selectedFileTreeFolderPath
                    )
                    .frame(width: ObsidianUI.displayedPaneWidth(
                        logicalWidth: appState.workspacePaneLayout.leftSidebarWidth,
                        scale: appZoomScale
                    ))

                    ObsidianPaneSplitHandle(
                        side: .left,
                        currentWidth: appState.workspacePaneLayout.leftSidebarWidth,
                        appContentZoomScale: appZoomScale
                    ) { proposedWidth in
                        appState.setLeftSidebarWidth(
                            proposedWidth,
                            availableWidth: workspaceAvailableWidth(in: geometry, scale: appZoomScale)
                        )
                    }
                }

                ObsidianWorkspaceDetail(
                    closeTab: closeTab,
                    moveTab: appState.moveTab(from:to:),
                    newTab: newTab,
                    showsRightSidebarToggle: appState.workspaceSelection != .graph,
                    isRightSidebarCollapsed: appState.workspacePaneLayout.isRightSidebarCollapsed,
                    toggleRightSidebar: appState.toggleRightSidebarCollapsed
                )

                if showsRightSidebar {
                    ObsidianPaneSplitHandle(
                        side: .right,
                        currentWidth: appState.workspacePaneLayout.rightSidebarWidth,
                        appContentZoomScale: appZoomScale
                    ) { proposedWidth in
                        appState.setRightSidebarWidth(
                            proposedWidth,
                            availableWidth: workspaceAvailableWidth(in: geometry, scale: appZoomScale)
                        )
                    }

                    ObsidianRightSidebar(selectedPanel: $selectedInspectorPanel)
                        .frame(width: ObsidianUI.displayedPaneWidth(
                            logicalWidth: appState.workspacePaneLayout.rightSidebarWidth,
                            scale: appZoomScale
                        ))
                }
            }
            .background(ObsidianUI.editorBackground)
        }
        .environment(\.appContentZoomScale, appContentZoomScale)
        .alert("Unsaved Changes", isPresented: dirtyNavigationAlertBinding) {
            Button("Stay", role: .cancel) {
                appState.dismissDirtyNavigationWarning()
            }
            Button("Discard and Open", role: .destructive) {
                appState.discardDirtyChangesAndOpenRequestedFile()
            }
        } message: {
            Text(dirtyNavigationMessage)
        }
        .alert("Unsaved Changes", isPresented: dirtyLifecycleAlertBinding) {
            Button("Stay", role: .cancel) {
                appState.dismissDirtyLifecycleWarning()
            }
            Button(dirtyLifecycleDestructiveTitle, role: .destructive) {
                if let action = appState.discardDirtyChangesForLifecycleWarning() {
                    AppLifecycleController.shared.performDiscardedLifecycleAction(action)
                }
            }
        } message: {
            Text(dirtyLifecycleMessage)
        }
        .alert("Unsaved Changes", isPresented: dirtyEditorActionAlertBinding) {
            Button("Stay", role: .cancel) {
                appState.dismissDirtyEditorActionWarning()
            }
            Button(dirtyEditorActionDestructiveTitle, role: .destructive) {
                appState.discardDirtyChangesForEditorActionWarning()
            }
        } message: {
            Text(dirtyEditorActionMessage)
        }
        .alert("Unsaved Changes", isPresented: dirtyTabCloseAlertBinding) {
            Button("Stay", role: .cancel) {
                appState.dismissDirtyTabCloseWarning()
            }
            Button("Discard and Close", role: .destructive) {
                appState.discardDirtyChangesForTabCloseWarning()
            }
        } message: {
            Text(dirtyTabCloseMessage)
        }
        .alert("Unsaved Changes", isPresented: pendingVaultCreationAlertBinding) {
            Button("Stay", role: .cancel) {
                pendingVaultCreationRequest = nil
            }
            Button("Discard and Create", role: .destructive) {
                guard let request = pendingVaultCreationRequest else {
                    return
                }
                pendingVaultCreationRequest = nil
                appState.discardDirtyChangesForVaultSwitch()
                _ = performVaultCreation(request)
            }
        } message: {
            Text("There are unsaved changes in open tabs. Discard them and create the new vault?")
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .help:
                GraniteHelpView(dismiss: dismissPresentedSheet)
                .frame(width: 420, height: 320)
            case .vaultPicker:
                VaultPickerView(
                    closeVault: closeVault,
                    createVault: presentVaultCreation,
                    dismiss: dismissPresentedSheet
                )
                    .environmentObject(appState)
                    .frame(width: 360, height: 460)
            case .createVault:
                VaultCreationSheet(
                    error: $vaultCreationError,
                    submit: submitVaultCreation,
                    cancel: dismissPresentedSheet
                )
                .frame(width: 460, height: 300)
            case .createItem(let kind, let defaultName):
                VaultItemCreationSheet(
                    kind: kind,
                    defaultName: defaultName,
                    error: $vaultItemCreationError,
                    submit: { submitVaultItemCreation(kind: kind, name: $0) },
                    cancel: dismissPresentedSheet
                )
                .frame(width: 360, height: 190)
            }
        }
        .background(DirtyLifecycleWindowGuard())
        .background(WorkspaceTabKeyCommandGuard(action: workspaceTabAction))
        .focusedValue(\.workspaceTabAction, workspaceTabAction)
        .focusedValue(\.vaultCommandAction, vaultCommandAction)
        .onAppear {
            AppLifecycleController.shared.appState = appState
            restoreLastVaultOnLaunch()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
    }

    private var showsRightSidebar: Bool {
        appState.workspaceSelection != .graph && !appState.workspacePaneLayout.isRightSidebarCollapsed
    }

    private var appContentZoomScale: Double {
        AppContentZoom(rawScale: rawAppContentZoomScale).scale
    }

    private func workspaceAvailableWidth(in geometry: GeometryProxy, scale: Double) -> Double {
        ObsidianUI.logicalWorkspaceAvailableWidth(displayedWidth: geometry.size.width, scale: scale)
    }

    private var dirtyNavigationAlertBinding: Binding<Bool> {
        Binding {
            appState.dirtyNavigationWarning != nil
        } set: { isPresented in
            if !isPresented {
                appState.dismissDirtyNavigationWarning()
            }
        }
    }

    private var dirtyNavigationMessage: String {
        guard let warning = appState.dirtyNavigationWarning else {
            return ""
        }
        return "Save or discard changes in \(warning.dirtyFile.displayName) before opening \(warning.requestedFile.displayName)."
    }

    private var dirtyLifecycleAlertBinding: Binding<Bool> {
        Binding {
            appState.dirtyLifecycleWarning != nil
        } set: { isPresented in
            if !isPresented {
                appState.dismissDirtyLifecycleWarning()
            }
        }
    }

    private var dirtyLifecycleMessage: String {
        guard let warning = appState.dirtyLifecycleWarning else {
            return ""
        }
        if warning.isAggregate {
            switch warning.action {
            case .closeWindow:
                return "There are unsaved changes in open tabs. Discard them and close this window?"
            case .quitApp:
                return "There are unsaved changes in open tabs. Discard them and quit Granite?"
            }
        }
        switch warning.action {
        case .closeWindow:
            return "Discard unsaved changes in \(warning.dirtyFile.displayName) and close this window?"
        case .quitApp:
            return "Discard unsaved changes in \(warning.dirtyFile.displayName) and quit Granite?"
        }
    }

    private var dirtyLifecycleDestructiveTitle: String {
        switch appState.dirtyLifecycleWarning?.action {
        case .closeWindow:
            return "Discard and Close"
        case .quitApp:
            return "Discard and Quit"
        case nil:
            return "Discard"
        }
    }

    private var dirtyEditorActionAlertBinding: Binding<Bool> {
        Binding {
            appState.dirtyEditorActionWarning != nil
        } set: { isPresented in
            if !isPresented {
                appState.dismissDirtyEditorActionWarning()
            }
        }
    }

    private var dirtyEditorActionMessage: String {
        guard let warning = appState.dirtyEditorActionWarning else {
            return ""
        }
        switch warning.action {
        case .clearSelection:
            return "Discard unsaved changes in \(warning.dirtyFile.displayName) and close this note?"
        case .closeVault:
            if warning.isAggregate {
                return "There are unsaved changes in open tabs. Discard them and close this vault?"
            }
            return "Discard unsaved changes in \(warning.dirtyFile.displayName) and close this vault?"
        }
    }

    private var dirtyEditorActionDestructiveTitle: String {
        switch appState.dirtyEditorActionWarning?.action {
        case .clearSelection:
            return "Discard"
        case .closeVault:
            return "Discard and Close Vault"
        case nil:
            return "Discard"
        }
    }

    private var dirtyTabCloseAlertBinding: Binding<Bool> {
        Binding {
            appState.dirtyTabCloseWarning != nil
        } set: { isPresented in
            if !isPresented {
                appState.dismissDirtyTabCloseWarning()
            }
        }
    }

    private var dirtyTabCloseMessage: String {
        guard let warning = appState.dirtyTabCloseWarning else {
            return ""
        }
        return "Discard unsaved changes in \"\(warning.dirtyFile.displayName)\" and close this tab?"
    }

    private var pendingVaultCreationAlertBinding: Binding<Bool> {
        Binding {
            pendingVaultCreationRequest != nil
        } set: { isPresented in
            if !isPresented {
                pendingVaultCreationRequest = nil
            }
        }
    }

    private func openVaultPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try appState.selectVault(url)
                vaultSelectionError = nil
                leftPanel = .files
            } catch {
                vaultSelectionError = error.localizedDescription
            }
        }
    }

    private func showHelp() {
        presentedSheet = .help
    }

    private func showSettings() {
        openSettings()
    }

    private func showVaultPicker() {
        presentedSheet = .vaultPicker
    }

    private func presentVaultCreation() {
        vaultCreationError = nil
        presentedSheet = .createVault
    }

    private func presentVaultItemCreation(_ kind: VaultItemCreationKind) {
        guard let vaultURL = appState.vaultSelection.url else {
            vaultSelectionError = "Open a vault before creating notes or folders."
            return
        }
        let parentURL = parentFolderURL(in: vaultURL)
        let suggestion = VaultNameSuggestion()
        let defaultName: String
        switch kind {
        case .note:
            defaultName = suggestion.suggestedNoteName(in: parentURL)
        case .folder:
            defaultName = suggestion.suggestedFolderName(in: parentURL)
        }
        vaultItemCreationError = nil
        presentedSheet = .createItem(kind: kind, defaultName: defaultName)
    }

    private func restoreLastVaultOnLaunch() {
        do {
            if try appState.restoreLastVaultOnLaunchIfNeeded() {
                vaultSelectionError = nil
                leftPanel = .files
            }
        } catch {
            vaultSelectionError = error.localizedDescription
        }
    }

    private func dismissPresentedSheet() {
        presentedSheet = nil
        vaultCreationError = nil
        vaultItemCreationError = nil
    }

    private func revealVaultInFinder() {
        guard let url = appState.vaultSelection.url,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func closeVault() {
        presentedSheet = nil
        selectedFileTreeFolderPath = nil
        appState.requestCloseVault()
    }

    private func closeTab(_ tabID: WorkspaceTab.ID) {
        appState.requestCloseTab(tabID)
    }

    private func newTab() {
        appState.newEmptyTab()
    }

    private var workspaceTabAction: WorkspaceTabAction {
        WorkspaceTabAction(
            isAvailable: appState.vaultSelection.url != nil,
            newTab: {
                appState.newEmptyTab()
            },
            closeActiveTab: {
                if appState.workspaceSelection == .graph {
                    appState.closeWorkspaceSelection()
                } else {
                    appState.requestCloseActiveTab()
                }
            },
            restoreClosedTab: {
                appState.restoreRecentlyClosedTab()
            },
            activateNextTab: {
                appState.activateNextTab()
            },
            activatePreviousTab: {
                appState.activatePreviousTab()
            },
            activateTabAtShortcutIndex: { index in
                appState.activateTab(atShortcutIndex: index)
            }
        )
    }

    private var vaultCommandAction: VaultCommandAction {
        VaultCommandAction(newVault: presentVaultCreation)
    }

    private func submitVaultCreation(_ request: VaultCreationRequest) -> Bool {
        vaultCreationError = nil
        guard !appState.hasDirtyEditors else {
            pendingVaultCreationRequest = request
            return false
        }
        return performVaultCreation(request)
    }

    private func performVaultCreation(_ request: VaultCreationRequest) -> Bool {
        let timer = AppTelemetryTimer()
        do {
            let outcome = try VaultCreator().createVault(request)
            try appState.selectVault(outcome.vaultURL)
            _ = appState.openFile(outcome.initialNote, disposition: .currentTab)
            selectedFileTreeFolderPath = nil
            vaultSelectionError = nil
            vaultCreationError = nil
            leftPanel = .files
            presentedSheet = nil
            AppTelemetry.vaultCreationCompleted(
                operation: .createVault,
                result: "success",
                durationMilliseconds: timer.elapsedMilliseconds()
            )
            return true
        } catch {
            vaultCreationError = error.localizedDescription
            AppTelemetry.vaultCreationCompleted(
                operation: .createVault,
                result: "failure",
                durationMilliseconds: timer.elapsedMilliseconds()
            )
            return false
        }
    }

    private func submitVaultItemCreation(kind: VaultItemCreationKind, name: String) -> Bool {
        guard let vaultURL = appState.vaultSelection.url else {
            vaultItemCreationError = "Open a vault before creating notes or folders."
            return false
        }

        let context = creationContext()
        let timer = AppTelemetryTimer()
        do {
            switch kind {
            case .note:
                let item = try VaultItemCreator().createNote(
                    vaultURL: vaultURL,
                    parentFolderPath: context.parentFolderPath,
                    name: name
                )
                appState.registerCreatedFileTreeItem(item)
                let disposition: WorkspaceTabOpenDisposition = appState.isActiveEditorDirty ? .newTab : .currentTab
                _ = appState.openFile(item, disposition: disposition)
            case .folder:
                let folderPath = try VaultItemCreator().createFolder(
                    vaultURL: vaultURL,
                    parentFolderPath: context.parentFolderPath,
                    name: name
                )
                appState.registerCreatedFileTreeFolder(path: folderPath)
                selectedFileTreeFolderPath = folderPath
            }
            _ = appState.requestCurrentVaultIndexRebuild()
            vaultItemCreationError = nil
            presentedSheet = nil
            AppTelemetry.vaultCreationCompleted(
                operation: kind == .note ? .createNote : .createFolder,
                result: "success",
                durationMilliseconds: timer.elapsedMilliseconds()
            )
            return true
        } catch {
            vaultItemCreationError = error.localizedDescription
            AppTelemetry.vaultCreationCompleted(
                operation: kind == .note ? .createNote : .createFolder,
                result: "failure",
                durationMilliseconds: timer.elapsedMilliseconds()
            )
            return false
        }
    }

    private func creationContext() -> VaultCreationContext {
        VaultCreationContext.from(
            selectedFolderPath: selectedFileTreeFolderPath,
            selectedFile: appState.selectedFile
        )
    }

    private func parentFolderURL(in vaultURL: URL) -> URL {
        let parentPath = creationContext().parentFolderPath
        return parentPath.isEmpty
            ? vaultURL
            : vaultURL.appendingPathComponent(parentPath, isDirectory: true)
    }

    private func openGraphFromRibbon() {
        appState.openGraph(source: .ribbon)
    }

    private func selectLeftPanel(_ panel: ObsidianLeftPanel) {
        leftPanel = panel
        if appState.workspacePaneLayout.isLeftSidebarCollapsed {
            appState.toggleLeftSidebarCollapsed()
        }
    }
}

private enum ObsidianLeftPanel {
    case files
    case search
    case bookmarks
}

private enum RootSheet: Identifiable {
    case help
    case vaultPicker
    case createVault
    case createItem(kind: VaultItemCreationKind, defaultName: String)

    var id: String {
        switch self {
        case .help:
            return "help"
        case .vaultPicker:
            return "vaultPicker"
        case .createVault:
            return "createVault"
        case .createItem(let kind, let defaultName):
            return "createItem-\(kind.rawValue)-\(defaultName)"
        }
    }
}

private struct ObsidianRibbonView: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    @Binding var selectedPanel: ObsidianLeftPanel
    let graphIsActive: Bool
    let selectLeftPanel: (ObsidianLeftPanel) -> Void
    let openVault: () -> Void
    let openGraph: () -> Void
    let showHelp: () -> Void
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: ObsidianUI.scaled(8, scale: appContentZoomScale)) {
            ObsidianIconButton(
                systemName: "folder",
                accessibilityLabel: "Files",
                isSelected: selectedPanel == .files
            ) {
                selectLeftPanel(.files)
            }

            ObsidianIconButton(
                systemName: "magnifyingglass",
                accessibilityLabel: "Search",
                isSelected: selectedPanel == .search
            ) {
                selectLeftPanel(.search)
            }

            ObsidianIconButton(
                systemName: "bookmark",
                accessibilityLabel: "Bookmarks",
                isSelected: selectedPanel == .bookmarks
            ) {
                selectLeftPanel(.bookmarks)
            }

            ObsidianIconButton(
                systemName: "point.3.connected.trianglepath.dotted",
                accessibilityLabel: "Graph view",
                isSelected: graphIsActive,
                action: openGraph
            )

            Spacer()

            ObsidianIconButton(
                systemName: "folder.badge.plus",
                accessibilityLabel: "Open vault",
                action: openVault
            )

            ObsidianIconButton(
                systemName: "questionmark.circle",
                accessibilityLabel: "Help",
                action: showHelp
            )

            ObsidianIconButton(
                systemName: "gearshape",
                accessibilityLabel: "Settings",
                action: showSettings
            )
        }
        .padding(.top, ObsidianUI.scaled(10, scale: appContentZoomScale))
        .padding(.bottom, ObsidianUI.scaled(12, scale: appContentZoomScale))
        .frame(width: ObsidianUI.ribbonWidth(scale: appContentZoomScale))
        .background(ObsidianUI.ribbonBackground)
    }
}

private struct ObsidianLeftSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedPanel: ObsidianLeftPanel
    let showVaultPicker: () -> Void
    let revealVaultInFinder: () -> Void
    let createNote: () -> Void
    let createFolder: () -> Void
    let closeVault: () -> Void
    let collapseSidebar: () -> Void
    let vaultSelectionError: String?
    @Binding var selectedFolderPath: String?

    var body: some View {
        VStack(spacing: 0) {
            ObsidianSidebarToolbar(
                selectedPanel: selectedPanel,
                createNote: createNote,
                createFolder: createFolder,
                collapseSidebar: collapseSidebar
            )

            Divider()

            Group {
                switch selectedPanel {
                case .files:
                    FileTreeView(showsHeader: false, selectedFolderPath: $selectedFolderPath)
                case .search:
                    SearchPanelView()
                case .bookmarks:
                    ObsidianBookmarksPlaceholder()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ObsidianVaultFooter(
                vaultSelection: appState.vaultSelection,
                error: vaultSelectionError,
                showVaultPicker: showVaultPicker,
                revealVaultInFinder: revealVaultInFinder,
                closeVault: closeVault
            )
        }
        .background(ObsidianUI.sidebarBackground)
    }
}

private struct ObsidianSidebarToolbar: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let selectedPanel: ObsidianLeftPanel
    let createNote: () -> Void
    let createFolder: () -> Void
    let collapseSidebar: () -> Void

    var body: some View {
        HStack(spacing: ObsidianUI.scaled(8, scale: appContentZoomScale)) {
            switch selectedPanel {
            case .files:
                ObsidianIconButton(systemName: "square.and.pencil", accessibilityLabel: "New note", action: createNote)
                ObsidianIconButton(systemName: "folder.badge.plus", accessibilityLabel: "New folder", action: createFolder)
                Menu {
                    ForEach(FileTreeSortMode.allCases) { mode in
                        Button {
                            appState.setFileTreeSortMode(mode)
                        } label: {
                            if appState.fileTreeSortMode == mode {
                                Label(mode.displayName, systemImage: "checkmark")
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: ObsidianUI.iconFontSize(scale: appContentZoomScale)))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: ObsidianUI.iconButtonSize(scale: appContentZoomScale),
                            height: ObsidianUI.iconButtonSize(scale: appContentZoomScale)
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .help("Sort files")
                .accessibilityLabel("Sort files")
                Spacer()
                ObsidianIconButton(
                    systemName: "rectangle.compress.vertical",
                    accessibilityLabel: "Collapse all",
                    action: appState.requestFileTreeCollapseAll
                )
            case .search:
                Text("Search")
                    .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale), weight: .semibold))
                Spacer()
            case .bookmarks:
                Text("Bookmarks")
                    .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale), weight: .semibold))
                Spacer()
            }

            ObsidianIconButton(
                systemName: "sidebar.left",
                accessibilityLabel: "Collapse left sidebar",
                action: collapseSidebar
            )
        }
        .padding(.horizontal, ObsidianUI.scaled(12, scale: appContentZoomScale))
        .frame(height: ObsidianUI.noteToolbarHeight(scale: appContentZoomScale))
    }
}

private struct ObsidianBookmarksPlaceholder: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale

    var body: some View {
        VStack(spacing: ObsidianUI.scaled(10, scale: appContentZoomScale)) {
            Image(systemName: "bookmark")
                .font(.system(size: ObsidianUI.fontSize(18, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
            Text("No bookmarks")
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ObsidianVaultFooter: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let vaultSelection: VaultSelectionState
    let error: String?
    let showVaultPicker: () -> Void
    let revealVaultInFinder: () -> Void
    let closeVault: () -> Void

    var body: some View {
        HStack(spacing: ObsidianUI.scaled(10, scale: appContentZoomScale)) {
            Button(action: showVaultPicker) {
                HStack(spacing: ObsidianUI.scaled(10, scale: appContentZoomScale)) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: ObsidianUI.scaled(2, scale: appContentZoomScale)) {
                        Text(title)
                            .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale), weight: .semibold))
                            .lineLimit(1)

                        if let error {
                            Text(error)
                                .font(.system(size: ObsidianUI.fontSize(11, scale: appContentZoomScale)))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Open vault switcher")
            .accessibilityLabel("Open vault switcher: \(title)")

            Spacer()

            Menu {
                Button("Open Vault Switcher", action: showVaultPicker)

                Button("Reveal in Finder", action: revealVaultInFinder)
                    .disabled(!canRevealVault)

                Button("Close Vault", role: .destructive, action: closeVault)
                    .disabled(!canCloseVault)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
                    .frame(
                        width: ObsidianUI.scaled(24, scale: appContentZoomScale),
                        height: ObsidianUI.scaled(24, scale: appContentZoomScale)
                    )
            }
            .buttonStyle(.plain)
            .help("Vault actions")
            .accessibilityLabel("Vault actions")
        }
        .padding(.horizontal, ObsidianUI.scaled(14, scale: appContentZoomScale))
        .frame(height: ObsidianUI.scaled(48, scale: appContentZoomScale))
    }

    private var title: String {
        switch vaultSelection {
        case .selected(let url):
            return url.lastPathComponent.isEmpty ? "Obsidian Vault" : url.lastPathComponent
        case .unavailable(let issue):
            return issue.displayTitle
        case .noVault:
            return "Open Vault"
        }
    }

    private var canCloseVault: Bool {
        vaultSelection.url != nil
    }

    private var canRevealVault: Bool {
        guard let url = vaultSelection.url else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

private struct ObsidianWorkspaceDetail: View {
    @EnvironmentObject private var appState: AppState
    let closeTab: (WorkspaceTab.ID) -> Void
    let moveTab: (Int, Int) -> Void
    let newTab: () -> Void
    let showsRightSidebarToggle: Bool
    let isRightSidebarCollapsed: Bool
    let toggleRightSidebar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ObsidianTabBar(
                tabs: appState.workspaceTabs,
                activeTabID: appState.activeTabID,
                isDirty: appState.isEditorDirty(file:),
                activateTab: appState.activateTab(id:),
                closeTab: closeTab,
                moveTab: moveTab,
                newTab: newTab,
                showsRightSidebarToggle: showsRightSidebarToggle,
                isRightSidebarCollapsed: isRightSidebarCollapsed,
                toggleRightSidebar: toggleRightSidebar
            )

            Divider()

            if appState.workspaceSelection == .graph {
                GraphWorkspaceView(vaultSelection: appState.vaultSelection)
            } else {
                switch appState.vaultSelection {
                case .noVault:
                    ObsidianEmptyWorkspace(
                        title: "Open a vault",
                        systemImage: "folder"
                    )
                case .unavailable(let issue):
                    ObsidianEmptyWorkspace(
                        title: issue.displayTitle,
                        systemImage: "exclamationmark.triangle"
                    )
                case .selected(let url):
                    ZStack {
                        EditorTabContentStack(
                            vaultURL: url,
                            tabs: appState.workspaceTabs,
                            activeTabID: appState.activeTabID,
                            activeFile: appState.activeFile
                        )
                        if appState.activeFile == nil {
                            ObsidianEmptyWorkspace(
                                title: url.lastPathComponent,
                                systemImage: "doc.text"
                            )
                            .zIndex(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ObsidianUI.editorBackground)
    }
}

private struct ObsidianRightSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedPanel: NoteInspectorPanel

    var body: some View {
        switch appState.vaultSelection {
        case .selected(let url):
            if let selectedFile = appState.selectedFile {
                NoteInspectorView(
                    vaultURL: url,
                    file: selectedFile,
                    selectedPanel: $selectedPanel
                )
            } else {
                ObsidianEmptySidebar(title: "No note selected")
            }
        case .noVault:
            ObsidianEmptySidebar(title: "No vault open")
        case .unavailable(let issue):
            ObsidianEmptySidebar(title: issue.displayTitle)
        }
    }
}

private struct ObsidianEmptyWorkspace: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: ObsidianUI.scaled(12, scale: appContentZoomScale)) {
            Image(systemName: systemImage)
                .font(.system(size: ObsidianUI.fontSize(28, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: ObsidianUI.fontSize(20, scale: appContentZoomScale), weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ObsidianEmptySidebar: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let title: String

    var body: some View {
        VStack(spacing: ObsidianUI.scaled(8, scale: appContentZoomScale)) {
            Image(systemName: "sidebar.right")
                .font(.system(size: ObsidianUI.fontSize(14, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ObsidianUI.sidebarBackground)
    }
}
