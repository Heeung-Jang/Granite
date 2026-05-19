import NativeMarkdownCore
import SwiftUI

struct NoteInspectorView: View {
    @EnvironmentObject private var appState: AppState
    let vaultURL: URL
    let file: FileTreeItem

    @State private var state: NoteInspectorViewState = .loading

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            content
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .task(id: file.id) {
            await load()
        }
    }

    private var header: some View {
        HStack {
            Text("Inspector")
                .font(.headline)
            Spacer()
            if case .loading = state {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            EmptyInspectorState(title: "Loading Metadata", systemImage: "hourglass")
        case .failed(let message):
            EmptyInspectorState(title: message, systemImage: "xmark.octagon")
        case .loaded(let snapshot):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if snapshot.state != .complete {
                        InspectorStateBanner(state: snapshot.state)
                    }

                    if !snapshot.warnings.isEmpty {
                        InspectorSection(title: "Warnings") {
                            ForEach(snapshot.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    InspectorSection(title: "Outgoing") {
                        if snapshot.outgoingLinks.isEmpty {
                            EmptyInlineText("No outgoing links")
                        } else {
                            ForEach(snapshot.outgoingLinks) { link in
                                OutgoingLinkRow(link: link, open: open)
                            }
                        }
                    }

                    InspectorSection(title: "Backlinks") {
                        if snapshot.backlinks.isEmpty {
                            EmptyInlineText("No backlinks")
                        } else {
                            ForEach(snapshot.backlinks) { backlink in
                                Button {
                                    appState.openFile(backlink.file)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(backlink.file.displayName)
                                            .lineLimit(1)
                                        Text(backlink.snippet)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    InspectorSection(title: "Tags") {
                        if snapshot.tags.isEmpty {
                            EmptyInlineText("No tags")
                        } else {
                            ForEach(snapshot.tagNotes) { group in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("#\(group.tag)")
                                        .font(.caption)
                                    if group.files.isEmpty {
                                        EmptyInlineText("No other notes")
                                    } else {
                                        ForEach(group.files) { taggedFile in
                                            Button {
                                                appState.openFile(taggedFile)
                                            } label: {
                                                Label(taggedFile.displayName, systemImage: "doc.text")
                                                    .lineLimit(1)
                                            }
                                            .buttonStyle(.plain)
                                            .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    InspectorSection(title: "Properties") {
                        if snapshot.properties.isEmpty {
                            EmptyInlineText("No properties")
                        } else {
                            ForEach(snapshot.properties) { property in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(property.key)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(property.value)
                                        .font(.caption)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }

                    InspectorSection(title: "Graph") {
                        EmptyInlineText("Graph placeholder")
                            .onAppear {
                                AppTelemetry.graphPlaceholderRendered(file)
                            }
                    }
                }
                .padding(12)
            }
        }
    }

    private func load() async {
        state = .loading
        let timer = AppTelemetryTimer()
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try FileSystemNoteInspectorLoader().loadInspector(at: vaultURL, file: file, maxFiles: 5_000)
            }.value

            if Task.isCancelled {
                return
            }
            state = .loaded(snapshot)
            AppTelemetry.inspectorRefreshCompleted(
                state: snapshot.state,
                outgoingCount: snapshot.outgoingLinks.count,
                backlinkCount: snapshot.backlinks.count,
                tagCount: snapshot.tags.count,
                propertyCount: snapshot.properties.count,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        } catch {
            if Task.isCancelled {
                return
            }
            state = .failed(error.localizedDescription)
            AppTelemetry.inspectorRefreshCompleted(
                state: .error,
                outgoingCount: 0,
                backlinkCount: 0,
                tagCount: 0,
                propertyCount: 0,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        }
    }

    private func open(_ file: FileTreeItem) {
        appState.openFile(file)
    }
}

private enum NoteInspectorViewState {
    case loading
    case loaded(NoteInspectorSnapshot)
    case failed(String)
}

private struct InspectorStateBanner: View {
    let state: SearchResultState

    var body: some View {
        Label(state.rawValue.capitalized, systemImage: "ellipsis")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OutgoingLinkRow: View {
    let link: OutgoingLinkItem
    let open: (FileTreeItem) -> Void

    var body: some View {
        switch link.state {
        case .resolved(let file):
            Button {
                open(file)
            } label: {
                Label(link.label, systemImage: "arrow.up.right")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        case .missing:
            Label("\(link.label) missing", systemImage: "questionmark")
                .foregroundStyle(.secondary)
        case .duplicate(let files):
            VStack(alignment: .leading, spacing: 3) {
                Label("\(link.label) duplicate", systemImage: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                ForEach(files) { file in
                    Button {
                        open(file)
                    } label: {
                        Text(file.relativePath)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        case .missingHeading(let file, let heading):
            Button {
                open(file)
            } label: {
                Label("\(link.label) missing #\(heading)", systemImage: "number")
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyInlineText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

private struct EmptyInspectorState: View {
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
