import AppKit
import NativeMarkdownCore
import SwiftUI

struct NoteInspectorView: View {
    @EnvironmentObject private var appState: AppState
    let vaultURL: URL
    let file: FileTreeItem

    @State private var selectedPanel: NoteInspectorPanel = .backlinks
    @State private var backlinksState: InspectorPanelState<[BacklinkItem]> = .idle
    @State private var outgoingState: InspectorPanelState<[OutgoingLinkItem]> = .idle
    @State private var tagsState: InspectorPanelState<TagsPropertiesPayload> = .idle
    @State private var attachmentsState: InspectorPanelState<[AttachmentReferenceItem]> = .idle

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            content
        }
        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
        .background(ObsidianUI.sidebarBackground)
        .task(id: "\(file.id)-\(appState.readGeneration)") {
            await resetAndLoadDefaultPanel()
        }
        .onChange(of: selectedPanel) { _, panel in
            Task {
                await load(panel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(NoteInspectorPanel.allCases, id: \.self) { panel in
                ObsidianIconButton(
                    systemName: panel.systemImage,
                    accessibilityLabel: panel.accessibilityLabel,
                    isSelected: selectedPanel == panel
                ) {
                    selectedPanel = panel
                }
            }

            Spacer()

            if selectedPanelIsLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                selectedPanelContent()
            }
            .padding(12)
        }
        .accessibilityLabel("Note inspector")
    }

    private func open(_ file: FileTreeItem) {
        appState.openFile(file)
    }

    private var selectedPanelIsLoading: Bool {
        switch selectedPanel {
        case .backlinks:
            backlinksState.isLoading
        case .outgoing:
            outgoingState.isLoading
        case .tags:
            tagsState.isLoading
        case .attachments:
            attachmentsState.isLoading
        case .graph:
            false
        }
    }

    private func resetAndLoadDefaultPanel() async {
        backlinksState = .idle
        outgoingState = .idle
        tagsState = .idle
        attachmentsState = .idle
        selectedPanel = .backlinks
        await load(.backlinks)
    }

    private func load(_ panel: NoteInspectorPanel) async {
        switch panel {
        case .backlinks:
            await loadBacklinks()
        case .outgoing:
            await loadOutgoing()
        case .tags:
            await loadTagsAndProperties()
        case .attachments:
            await loadAttachments()
        case .graph:
            return
        }
    }

    private func inspectorLoader() -> EngineInspectorPanelLoader? {
        guard let reader = appState.readClient, appState.readAvailability == .ready else {
            return nil
        }
        return EngineInspectorPanelLoader(reader: reader)
    }

    private func readUnavailableTitle(_ availability: ReadAvailability) -> String {
        switch availability {
        case .unavailable:
            return "Index unavailable"
        case .opening:
            return "Opening index"
        case .ready:
            return "Index ready"
        case .stale:
            return "Index stale"
        case .error(let message):
            return message
        }
    }

    private func errorMessage(_ error: any Error) -> String {
        let message = String(describing: error)
        return message.isEmpty ? "Inspector failed" : message
    }

    private func loadBacklinks() async {
        guard backlinksState.shouldLoad else {
            return
        }
        backlinksState = .loading
        let timer = AppTelemetryTimer()
        guard let loader = inspectorLoader() else {
            backlinksState = .failed(readUnavailableTitle(appState.readAvailability))
            return
        }
        do {
            let payload = try await loader.loadPanel(
                file: file,
                panel: .backlinks,
                requestID: appState.readGeneration,
                limit: 100
            )
            guard case .backlinks(let backlinks) = payload else {
                backlinksState = .failed("Unexpected backlinks response")
                return
            }
            backlinksState = .loaded(backlinks)
            AppTelemetry.inspectorRefreshCompleted(
                state: .complete,
                outgoingCount: 0,
                backlinkCount: backlinks.count,
                tagCount: 0,
                propertyCount: 0,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        } catch {
            backlinksState = .failed(errorMessage(error))
        }
    }

    private func loadOutgoing() async {
        guard outgoingState.shouldLoad else {
            return
        }
        outgoingState = .loading
        guard let loader = inspectorLoader() else {
            outgoingState = .failed(readUnavailableTitle(appState.readAvailability))
            return
        }
        do {
            let payload = try await loader.loadPanel(
                file: file,
                panel: .outgoing,
                requestID: appState.readGeneration,
                limit: 100
            )
            guard case .outgoing(let outgoing) = payload else {
                outgoingState = .failed("Unexpected outgoing response")
                return
            }
            outgoingState = .loaded(outgoing)
        } catch {
            outgoingState = .failed(errorMessage(error))
        }
    }

    private func loadTagsAndProperties() async {
        guard tagsState.shouldLoad else {
            return
        }
        tagsState = .loading
        guard let loader = inspectorLoader() else {
            tagsState = .failed(readUnavailableTitle(appState.readAvailability))
            return
        }
        let generation = appState.readGeneration
        do {
            async let tagsPayload = loader.loadPanel(
                file: file,
                panel: .tags,
                requestID: generation,
                limit: 100
            )
            async let propertiesPayload = loader.loadPanel(
                file: file,
                panel: .properties,
                requestID: generation,
                limit: 100
            )
            guard case .tags(let tags) = try await tagsPayload,
                  case .properties(let properties) = try await propertiesPayload
            else {
                tagsState = .failed("Unexpected tags response")
                return
            }
            tagsState = .loaded(TagsPropertiesPayload(tags: tags, properties: properties))
        } catch {
            tagsState = .failed(errorMessage(error))
        }
    }

    private func loadAttachments() async {
        guard attachmentsState.shouldLoad else {
            return
        }
        attachmentsState = .loading
        guard let loader = inspectorLoader() else {
            attachmentsState = .failed(readUnavailableTitle(appState.readAvailability))
            return
        }
        do {
            let payload = try await loader.loadPanel(
                file: file,
                panel: .attachments,
                requestID: appState.readGeneration,
                limit: 100
            )
            guard case .attachments(let attachments) = payload else {
                attachmentsState = .failed("Unexpected attachments response")
                return
            }
            attachmentsState = .loaded(attachments)
        } catch {
            attachmentsState = .failed(errorMessage(error))
        }
    }

    @ViewBuilder
    private func selectedPanelContent() -> some View {
        switch selectedPanel {
        case .backlinks:
            panelStateContent(backlinksState, loadingText: "백링크를 불러오는 중입니다.") { backlinks in
                backlinksSection(backlinks)
            }
        case .outgoing:
            panelStateContent(outgoingState, loadingText: "Outgoing links loading") { outgoing in
                outgoingSection(outgoing)
            }
        case .tags:
            panelStateContent(tagsState, loadingText: "Tags loading") { payload in
                tagsSection(payload.tags)
                propertiesSection(payload.properties)
            }
        case .attachments:
            panelStateContent(attachmentsState, loadingText: "Attachments loading") { attachments in
                attachmentsSection(attachments)
            }
        case .graph:
            graphSection()
        }
    }

    @ViewBuilder
    private func panelStateContent<Value, Content: View>(
        _ state: InspectorPanelState<Value>,
        loadingText: String,
        @ViewBuilder content: (Value) -> Content
    ) -> some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                EmptyInlineText(loadingText)
            }
        case .failed(let message):
            EmptyInspectorState(title: message, systemImage: "xmark.octagon")
        case .loaded(let value):
            content(value)
        }
    }

    private func outgoingSection(_ outgoingLinks: [OutgoingLinkItem]) -> some View {
        InspectorSection(title: "Outgoing links") {
            if outgoingLinks.isEmpty {
                EmptyInlineText("No outgoing links")
            } else {
                ForEach(outgoingLinks) { link in
                    OutgoingLinkRow(link: link, open: open)
                }
            }
        }
    }

    private func backlinksSection(_ backlinks: [BacklinkItem]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            InspectorSection(title: "링크된 언급", count: backlinks.count) {
                if backlinks.isEmpty {
                    EmptyInlineText("백링크를 찾지 못했습니다.")
                } else {
                    ForEach(backlinks) { backlink in
                        Button {
                            appState.openFile(backlink.file)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((backlink.file.displayName as NSString).deletingPathExtension)
                                    .lineLimit(1)
                                Text(backlink.snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open backlink \(backlink.file.displayName)")
                    }
                }
            }

            InspectorSection(title: "링크되지 않은 언급") {
                EmptyInlineText("검색된 언급이 없습니다.")
            }
        }
    }

    private func tagsSection(_ tags: [String]) -> some View {
        InspectorSection(title: "Tags") {
            if tags.isEmpty {
                EmptyInlineText("No tags")
            } else {
                ForEach(tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.caption)
                }
            }
        }
    }

    private func propertiesSection(_ properties: [PropertyItem]) -> some View {
        InspectorSection(title: "Properties") {
            if properties.isEmpty {
                EmptyInlineText("No properties")
            } else {
                ForEach(properties) { property in
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
    }

    private func attachmentsSection(_ attachments: [AttachmentReferenceItem]) -> some View {
        InspectorSection(title: "Attachments") {
            if attachments.isEmpty {
                EmptyInlineText("No attachments")
            } else {
                ForEach(attachments) { attachment in
                    AttachmentReferenceRow(vaultURL: vaultURL, reference: attachment)
                }
            }
        }
    }

    private func graphSection() -> some View {
        InspectorSection(title: "Graph") {
            LocalGraphSection(
                file: file,
                reader: appState.readClient,
                readAvailability: appState.readAvailability,
                readGeneration: appState.readGeneration,
                open: open
            )
        }
    }
}

private enum InspectorPanelState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }

    var shouldLoad: Bool {
        if case .idle = self {
            return true
        }
        return false
    }
}

