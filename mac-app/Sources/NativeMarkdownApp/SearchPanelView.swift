import NativeMarkdownCore
import SwiftUI

struct SearchPanelView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var mode: SearchMode = .fileName
    @State private var status: SearchPanelStatus = .idle
    @State private var results: [SearchHitItem] = []
    @State private var resultState: SearchResultState = .complete
    @State private var nextOffset: Int?
    @State private var activeRequestID: UInt64 = 0
    @State private var isLoadingMore = false

    private let pageSize = 20

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            content
        }
        .task(id: SearchTaskKey(
            vaultPath: appState.vaultSelection.url?.path,
            query: query,
            mode: mode
        )) {
            await runDebouncedSearch()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Search")
                    .font(.headline)

                Spacer()

                Picker("Mode", selection: $mode) {
                    ForEach(SearchMode.allCases, id: \.self) { searchMode in
                        Text(searchMode.displayName).tag(searchMode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            TextField("Search vault", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task {
                        await performSearch(offset: 0, append: false)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .idle:
            EmptySearchState(title: "Enter Search", systemImage: "magnifyingglass")
        case .loading:
            EmptySearchState(title: "Searching", systemImage: "hourglass")
        case .noVault:
            EmptySearchState(title: "No Vault Open", systemImage: "folder")
        case .unavailable(let title):
            EmptySearchState(title: title, systemImage: "exclamationmark.triangle")
        case .noMatches:
            EmptySearchState(title: "No Matches", systemImage: "magnifyingglass")
        case .cancelled:
            EmptySearchState(title: "Search Cancelled", systemImage: "xmark.circle")
        case .failed(let message):
            EmptySearchState(title: message, systemImage: "xmark.octagon")
        case .results:
            VStack(spacing: 0) {
                if resultState != .complete {
                    SearchStateBanner(state: resultState)
                    Divider()
                }

                List {
                    ForEach(results) { hit in
                        Button {
                            appState.openFile(hit.file)
                        } label: {
                            SearchResultRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }

                    if let nextOffset {
                        Button {
                            Task {
                                await performSearch(offset: nextOffset, append: true)
                            }
                        } label: {
                            HStack {
                                if isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isLoadingMore ? "Loading" : "Load More")
                            }
                        }
                        .disabled(isLoadingMore)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func runDebouncedSearch() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            resetSearch()
            return
        }
        AppTelemetry.searchInputChanged(mode: mode, queryLength: trimmedQuery.count)

        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            status = .cancelled
            return
        }

        await performSearch(offset: 0, append: false)
    }

    private func performSearch(offset: Int, append: Bool) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            resetSearch()
            return
        }

        guard case .selected(let vaultURL) = appState.vaultSelection else {
            switch appState.vaultSelection {
            case .noVault:
                status = .noVault
            case .unavailable(let issue):
                status = .unavailable(issue.displayTitle)
            case .selected:
                break
            }
            return
        }

        activeRequestID &+= 1
        let requestID = activeRequestID
        let searchMode = mode
        let limit = pageSize
        let timer = AppTelemetryTimer()
        if append {
            isLoadingMore = true
        } else {
            status = .loading
            results = []
            nextOffset = nil
            resultState = .complete
        }

        do {
            let page = try await Task.detached(priority: .userInitiated) {
                try FileSystemVaultSearchLoader().search(
                    at: vaultURL,
                    query: trimmedQuery,
                    mode: searchMode,
                    page: SearchPageRequest(
                        requestID: requestID,
                        offset: offset,
                        limit: limit
                    )
                )
            }.value

            guard page.requestID == activeRequestID else {
                return
            }

            apply(page, append: append)
            AppTelemetry.searchCompleted(
                mode: searchMode,
                state: page.state,
                resultCount: page.items.count,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        } catch is CancellationError {
            guard requestID == activeRequestID else {
                return
            }
            status = .cancelled
        } catch VaultSearchError.emptyQuery {
            guard requestID == activeRequestID else {
                return
            }
            resetSearch()
        } catch {
            guard requestID == activeRequestID else {
                return
            }
            results = []
            nextOffset = nil
            resultState = .error
            status = .failed(error.localizedDescription)
            AppTelemetry.searchCompleted(
                mode: searchMode,
                state: .error,
                resultCount: 0,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        }

        if requestID == activeRequestID {
            isLoadingMore = false
        }
    }

    private func apply(_ page: SearchPage, append: Bool) {
        results = append ? results + page.items : page.items
        nextOffset = page.nextOffset
        resultState = page.state

        switch page.state {
        case .complete, .partial, .stale:
            status = results.isEmpty ? .noMatches : .results
        case .cancelled:
            status = .cancelled
        case .error:
            status = .failed("Search failed")
        }
    }

    private func resetSearch() {
        activeRequestID &+= 1
        status = .idle
        results = []
        nextOffset = nil
        resultState = .complete
        isLoadingMore = false
    }
}

private struct SearchTaskKey: Hashable {
    let vaultPath: String?
    let query: String
    let mode: SearchMode
}

private enum SearchPanelStatus: Equatable {
    case idle
    case loading
    case noVault
    case unavailable(String)
    case noMatches
    case results
    case cancelled
    case failed(String)
}

private struct SearchStateBanner: View {
    let state: SearchResultState

    var body: some View {
        HStack {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var title: String {
        switch state {
        case .complete:
            return "Complete"
        case .partial:
            return "Partial"
        case .stale:
            return "Stale"
        case .cancelled:
            return "Cancelled"
        case .error:
            return "Error"
        }
    }

    private var systemImage: String {
        switch state {
        case .complete:
            return "checkmark.circle"
        case .partial:
            return "ellipsis"
        case .stale:
            return "clock.badge.exclamationmark"
        case .cancelled:
            return "xmark.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}

private struct SearchResultRow: View {
    let hit: SearchHitItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title)
                    .lineLimit(1)

                Text(hit.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct EmptySearchState: View {
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
    }
}
