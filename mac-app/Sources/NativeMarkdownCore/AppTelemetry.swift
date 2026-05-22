import Foundation
import OSLog

public struct AppTelemetryTimer: Sendable {
    private let startNanoseconds: UInt64

    public init(startNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startNanoseconds = startNanoseconds
    }

    public func elapsedMilliseconds(
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Double {
        Double(nowNanoseconds.saturatingSubtracting(startNanoseconds)) / 1_000_000
    }
}

public struct AppTelemetryPrivacySchema: Codable, Equatable, Sendable {
    public var allowedPublicFields: [String]
    public var disallowedRawFields: [String]

    public init(
        allowedPublicFields: [String],
        disallowedRawFields: [String]
    ) {
        self.allowedPublicFields = allowedPublicFields.sorted()
        self.disallowedRawFields = disallowedRawFields.sorted()
    }

    public func allowsPublicField(_ field: String) -> Bool {
        allowedPublicFields.contains(field)
    }

    public func rejectsRawField(_ field: String) -> Bool {
        disallowedRawFields.contains(field)
    }
}

public enum GraphTelemetryStage: String, Equatable, Sendable {
    case snapshot
    case decode
    case layout
    case draw
    case totalFirstRender

    public var signpostName: String {
        switch self {
        case .snapshot:
            return "graph.snapshot"
        case .decode:
            return "graph.decode"
        case .layout:
            return "graph.layout"
        case .draw:
            return "graph.draw"
        case .totalFirstRender:
            return "graph.first_render"
        }
    }
}

public struct GraphStageSignpostInterval {
    fileprivate let stage: GraphTelemetryStage
    fileprivate let name: StaticString
    fileprivate let state: OSSignpostIntervalState
}

public enum AppTelemetry {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Granite"
    private static let searchLogger = Logger(subsystem: subsystem, category: "Search")
    private static let navigationLogger = Logger(subsystem: subsystem, category: "Navigation")
    private static let sidebarLogger = Logger(subsystem: subsystem, category: "Sidebar")
    private static let inspectorLogger = Logger(subsystem: subsystem, category: "Inspector")
    private static let editorLogger = Logger(subsystem: subsystem, category: "Editor")
    private static let saveLogger = Logger(subsystem: subsystem, category: "Save")
    private static let graphLogger = Logger(subsystem: subsystem, category: "Graph")
    private static let graphSignposter = OSSignposter(logger: graphLogger)

    public static let privacySchema = AppTelemetryPrivacySchema(
        allowedPublicFields: [
            "appliedRuns",
            "appKitControlCountAfter",
            "appKitControlCountBefore",
            "appKitControlDelta",
            "blockCount",
            "byteCount",
            "changedRangeCount",
            "changedUTF16Length",
            "durationMilliseconds",
            "embedCount",
            "fallbackReason",
            "fixtureID",
            "hardCeilingPassed",
            "hardCeilingViolations",
            "iterationCount",
            "memoryDeltaBytes",
            "mode",
            "nodeCount",
            "edgeCount",
            "rendererKind",
            "resultCount",
            "source",
            "stageName",
            "state",
            "tableCellCount",
            "textLength",
            "visibleRangeLength"
        ],
        disallowedRawFields: [
            "absolutePath",
            "attachmentFilename",
            "embedName",
            "fileName",
            "frontmatterValue",
            "groupQuery",
            "groupRule",
            "linkTarget",
            "noteText",
            "rawPath",
            "renderedSnippet",
            "searchQuery",
            "selectedText",
            "tagName"
        ]
    )