private struct TagsPropertiesPayload: Equatable {
    let tags: [String]
    let properties: [PropertyItem]
}

private enum NoteInspectorPanel: CaseIterable {
    case backlinks
    case outgoing
    case tags
    case attachments
    case graph

    var systemImage: String {
        switch self {
        case .backlinks:
            return "link"
        case .outgoing:
            return "link.badge.plus"
        case .tags:
            return "tag"
        case .attachments:
            return "doc"
        case .graph:
            return "list.bullet"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .backlinks:
            return "Backlinks"
        case .outgoing:
            return "Outgoing links"
        case .tags:
            return "Tags and properties"
        case .attachments:
            return "Attachments"
        case .graph:
            return "Graph"
        }
    }
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
    var count: Int?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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
            .accessibilityLabel("Open outgoing link \(link.label)")
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
                    .accessibilityLabel("Open duplicate link target \(file.displayName)")
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
            .accessibilityLabel("Open \(link.label), missing heading \(heading)")
        }
    }
}

private struct AttachmentReferenceRow: View {
    let vaultURL: URL
    let reference: AttachmentReferenceItem
    @State private var previewInfo: AttachmentPreviewInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(reference.rawTarget, systemImage: systemImage)
                .font(.caption)
                .lineLimit(1)
            Text("\(sourceText) - \(statusText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if case .duplicate(let files) = reference.state {
                ForEach(files) { file in
                    Text(file.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if let previewInfo {
                AttachmentImagePreview(info: previewInfo)
            }
        }
        .task(id: reference.id) {
            await loadPreviewInfo()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attachment \(reference.rawTarget), \(statusText)")
    }

    private var systemImage: String {
        switch reference.state {
        case .resolved:
            "paperclip"
        case .missing:
            "questionmark"
        case .unreadable:
            "lock"
        case .duplicate:
            "square.stack.3d.up"
        case .remote:
            "network"
        case .rejected:
            "exclamationmark.triangle"
        case .unsupported:
            "nosign"
        }
    }

    private var statusText: String {
        switch reference.state {
        case .resolved(let file):
            "Resolved: \(file.relativePath)"
        case .missing:
            "Missing"
        case .unreadable(let file):
            "Unreadable: \(file.relativePath)"
        case .duplicate:
            "Duplicate basename"
        case .remote:
            "Remote reference"
        case .rejected(let reason):
            "Rejected: \(reason.rawValue)"
        case .unsupported:
            "Unsupported"
        }
    }

    private var sourceText: String {
        switch reference.source {
        case .wikiEmbed:
            "Wiki embed"
        case .markdownImage:
            "Markdown image"
        case .markdownLink:
            "Markdown link"
        }
    }

    private func loadPreviewInfo() async {
        previewInfo = nil
        let vaultURL = vaultURL
        let reference = reference
        let state = await Task.detached(priority: .utility) {
            FileSystemAttachmentPreviewGate().previewState(vaultURL: vaultURL, reference: reference)
        }.value

        if Task.isCancelled {
            return
        }
        if case .eligible(let info) = state {
            previewInfo = info
        }
    }
}

private struct AttachmentImagePreview: View {
    let info: AttachmentPreviewInfo
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.4))
            previewContent
                .padding(4)
        }
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 120)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Attachment image preview")
        .task(id: info.url) {
            await loadImage()
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else if didFail {
            EmptyView()
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func loadImage() async {
        didFail = false
        image = nil
        let url = info.url
        let data = try? await Task.detached(priority: .utility) {
            try Data(contentsOf: url)
        }.value

        if Task.isCancelled {
            return
        }
        guard let data, let loadedImage = NSImage(data: data) else {
            didFail = true
            return
        }
        image = loadedImage
    }
}

private enum LocalGraphViewState {
    case loading
    case loaded(LocalGraphSnapshot)
    case failed(String)
}

private struct LocalGraphSection: View {
    let file: FileTreeItem
    let reader: (any EngineReading)?
    let readAvailability: ReadAvailability
    let readGeneration: UInt64
    let open: (FileTreeItem) -> Void

    @State private var depth: LocalGraphDepth = .oneHop
    @State private var state: LocalGraphViewState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Depth", selection: $depth) {
                ForEach(LocalGraphDepth.allCases, id: \.self) { depth in
                    Text(depth.displayName).tag(depth)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .accessibilityLabel("Graph depth")

            switch state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    EmptyInlineText("Loading graph")
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let snapshot):
                LocalGraphContent(snapshot: snapshot, open: open)
            }
        }
        .task(id: "\(file.id)-\(depth.rawValue)-\(readGeneration)") {
            await loadGraph()
        }
    }

    private func loadGraph() async {
        state = .loading
        let timer = AppTelemetryTimer()
        let file = file
        let depth = depth
        guard let reader, readAvailability == .ready else {
            state = readAvailability == .opening ? .loading : .failed(readUnavailableTitle(readAvailability))
            return
        }

        do {
            let snapshot = try await EngineLocalGraphLoader(reader: reader).loadGraph(
                file: file,
                requestID: readGeneration,
                request: LocalGraphRequest(depth: depth)
            )

            if Task.isCancelled {
                return
            }
            state = .loaded(snapshot)
            AppTelemetry.graphRendered(
                file,
                state: snapshot.state,
                nodeCount: snapshot.nodes.count,
                edgeCount: snapshot.edges.count,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        } catch {
            if Task.isCancelled {
                return
            }
            state = .failed(error.localizedDescription)
            AppTelemetry.graphRendered(
                file,
                state: .error,
                nodeCount: 0,
                edgeCount: 0,
                durationMilliseconds: timer.elapsedMilliseconds()
            )
        }
    }

    private func readUnavailableTitle(_ availability: ReadAvailability) -> String {
        switch availability {
        case .unavailable:
            return "Index unavailable"
        case .opening:
            return "Opening index"
        case .ready:
            return "Index ready"
        case .stale:
            return "Index stale"
        case .error(let message):
            return message
        }
    }
}

