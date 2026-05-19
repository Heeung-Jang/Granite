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

            switch appState.vaultSelection {
            case .noVault:
                Button("Open Vault") {
                    openVaultPanel()
                }
                .buttonStyle(.borderedProminent)
            case .selected(let url):
                Text(url.lastPathComponent)
                    .font(.body)
                Button("Close Vault") {
                    appState.clearVault()
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
            appState.selectVault(url)
        }
    }
}

struct WorkspacePlaceholderView: View {
    let vaultSelection: VaultSelectionState

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
                AppKitEditorBridgePlaceholder()
                    .frame(minHeight: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