    public static func redactedIdentifier(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    public static func searchInputChanged(mode: SearchMode, queryLength: Int) {
        searchLogger.debug("Search input mode=\(mode.rawValue, privacy: .public) length=\(queryLength, privacy: .public)")
    }

    public static func searchCompleted(
        mode: SearchMode,
        state: SearchResultState,
        resultCount: Int,
        durationMilliseconds: Double
    ) {
        searchLogger.info("Search completed mode=\(mode.rawValue, privacy: .public) state=\(state.rawValue, privacy: .public) results=\(resultCount, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)")
    }

    public static func noteOpened(_ file: FileTreeItem) {
        navigationLogger.info("Note opened id=\(redactedIdentifier(for: file.relativePath), privacy: .public)")
    }

    public static func noteLoadCompleted(
        _ file: FileTreeItem,
        success: Bool,
        durationMilliseconds: Double
    ) {
        navigationLogger.info("Note load id=\(redactedIdentifier(for: file.relativePath), privacy: .public) success=\(success, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)")
    }

    public static func sidebarRefreshCompleted(
        state: FileTreeResultState?,
        itemCount: Int,
        durationMilliseconds: Double
    ) {
        sidebarLogger.info("Sidebar refresh state=\(state?.rawValue ?? "none", privacy: .public) items=\(itemCount, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)")
    }

    public static func inspectorRefreshCompleted(
        state: SearchResultState,
        outgoingCount: Int,
        backlinkCount: Int,
        tagCount: Int,
        propertyCount: Int,
        durationMilliseconds: Double
    ) {
        inspectorLogger.info("Inspector refresh state=\(state.rawValue, privacy: .public) outgoing=\(outgoingCount, privacy: .public) backlinks=\(backlinkCount, privacy: .public) tags=\(tagCount, privacy: .public) properties=\(propertyCount, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)")
    }

    public static func graphRendered(
        _ file: FileTreeItem,
        state: SearchResultState,
        nodeCount: Int,
        edgeCount: Int,
        durationMilliseconds: Double
    ) {
        graphLogger.info("Graph rendered id=\(redactedIdentifier(for: file.relativePath), privacy: .public) state=\(state.rawValue, privacy: .public) nodes=\(nodeCount, privacy: .public) edges=\(edgeCount, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)")
    }

    public static func graphOpened(source: GraphOpenSource) {
        graphLogger.info("graph_opened source=\(source.rawValue, privacy: .public)")
    }

    public static func graphDrawCompleted(_ metrics: GraphRendererMetrics) {
        graphLogger.info("first_draw_completed renderer=\(metrics.rendererKind.rawValue, privacy: .public) nodes=\(metrics.nodeCount, privacy: .public) edges=\(metrics.edgeCount, privacy: .public) duration_ms=\(metrics.drawDurationMilliseconds, privacy: .public)")
    }

    public static func graphStageCompleted(
        stage: GraphTelemetryStage,
        state: SearchResultState,
        nodeCount: Int,
        edgeCount: Int,
        durationMilliseconds: Double
    ) {
        graphSignposter.emitEvent("graph_stage_completed", "stageName=\(stage.rawValue, privacy: .public)")
        graphLogger.info("graph_stage_completed stageName=\(stage.rawValue, privacy: .public) state=\(state.rawValue, privacy: .public) nodes=\(nodeCount, privacy: .public) edges=\(edgeCount, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)")
    }

    public static func beginGraphStage(_ stage: GraphTelemetryStage) -> GraphStageSignpostInterval {
        switch stage {
        case .snapshot:
            return beginGraphStage(stage, name: "graph.snapshot")
        case .decode:
            return beginGraphStage(stage, name: "graph.decode")
        case .layout:
            return beginGraphStage(stage, name: "graph.layout")
        case .draw:
            return beginGraphStage(stage, name: "graph.draw")
        case .totalFirstRender:
            return beginGraphStage(stage, name: "graph.first_render")
        }
    }

    private static func beginGraphStage(
        _ stage: GraphTelemetryStage,
        name: StaticString
    ) -> GraphStageSignpostInterval {
        GraphStageSignpostInterval(
            stage: stage,
            name: name,
            state: graphSignposter.beginInterval(
                name,
                "stageName=\(stage.rawValue, privacy: .public)"
            )
        )
    }

    public static func endGraphStage(_ interval: GraphStageSignpostInterval) {
        graphSignposter.endInterval(
            interval.name,
            interval.state,
            "stageName=\(interval.stage.rawValue, privacy: .public)"
        )
    }

    public static func saveRequested(file: FileTreeItem?, available: Bool) {
        let fileID = file.map { redactedIdentifier(for: $0.relativePath) } ?? "none"
        saveLogger.info("Save requested id=\(fileID, privacy: .public) available=\(available, privacy: .public)")
    }

    public static func editorDecorationCompleted(
        textLength: Int,
        durationMilliseconds: Double
    ) {
        editorLogger.debug("Editor decoration text_length=\(textLength, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)")
    }
}

private extension UInt64 {
    func saturatingSubtracting(_ value: UInt64) -> UInt64 {
        self >= value ? self - value : 0
    }
}
