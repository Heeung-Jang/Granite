import NativeMarkdownCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            VaultPickerView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            WorkspacePlaceholderView(vaultSelection: appState.vaultSelection)
        }
    }
}

struct VaultPickerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vault")
                .font(.headline)
            Text(appState.engineHealth.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch appState.vaultSelection {
            case .noVault:
                Button {
                    openVaultPanel()
                } label: {
                    Label("Open Vault", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
            case .selected(let url):
                Text(url.lastPathComponent)
                    .font(.body)
                Button {
                    appState.clearVault()
                } label: {
                    Label("Close Vault", systemImage: "xmark.circle")
                }
            case .unavailable(let issue):
                Text(issue.displayTitle)
                    .font(.body)
                Text(issue.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    try? appState.reconnectVault()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                Button {
                    openVaultPanel()
                } label: {
                    Label("Choose Other", systemImage: "folder")
                }
            }

            Spacer()
        }
        .padding(16)
    }

    private func openVaultPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        if panel.runModal() == .OK, let url = panel.url {
            try? appState.selectVault(url)
        }
    }
}

struct WorkspacePlaceholderView: View {
    let vaultSelection: VaultSelectionState
    @State private var editorText = "# Native Markdown\n\n"

    var body: some View {
        VStack(spacing: 16) {
            switch vaultSelection {
            case .noVault:
                Text("No Vault Open")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            case .selected(let url):
                Text(url.lastPathComponent)
                    .font(.title2)
                MarkdownEditorView(text: $editorText)
                    .frame(minHeight: 320)
            case .unavailable(let issue):
                Text(issue.displayTitle)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
