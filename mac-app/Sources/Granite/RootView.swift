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
