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
