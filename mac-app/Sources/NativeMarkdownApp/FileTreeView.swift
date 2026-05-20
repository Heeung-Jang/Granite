import NativeMarkdownCore
import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var state: FileTreeViewState = .idle
    @State private var selectedFileID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            content
        }
        .task(id: appState.vaultSelection.url) {
            await reload(for: appState.vaultSelection)
        }
        .onChange(of: selectedFileID) { _, newValue in
            guard let item = item(withID: newValue) else {
                return
            }
            if !appState.openFile(item) {
                selectedFileID = appState.selectedFile?.id
            }
        }
        .onChange(of: appState.selectedFile?.id) { _, newValue in
            selectedFileID = newValue
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File browser")
    }

    private var header: some View {
        HStack {
            Text("Files")
                .font(.headline)

            Spacer()

            if case .loading = state {
                ProgressView()
                    .controlSize(.small)
            } else if case .loaded = state {
                Button {
                    Task {
                        await reload(for: appState.vaultSelection)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh Files")
                .accessibilityLabel("Refresh files")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyFileTreeState(title: "No Vault Open", systemImage: "folder")
        case .loading:
            EmptyFileTreeState(title: "Loading Files", systemImage: "hourglass")
        case .empty:
            EmptyFileTreeState(title: "No Markdown Files", systemImage: "doc")
        case .unavailable(let issue):
            EmptyFileTreeState(title: issue.displayTitle, systemImage: "exclamationmark.triangle")
        case .failed(let message):
            EmptyFileTreeState(title: message, systemImage: "xmark.octagon")
        case .loaded(let snapshot):
            VStack(spacing: 0) {
                if snapshot.state != .complete {
                    HStack {
                        Image(systemName: snapshot.state == .stale ? "clock.badge.exclamationmark" : "ellipsis")
                        Text(snapshot.state == .stale ? "Stale" : "Partial")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(snapshot.state == .stale ? "File list is stale" : "File list is partial")

                    Divider()
                }

                List(selection: $selectedFileID) {
                    ForEach(snapshot.items) { item in
                        FileTreeRow(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Markdown files")
            }
        }
    }

    @MainActor
    private func reload(for selection: VaultSelectionState) async {
        selectedFileID = nil

        switch selection {
        case .noVault:
            state = .idle
        case .unavailable(let issue):
            state = .unavailable(issue)
        case .selected(let url):
            let timer = AppTelemetryTimer()
            state = .loading
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try FileSystemFileTreeLoader().loadFileTree(at: url, maxItems: 5_000)
                }.value

                if Task.isCancelled {
                    return
                }

                state = snapshot.items.isEmpty ? .empty : .loaded(snapshot)
                AppTelemetry.sidebarRefreshCompleted(
                    state: snapshot.state,
                    itemCount: snapshot.items.count,
                    durationMilliseconds: timer.elapsedMilliseconds()
                )
            } catch {
                if Task.isCancelled {
                    return
                }
                state = .failed(error.localizedDescription)
                AppTelemetry.sidebarRefreshCompleted(
                    state: nil,
                    itemCount: 0,
                    durationMilliseconds: timer.elapsedMilliseconds()
                )
            }
        }
    }

    private func item(withID id: String?) -> FileTreeItem? {
        guard let id, case .loaded(let snapshot) = state else {
            return nil
        }
        return snapshot.items.first { $0.id == id }
    }
}

private enum FileTreeViewState {
    case idle
    case loading
    case loaded(FileTreeSnapshot)
    case empty
    case unavailable(VaultAccessIssue)
    case failed(String)
}

private struct FileTreeRow: View {
    let item: FileTreeItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)

                if !item.parentPath.isEmpty {
                    Text(item.parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        item.parentPath.isEmpty ? item.displayName : "\(item.displayName), \(item.parentPath)"
    }
}

private struct EmptyFileTreeState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
