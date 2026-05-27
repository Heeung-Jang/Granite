import AppKit
import NativeMarkdownCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppContentZoom.storageKey) private var rawAppContentZoomScale = AppContentZoom.defaultScale
    @State private var leftPanel: ObsidianLeftPanel = .files
    @State private var selectedInspectorPanel: NoteInspectorPanel = .backlinks
    @State private var vaultSelectionError: String?
    @State private var presentedSheet: RootSheet?

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
                        closeVault: closeVault,
                        collapseSidebar: appState.toggleLeftSidebarCollapsed,
                        vaultSelectionError: vaultSelectionError
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
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .help:
                GraniteHelpView(dismiss: dismissPresentedSheet)
                .frame(width: 420, height: 320)
            case .vaultPicker:
                VaultPickerView(closeVault: closeVault, dismiss: dismissPresentedSheet)
                    .environmentObject(appState)
                    .frame(width: 360, height: 460)
            }
        }
        .background(DirtyLifecycleWindowGuard())
        .background(WorkspaceTabKeyCommandGuard(action: workspaceTabAction))
        .focusedValue(\.workspaceTabAction, workspaceTabAction)
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

    var id: String {
        switch self {
        case .help:
            return "help"
        case .vaultPicker:
            return "vaultPicker"
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
    let closeVault: () -> Void
    let collapseSidebar: () -> Void
    let vaultSelectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            ObsidianSidebarToolbar(
                selectedPanel: selectedPanel,
                collapseSidebar: collapseSidebar
            )

            Divider()

            Group {
                switch selectedPanel {
                case .files:
                    FileTreeView(showsHeader: false)
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
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let selectedPanel: ObsidianLeftPanel
    let collapseSidebar: () -> Void

    var body: some View {
        HStack(spacing: ObsidianUI.scaled(8, scale: appContentZoomScale)) {
            switch selectedPanel {
            case .files:
                ObsidianIconButton(systemName: "square.and.pencil", accessibilityLabel: "New note", action: {})
                ObsidianIconButton(systemName: "folder.badge.plus", accessibilityLabel: "New folder", action: {})
                ObsidianIconButton(systemName: "arrow.up.arrow.down", accessibilityLabel: "Sort files", action: {})
                Spacer()
                ObsidianIconButton(systemName: "rectangle.compress.vertical", accessibilityLabel: "Collapse all", action: {})
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
                Image(systemName: "gearshape")
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

private struct ObsidianTabBar: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let tabs: [WorkspaceTab]
    let activeTabID: WorkspaceTab.ID?
    let isDirty: (FileTreeItem) -> Bool
    let activateTab: (WorkspaceTab.ID) -> Void
    let closeTab: (WorkspaceTab.ID) -> Void
    let moveTab: (Int, Int) -> Void
    let newTab: () -> Void
    let showsRightSidebarToggle: Bool
    let isRightSidebarCollapsed: Bool
    let toggleRightSidebar: () -> Void
    @State private var draggedTabID: WorkspaceTab.ID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            ObsidianTabItem(
                                tab: tab,
                                isActive: tab.id == activeTabID,
                                isDirty: tab.file.map(isDirty) ?? false,
                                activate: {
                                    activateTab(tab.id)
                                },
                                close: {
                                    closeTab(tab.id)
                                }
                            )
                            .id(tab.id)
                            .onDrag {
                                draggedTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: ObsidianTabDropDelegate(
                                    targetTabID: tab.id,
                                    tabs: tabs,
                                    draggedTabID: $draggedTabID,
                                    moveTab: moveTab
                                )
                            )

                            Divider()
                                .frame(height: ObsidianUI.tabBarHeight(scale: appContentZoomScale))
                        }
                    }
                }
                .onChange(of: activeTabID) { _, newValue in
                    guard let newValue else {
                        return
                    }
                    withAnimation(.snappy(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            ObsidianIconButton(
                systemName: "plus",
                accessibilityLabel: "New tab",
                action: newTab
            )

            Spacer()

            if showsRightSidebarToggle {
                ObsidianIconButton(
                    systemName: "sidebar.right",
                    accessibilityLabel: isRightSidebarCollapsed ? "Expand right inspector" : "Collapse right inspector",
                    isSelected: !isRightSidebarCollapsed,
                    action: toggleRightSidebar
                )
                .padding(.trailing, ObsidianUI.scaled(4, scale: appContentZoomScale))
            }

            Image(systemName: "chevron.down")
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
                .padding(.trailing, ObsidianUI.scaled(14, scale: appContentZoomScale))
        }
        .frame(height: ObsidianUI.tabBarHeight(scale: appContentZoomScale))
        .background(ObsidianUI.sidebarBackground.opacity(0.55))
    }
}

private struct ObsidianTabDropDelegate: DropDelegate {
    let targetTabID: WorkspaceTab.ID
    let tabs: [WorkspaceTab]
    @Binding var draggedTabID: WorkspaceTab.ID?
    let moveTab: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedTabID,
              draggedTabID != targetTabID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == draggedTabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetTabID })
        else {
            return
        }
        moveTab(sourceIndex, targetIndex)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }
}

private struct ObsidianTabItem: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let tab: WorkspaceTab
    let isActive: Bool
    let isDirty: Bool
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: activate) {
                Text(displayTitle)
                    .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(
                        width: ObsidianUI.scaled(6, scale: appContentZoomScale),
                        height: ObsidianUI.scaled(6, scale: appContentZoomScale)
                    )
                    .accessibilityLabel("Unsaved changes")
                    .padding(.leading, ObsidianUI.scaled(8, scale: appContentZoomScale))
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: ObsidianUI.fontSize(11, scale: appContentZoomScale)))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: ObsidianUI.scaled(18, scale: appContentZoomScale),
                        height: ObsidianUI.scaled(18, scale: appContentZoomScale)
                    )
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .accessibilityLabel("Close tab")
            .padding(.leading, ObsidianUI.scaled(8, scale: appContentZoomScale))
        }
        .padding(.horizontal, ObsidianUI.scaled(14, scale: appContentZoomScale))
        .frame(height: ObsidianUI.tabBarHeight(scale: appContentZoomScale))
        .frame(width: ObsidianUI.scaled(220, scale: appContentZoomScale), alignment: .leading)
        .contentShape(Rectangle())
        .background(isActive ? ObsidianUI.editorBackground : Color.clear)
    }

    private var displayTitle: String {
        guard let file = tab.file else {
            return "Untitled"
        }
        return (file.displayName as NSString).deletingPathExtension
    }
}

