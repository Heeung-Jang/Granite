import Testing
@testable import NativeMarkdownCore

@Test
func graphSettingsDefaultsMatchMvpGate() {
    let settings = GraphSettings()

    #expect(settings.semantic.includeUnresolved == false)
    #expect(settings.semantic.includeOrphans == false)
    #expect(settings.semantic.resolvedLinksOnly)
    #expect(settings.presentation.labelVisibility == .automatic)
    #expect(settings.searchQuery.isEmpty)
    #expect(settings.groupRules.isEmpty)
}

@Test
func graphSettingsReloadOnlyForSemanticChanges() {
    let baseline = GraphSettings()
    var semanticChange = baseline
    semanticChange.semantic.includeOrphans = true
    var presentationChange = baseline
    presentationChange.presentation.showArrows = true
    var searchChange = baseline
    searchChange.searchQuery = "client@example.com"

    #expect(semanticChange.requiresSnapshotReload(comparedTo: baseline))
    #expect(!presentationChange.requiresSnapshotReload(comparedTo: baseline))
    #expect(!searchChange.requiresSnapshotReload(comparedTo: baseline))
}

@Test
func graphSettingsPrivacyKeyDoesNotExposePrivateValues() {
    let settings = GraphSettings(
        searchQuery: "/Users/example/Codex Vault/Secret Note.md client@example.com",
        groupRules: [
            GraphGroupRule(
                id: "secret-rule",
                query: "#private/project client@example.com",
                colorHex: "#ff00aa"
            )
        ]
    )

    let key = GraphSettingsPrivacyKey.make(settings: settings).description

    #expect(key.hasPrefix("graph-settings-"))
    #expect(!key.contains("Secret"))
    #expect(!key.contains("client@example.com"))
    #expect(!key.contains("/Users/example"))
    #expect(!key.contains("#private"))
    #expect(!key.contains("secret-rule"))
}

@Test
func graphGroupRuleCapsQueryAndNormalizesColor() {
    let longQuery = String(repeating: "a", count: GraphGroupRule.maxQueryLength + 20)
    let rule = GraphGroupRule(id: "rule", query: longQuery, colorHex: "FF00AA")

    #expect(rule.query.count == GraphGroupRule.maxQueryLength)
    #expect(rule.colorHex == "#ff00aa")
}

@Test
func graphGroupMatcherMatchesLabelsPathsAndTags() {
    let layout = GraphRendererSnapshot(
        requestID: 1,
        generation: 1,
        nodes: [
            GraphLayoutNode(
                index: 0,
                nodeID: "file:daily",
                relativePath: "Daily/Today.md",
                label: "Today",
                kind: .resolved,
                degree: 1,
                tags: ["journal"],
                position: GraphPoint(x: 0, y: 0),
                radius: 4
            ),
            GraphLayoutNode(
                index: 1,
                nodeID: "file:project",
                relativePath: "Projects/Roadmap.md",
                label: "Roadmap",
                kind: .resolved,
                degree: 1,
                tags: ["work"],
                position: GraphPoint(x: 20, y: 0),
                radius: 4
            )
        ],
        edges: [],
        components: []
    )

    let colors = GraphGroupMatcher.groupColorHexByNodeID(
        in: layout,
        rules: [
            GraphGroupRule(id: "tag", query: "#journal", colorHex: "#2da44e"),
            GraphGroupRule(id: "path", query: "Projects", colorHex: "#2f81f7")
        ]
    )

    #expect(colors["file:daily"] == "#2da44e")
    #expect(colors["file:project"] == "#2f81f7")
}

@Test
func graphWorkspaceModelRetainsPreviousStableGraphDuringFailures() {
    let stable = GraphStableGraphSummary(generation: 7, nodeCount: 10, edgeCount: 12)
    var model = GraphWorkspaceModel()

    model.applyStableGraph(stable)
    model.beginRecompute()

    #expect(model.shouldDisplayPreviousStableGraph)
    #expect(model.previousStableGraph == stable)

    model.fail(.decodeFailed)

    #expect(model.state == .decodeFailed)
    #expect(model.shouldDisplayPreviousStableGraph)
    #expect(model.previousStableGraph == stable)
}

@Test
func graphWorkspaceModelClearsStableGraphForIncompatibleStates() {
    let stable = GraphStableGraphSummary(generation: 7, nodeCount: 10, edgeCount: 12)
    var model = GraphWorkspaceModel()

    model.applyStableGraph(stable)
    model.clear(.noVault)

    #expect(model.state == .noVault)
    #expect(model.previousStableGraph == nil)
    #expect(!model.shouldDisplayPreviousStableGraph)
}
