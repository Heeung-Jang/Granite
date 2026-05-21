import NativeMarkdownCore
import SwiftUI

@main
@MainActor
struct GraniteApp: App {
    @NSApplicationDelegateAdaptor(GraniteAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        if CommandLine.arguments.contains("--help") {
            print(ReadApiUIProbe.helpText())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--read-api-ui-probe") {
            Foundation.exit(ReadApiUIProbe.run(arguments: CommandLine.arguments))
        }

        if CommandLine.arguments.contains("--engine-smoke-test") {
            let expectedAbi = expectedAbiVersionArgument() ?? 1
            let status = EngineHealthClient(expectedAbiVersion: expectedAbi).load()
            print("\(status.state.rawValue): \(status.message)")
            Foundation.exit(status.state == .loaded ? 0 : 2)
        }

        if CommandLine.arguments.contains("--smoke-test") {
            print("Granite smoke test")
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--telemetry-smoke-test") {
            let file = FileTreeItem(relativePath: "Telemetry/Smoke.md")
            AppTelemetry.searchInputChanged(mode: .fileName, queryLength: 5)
            AppTelemetry.searchCompleted(mode: .fileName, state: .complete, resultCount: 1, durationMilliseconds: 1)
            AppTelemetry.noteOpened(file)
            AppTelemetry.noteLoadCompleted(file, success: true, durationMilliseconds: 1)
            AppTelemetry.sidebarRefreshCompleted(state: .complete, itemCount: 1, durationMilliseconds: 1)
            AppTelemetry.inspectorRefreshCompleted(
                state: .complete,
                outgoingCount: 1,
                backlinkCount: 1,
                tagCount: 1,
                propertyCount: 1,
                durationMilliseconds: 1
            )
            AppTelemetry.graphRendered(
                file,
                state: .complete,
                nodeCount: 1,
                edgeCount: 0,
                durationMilliseconds: 1
            )
            AppTelemetry.saveRequested(file: file, available: false)
            AppTelemetry.editorDecorationCompleted(textLength: 128, durationMilliseconds: 1)
            print("Granite telemetry smoke test")
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--textkit-strategy-probe") {
            print(TextKitStrategyProbe.encodedReport())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--editor-bridge-probe") {
            print(MarkdownEditorBridgeProbe.encodedReport())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--markdown-decoration-probe") {
            print(MarkdownDecorationProbe.encodedReport())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--live-preview-style-probe") {
            print(LivePreviewStyleProbe.encodedReport())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--live-preview-probe") {
            let report = LivePreviewProbe.run()
            print(LivePreviewProbe.encodedReport(report))
            Foundation.exit(report.hardCeilingPassed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--workspace-tabs-probe") {
            let report = WorkspaceTabsProbe.run()
            print(WorkspaceTabsProbe.encodedReport(report))
            Foundation.exit(report.passed ? 0 : 2)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1180, minHeight: 720)
                .toolbar(removing: .title)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            EditorCommands()
        }

        Settings {
            GraniteSettingsView()
                .environmentObject(appState)
        }
    }
}

private func expectedAbiVersionArgument() -> UInt32? {
    guard let index = CommandLine.arguments.firstIndex(of: "--expected-abi"),
          CommandLine.arguments.indices.contains(index + 1)
    else {
        return nil
    }
    return UInt32(CommandLine.arguments[index + 1])
}