private struct EditorTabContentStack: View {
    @EnvironmentObject private var appState: AppState
    let vaultURL: URL
    let tabs: [WorkspaceTab]
    let activeTabID: WorkspaceTab.ID?
    let activeFile: FileTreeItem?
    @State private var mountedTabIDs: [WorkspaceTab.ID] = []
    @State private var focusRequestID: WorkspaceTab.ID?

    var body: some View {
        ZStack {
            ForEach(mountedTabs) { tab in
                if let file = tab.file {
                    ObsidianEditorPane(
                        vaultURL: vaultURL,
                        file: file,
                        isActive: tab.id == activeTabID,
                        focusRequestID: tab.id == activeTabID ? focusRequestID : nil
                    )
                        .opacity(tab.id == activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == activeTabID)
                        .accessibilityHidden(tab.id != activeTabID)
                        .zIndex(tab.id == activeTabID ? 1 : 0)
                }
            }
        }
        .onAppear {
            focusRequestID = activeFile == nil ? nil : activeTabID
            reconcileMountedTabs()
        }
        .onChange(of: activeTabID) { _, _ in
            focusRequestID = activeFile == nil ? nil : activeTabID
            reconcileMountedTabs()
        }
        .onChange(of: tabs.map(\.id)) { _, _ in
            reconcileMountedTabs()
        }
        .onChange(of: activeFile?.id) { _, _ in
            reconcileMountedTabs()
        }
    }

    private var mountedTabs: [WorkspaceTab] {
        mountedTabIDs.compactMap { id in
            tabs.first { $0.id == id && $0.file != nil }
        }
    }

    private func reconcileMountedTabs() {
        let plan = WorkspaceMountedEditorPlanner.reconcile(
            tabs: tabs,
            activeTabID: activeTabID,
            existingMountedTabIDs: mountedTabIDs
        ) { tab in
            guard let file = tab.file else {
                return false
            }
            return appState.isEditorDirty(file: file)
        }
        mountedTabIDs = plan.mountedTabIDs
    }
}

private struct ObsidianEditorPane: View {
    let vaultURL: URL
    let file: FileTreeItem
    var isActive = true
    var focusRequestID: WorkspaceTab.ID?

    var body: some View {
        VStack(spacing: 0) {
            ObsidianNoteToolbar(file: file)

            Divider()

            SourceNoteView(
                vaultURL: vaultURL,
                file: file,
                chrome: .obsidian,
                isActive: isActive,
                focusRequestID: focusRequestID
            )
        }
    }
}

private struct ObsidianNoteToolbar: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let file: FileTreeItem

    var body: some View {
        HStack(spacing: ObsidianUI.scaled(10, scale: appContentZoomScale)) {
            ObsidianIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: {})
            ObsidianIconButton(systemName: "chevron.right", accessibilityLabel: "Forward", action: {})

            Text(breadcrumb)
                .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            ObsidianIconButton(systemName: "book", accessibilityLabel: "Reading view", action: {})
            ObsidianMarkerStyleMenu()
        }
        .padding(.horizontal, ObsidianUI.scaled(14, scale: appContentZoomScale))
        .frame(height: ObsidianUI.noteToolbarHeight(scale: appContentZoomScale))
        .background(ObsidianUI.editorBackground)
    }

    private var breadcrumb: String {
        let title = (file.displayName as NSString).deletingPathExtension
        return file.parentPath.isEmpty ? title : "\(file.parentPath) / \(title)"
    }
}

private struct ObsidianMarkerStyleMenu: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    @AppStorage(LivePreviewMarkerStyle.storageKey) private var markerStyleRaw = LivePreviewMarkerStyle.defaultValue.rawValue

    var body: some View {
        Menu {
            Picker("Marker Style", selection: $markerStyleRaw) {
                ForEach(LivePreviewMarkerStyle.allCases) { style in
                    Text(style.menuTitle).tag(style.rawValue)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
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
        .help("Marker style")
        .accessibilityLabel("Marker style")
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
