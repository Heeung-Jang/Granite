import AppKit
import NativeMarkdownCore
import SwiftUI

struct VaultPickerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            currentVaultSection
                .padding(16)

            Divider()

            List {
                Section("Recent Vaults") {
                    if appState.recentVaults.isEmpty {
                        Text("No Recent Vaults")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(appState.recentVaults) { recentVault in
                        RecentVaultRow(
                            recentVault: recentVault,
                            isCurrent: appState.vaultSelection.url == recentVault.url,
                            open: { open(recentVault) },
                            remove: { appState.removeRecentVault(recentVault) }
                        )
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vault picker")
    }

    private var currentVaultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Vault")
                    .font(.headline)

                Spacer()

                Button {
                    openVaultPanel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Choose Other")
                .accessibilityLabel("Choose other vault")
            }

            Text(appState.engineHealth.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)

            currentVaultState

            if let selectionError {
                Text(selectionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var currentVaultState: some View {
        switch appState.vaultSelection {
        case .noVault:
            Button {
                openVaultPanel()
            } label: {
                Label("Open Vault", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

        case .selected(let url):
            VaultStateSummary(
                systemImage: "checkmark.circle.fill",
                title: displayName(for: url),
                detail: url.deletingLastPathComponent().path
            )

            HStack {
                Button {
                    appState.clearVault()
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }

                Button {
                    openVaultPanel()
                } label: {
                    Label("Choose Other", systemImage: "folder")
                }
            }

        case .unavailable(let issue):
            VaultStateSummary(
                systemImage: systemImage(for: issue),
                title: issue.displayTitle,
                detail: displayName(for: issue.url)
            )

            Text(issue.recoveryMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(issue.url.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    reconnectVault()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }

                Button {
                    openVaultPanel()
                } label: {
                    Label("Choose Other", systemImage: "folder")
                }

                Button(role: .destructive) {
                    appState.removeRecentVault(at: issue.url)
                } label: {
                    Label("Remove Recent", systemImage: "minus.circle")
                }
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
            selectVault(at: url)
        }
    }

    private func open(_ recentVault: RecentVault) {
        do {
            try appState.openRecentVault(recentVault)
            selectionError = nil
        } catch {
            selectionError = error.localizedDescription
        }
    }

    private func reconnectVault() {
        do {
            try appState.reconnectVault()
            selectionError = nil
        } catch {
            selectionError = error.localizedDescription
        }
    }

    private func selectVault(at url: URL) {
        do {
            try appState.selectVault(url)
            selectionError = nil
        } catch {
            selectionError = error.localizedDescription
        }
    }

    private func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private func systemImage(for issue: VaultAccessIssue) -> String {
        switch issue {
        case .denied, .staleBookmark:
            return "lock.trianglebadge.exclamationmark"
        case .missing:
            return "questionmark.folder"
        case .unmounted:
            return "externaldrive.badge.questionmark"
        case .readOnly:
            return "lock.doc"
        }
    }
}

private struct VaultStateSummary: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct RecentVaultRow: View {
    let recentVault: RecentVault
    let isCurrent: Bool
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: isCurrent ? "folder.fill" : "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(recentVault.displayName)
                            .lineLimit(1)

                        Text(recentVault.displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open vault \(recentVault.displayName)")
            .accessibilityHint(recentVault.displayPath)

            Button(action: remove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove Recent Vault")
            .accessibilityLabel("Remove recent vault \(recentVault.displayName)")
        }
        .contextMenu {
            Button("Open", action: open)
            Button("Remove from Recent", role: .destructive, action: remove)
        }
    }
}
