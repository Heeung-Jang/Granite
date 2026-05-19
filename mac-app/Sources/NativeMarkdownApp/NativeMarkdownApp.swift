import NativeMarkdownCore
import SwiftUI

@main
@MainActor
struct NativeMarkdownApp: App {
    @StateObject private var appState = AppState()

    init() {
        if CommandLine.arguments.contains("--engine-smoke-test") {
            let expectedAbi = expectedAbiVersionArgument() ?? 1
            let status = EngineHealthClient(expectedAbiVersion: expectedAbi).load()
            print("\(status.state.rawValue): \(status.message)")
            Foundation.exit(status.state == .loaded ? 0 : 2)
        }

        if CommandLine.arguments.contains("--smoke-test") {
            print("NativeMarkdownApp smoke test")
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
            AppTelemetry.graphPlaceholderRendered(file)
            AppTelemetry.saveRequested(file: file, available: false)
            AppTelemetry.editorDecorationCompleted(textLength: 128, durationMilliseconds: 1)
            print("NativeMarkdownApp telemetry smoke test")
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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            EditorCommands()
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