private struct LocalGraphContent: View {
    let snapshot: LocalGraphSnapshot
    let open: (FileTreeItem) -> Void

    private var nodesByID: [String: LocalGraphNode] {
        Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.state != .complete {
                Label("Partial graph", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.edges.isEmpty {
                EmptyInlineText("No graph links")
            } else {
                LocalGraphNodeStrip(nodes: snapshot.nodes, open: open)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.edges.prefix(12)) { edge in
                        LocalGraphEdgeRow(edge: edge, nodesByID: nodesByID, open: open)
                    }
                    if snapshot.edges.count > 12 {
                        Text("+ \(snapshot.edges.count - 12) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct LocalGraphNodeStrip: View {
    let nodes: [LocalGraphNode]
    let open: (FileTreeItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(nodes) { node in
                    LocalGraphNodeChip(node: node, open: open)
                }
            }
        }
        .accessibilityLabel("Graph nodes")
    }
}

private struct LocalGraphNodeChip: View {
    let node: LocalGraphNode
    let open: (FileTreeItem) -> Void

    var body: some View {
        Group {
            if let file = node.file, node.kind != .center {
                Button {
                    open(file)
                } label: {
                    label
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open graph note \(node.label)")
            } else {
                label
                    .accessibilityLabel(accessibilityLabel)
            }
        }
    }

    private var accessibilityLabel: String {
        switch node.kind {
        case .center:
            "Current graph note \(node.label)"
        case .resolved:
            "Graph note \(node.label)"
        case .unresolved:
            "Unresolved graph link \(node.label)"
        }
    }

    private var label: some View {
        Label(node.label, systemImage: systemImage)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(node.kind == .center ? 0.9 : 0.45))
            .clipShape(Capsule())
    }

    private var systemImage: String {
        switch node.kind {
        case .center:
            "smallcircle.filled.circle"
        case .resolved:
            "doc.text"
        case .unresolved:
            "questionmark"
        }
    }
}

private struct LocalGraphEdgeRow: View {
    let edge: LocalGraphEdge
    let nodesByID: [String: LocalGraphNode]
    let open: (FileTreeItem) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            nodeLabel(nodesByID[edge.sourceNodeID])
            Image(systemName: edge.direction == .backlink ? "arrow.left" : "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            nodeLabel(nodesByID[edge.targetNodeID])
            Text("h\(edge.hop)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let source = nodesByID[edge.sourceNodeID]?.label ?? edge.sourceNodeID
        let target = nodesByID[edge.targetNodeID]?.label ?? edge.targetText
        let direction = edge.direction == .backlink ? "backlink" : "outgoing link"
        return "\(direction) from \(source) to \(target), hop \(edge.hop)"
    }

    @ViewBuilder
    private func nodeLabel(_ node: LocalGraphNode?) -> some View {
        if let file = node?.file, node?.kind != .center {
            Button {
                open(file)
            } label: {
                Text(node?.label ?? "")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .font(.caption)
        } else {
            Text(node?.label ?? edge.targetText)
                .font(.caption)
                .foregroundStyle(node == nil ? .secondary : .primary)
                .lineLimit(1)
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
            .accessibilityLabel(text)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
