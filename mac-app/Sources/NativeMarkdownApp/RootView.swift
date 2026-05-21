import AppKit
import NativeMarkdownCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var leftPanel: ObsidianLeftPanel = .files
    @State private var vaultSelectionError: String?

    var body: some View {
        HStack(spacing: 0) {
            ObsidianRibbonView(
                selectedPanel: $leftPanel,
                openVault: openVaultPanel
            )

            Divider()

            ObsidianLeftSidebar(
                selectedPanel: $leftPanel,
                openVault: openVaultPanel,
                vaultSelectionError: vaultSelectionError
            )
            .frame(width: ObsidianUI.leftSidebarWidth)

            Divider()

            ObsidianWorkspaceDetail()

            Divider()

            ObsidianRightSidebar()
                .frame(width: ObsidianUI.rightSidebarWidth)
        }
        .background(ObsidianUI.editorBackground)
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
        .background(DirtyLifecycleWindowGuard())
        .onAppear {
            AppLifecycleController.shared.appState = appState
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
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
}

private enum ObsidianLeftPanel {
    case files
    case search
    case bookmarks
}

private struct ObsidianRibbonView: View {
    @Binding var selectedPanel: ObsidianLeftPanel
    let openVault: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ObsidianIconButton(
                systemName: "folder",
                accessibilityLabel: "Files",
                isSelected: selectedPanel == .files
            ) {
                selectedPanel = .files
            }

            ObsidianIconButton(
                systemName: "magnifyingglass",
                accessibilityLabel: "Search",
                isSelected: selectedPanel == .search
            ) {
                selectedPanel = .search
            }

            ObsidianIconButton(
                systemName: "bookmark",
                accessibilityLabel: "Bookmarks",
                isSelected: selectedPanel == .bookmarks
            ) {
                selectedPanel = .bookmarks
            }

            Spacer()

            ObsidianIconButton(
                systemName: "folder.badge.plus",
                accessibilityLabel: "Open vault",
                action: openVault
            )

            ObsidianIconButton(
                systemName: "questionmark.circle",
                accessibilityLabel: "Help",
                action: {}
            )

            ObsidianIconButton(
                systemName: "gearshape",
                accessibilityLabel: "Settings",
                action: {}
            )
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(width: ObsidianUI.ribbonWidth)
        .background(ObsidianUI.ribbonBackground)
    }
}

private struct ObsidianLeftSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedPanel: ObsidianLeftPanel
    let openVault: () -> Void
    let vaultSelectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            ObsidianSidebarToolbar(selectedPanel: selectedPanel)

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
                openVault: openVault
            )
        }
        .background(ObsidianUI.sidebarBackground)
    }
}

private struct ObsidianSidebarToolbar: View {
    let selectedPanel: ObsidianLeftPanel

    var body: some View {
        HStack(spacing: 8) {
            switch selectedPanel {
            case .files:
                ObsidianIconButton(systemName: "square.and.pencil", accessibilityLabel: "New note", action: {})
                ObsidianIconButton(systemName: "folder.badge.plus", accessibilityLabel: "New folder", action: {})
                ObsidianIconButton(systemName: "arrow.up.arrow.down", accessibilityLabel: "Sort files", action: {})
                Spacer()
                ObsidianIconButton(systemName: "rectangle.compress.vertical", accessibilityLabel: "Collapse all", action: {})
            case .search:
                Text("Search")
                    .font(.headline)
                Spacer()
            case .bookmarks:
                Text("Bookmarks")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ObsidianUI.noteToolbarHeight)
    }
}

private struct ObsidianBookmarksPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .foregroundStyle(.secondary)
            Text("No bookmarks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ObsidianVaultFooter: View {
    let vaultSelection: VaultSelectionState
    let error: String?
    let openVault: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: openVault) {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Open or switch vault")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
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
}

private struct ObsidianWorkspaceDetail: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            ObsidianTabBar(file: appState.selectedFile)

            Divider()

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
                if let selectedFile = appState.selectedFile {
                    ObsidianEditorPane(vaultURL: url, file: selectedFile)
                } else {
                    ObsidianEmptyWorkspace(
                        title: url.lastPathComponent,
                        systemImage: "doc.text"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ObsidianUI.editorBackground)
    }
}

private struct ObsidianTabBar: View {
    let file: FileTreeItem?

    var body: some View {
        HStack(spacing: 0) {
            if let file {
                HStack(spacing: 10) {
                    Text(displayTitle(for: file))
                        .lineLimit(1)
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: ObsidianUI.tabBarHeight)
                .frame(maxWidth: 280, alignment: .leading)
                .background(ObsidianUI.editorBackground)

                Divider()
                    .frame(height: ObsidianUI.tabBarHeight)
            }

            ObsidianIconButton(systemName: "plus", accessibilityLabel: "New tab", action: {})

            Spacer()

            Image(systemName: "chevron.down")
                .foregroundStyle(.secondary)
                .padding(.trailing, 14)
        }
        .frame(height: ObsidianUI.tabBarHeight)
        .background(ObsidianUI.sidebarBackground.opacity(0.55))
    }

    private func displayTitle(for file: FileTreeItem) -> String {
        (file.displayName as NSString).deletingPathExtension
    }
}

private struct ObsidianEditorPane: View {
    let vaultURL: URL
    let file: FileTreeItem

    var body: some View {
        VStack(spacing: 0) {
            ObsidianNoteToolbar(file: file)

            Divider()

            SourceNoteView(vaultURL: vaultURL, file: file, chrome: .obsidian)
        }
    }
}

private struct ObsidianNoteToolbar: View {
    let file: FileTreeItem

    var body: some View {
        HStack(spacing: 10) {
            ObsidianIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: {})
            ObsidianIconButton(systemName: "chevron.right", accessibilityLabel: "Forward", action: {})

            Text(breadcrumb)
                .font(.body)
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            ObsidianIconButton(systemName: "book", accessibilityLabel: "Reading view", action: {})
            ObsidianIconButton(systemName: "ellipsis", accessibilityLabel: "More actions", action: {})
        }
        .padding(.horizontal, 14)
        .frame(height: ObsidianUI.noteToolbarHeight)
        .background(ObsidianUI.editorBackground)
    }

    private var breadcrumb: String {
        let title = (file.displayName as NSString).deletingPathExtension
        return file.parentPath.isEmpty ? title : "\(file.parentPath) / \(title)"
    }
}

private struct ObsidianRightSidebar: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch appState.vaultSelection {
        case .selected(let url):
            if let selectedFile = appState.selectedFile {
                NoteInspectorView(vaultURL: url, file: selectedFile)
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
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ObsidianEmptySidebar: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ObsidianUI.sidebarBackground)
    }
}
