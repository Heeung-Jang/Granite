import AppKit
import NativeMarkdownCore
import SwiftUI

@main
@MainActor
struct GraniteApp: App {
    @NSApplicationDelegateAdaptor(GraniteAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var editorFontSettings = EditorFontSettings()

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
            AppTelemetry.graphOpened(source: .keyboard)
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
            AppTelemetry.graphDrawCompleted(GraphRendererMetrics(
                rendererKind: .canvas,
                nodeCount: 1,
                edgeCount: 0,
                drawDurationMilliseconds: 1
            ))
            AppTelemetry.graphStageCompleted(
                stage: .layout,
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

        if CommandLine.arguments.contains("--graph-canvas-smoke-test") {
            do {
                let metrics = try GraphCanvasRendererSmokeProbe.run()
                AppTelemetry.graphDrawCompleted(metrics)
                print("Graph canvas smoke test renderer=\(metrics.rendererKind.rawValue) nodes=\(metrics.nodeCount) edges=\(metrics.edgeCount)")
                Foundation.exit(0)
            } catch {
                print("Graph canvas smoke test failed")
                Foundation.exit(2)
            }
        }

        if CommandLine.arguments.contains("--graph-load-smoke-test") {
            do {
                let metrics = try GraphLoadSmokeProbe.run()
                print("Graph load smoke test renderer=\(metrics.rendererKind.rawValue) nodes=\(metrics.nodeCount) edges=\(metrics.edgeCount)")
                Foundation.exit(0)
            } catch {
                print("Graph load smoke test failed")
                Foundation.exit(2)
            }
        }

        if let payloadBenchmarkIndex = CommandLine.arguments.firstIndex(of: "--graph-payload-benchmark") {
            do {
                let payloadPathIndex = CommandLine.arguments.index(after: payloadBenchmarkIndex)
                guard CommandLine.arguments.indices.contains(payloadPathIndex) else {
                    print("Graph payload benchmark failed")
                    Foundation.exit(2)
                }
                let payloadURL = URL(fileURLWithPath: CommandLine.arguments[payloadPathIndex])
                print(try GraphPayloadBenchmarkProbe.encodedResult(payloadURL: payloadURL))
                Foundation.exit(0)
            } catch {
                print("Graph payload benchmark failed")
                Foundation.exit(2)
            }
        }

        if let canvasBenchmarkIndex = CommandLine.arguments.firstIndex(of: "--graph-canvas-benchmark") {
            do {
                let payloadPathIndex = CommandLine.arguments.index(after: canvasBenchmarkIndex)
                guard CommandLine.arguments.indices.contains(payloadPathIndex) else {
                    print("Graph canvas benchmark failed")
                    Foundation.exit(2)
                }
                let payloadURL = URL(fileURLWithPath: CommandLine.arguments[payloadPathIndex])
                print(try GraphCanvasBenchmarkProbe.encodedResult(payloadURL: payloadURL))
                Foundation.exit(0)
            } catch {
                print("Graph canvas benchmark failed")
                Foundation.exit(2)
            }
        }

        if let metalBenchmarkIndex = CommandLine.arguments.firstIndex(of: "--graph-metal-benchmark") {
            do {
                let payloadPathIndex = CommandLine.arguments.index(after: metalBenchmarkIndex)
                guard CommandLine.arguments.indices.contains(payloadPathIndex) else {
                    print("Graph metal benchmark failed")
                    Foundation.exit(2)
                }
                let payloadURL = URL(fileURLWithPath: CommandLine.arguments[payloadPathIndex])
                print(try GraphMetalBenchmarkProbe.encodedResult(payloadURL: payloadURL))
                Foundation.exit(0)
            } catch {
                print("Graph metal benchmark failed")
                Foundation.exit(2)
            }
        }

        if CommandLine.arguments.contains("--textkit-strategy-probe") {
            print(TextKitStrategyProbe.encodedReport())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--editor-bridge-probe") {
            let report = MarkdownEditorBridgeProbe.run()
            print(MarkdownEditorBridgeProbe.encodedReport(report))
            Foundation.exit(report.summary.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--markdown-decoration-probe") {
            print(MarkdownDecorationProbe.encodedReport())
            Foundation.exit(0)
        }

        if CommandLine.arguments.contains("--live-preview-style-probe") {
            let report = LivePreviewStyleProbe.run()
            print(LivePreviewStyleProbe.encodedReport(report))
            Foundation.exit(report.summary.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--font-settings-probe") {
            let report = FontSettingsProbe.run()
            print(FontSettingsProbe.encodedReport(report))
            Foundation.exit(report.summary.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--live-preview-probe") {
            let report = LivePreviewProbe.run()
            print(LivePreviewProbe.encodedReport(report))
            Foundation.exit(report.hardCeilingPassed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--live-preview-syntax-probe") {
            Task.detached {
                let report = await LivePreviewSyntaxHighlightProbe.run()
                print(LivePreviewSyntaxHighlightProbe.encodedReport(report))
                Foundation.exit(report.summary.passed ? 0 : 2)
            }
            dispatchMain()
        }

        if CommandLine.arguments.contains("--workspace-tabs-probe") {
            let report = WorkspaceTabsProbe.run()
            print(WorkspaceTabsProbe.encodedReport(report))
            Foundation.exit(report.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--startup-vault-restore-probe") {
            let report = StartupVaultRestoreProbe.run()
            print(StartupVaultRestoreProbe.encodedReport(report))
            Foundation.exit(report.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--vault-creation-probe") {
            let report = VaultCreationProbe.run()
            print(VaultCreationProbe.encodedReport(report))
            Foundation.exit(report.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--file-tree-actions-probe") {
            let report = FileTreeActionsProbe.run()
            print(FileTreeActionsProbe.encodedReport(report))
            Foundation.exit(report.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--inspector-indexing-state-probe") {
            let report = InspectorIndexingRecoveryProbe.run()
            print(InspectorIndexingRecoveryProbe.encodedReport(report))
            Foundation.exit(report.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--workspace-pane-layout-probe") {
            let report = WorkspacePaneLayoutProbe.run()
            print(WorkspacePaneLayoutProbe.encodedReport(report))
            Foundation.exit(report.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--app-content-zoom-probe") {
            let report = AppContentZoomProbe.run()
            print(AppContentZoomProbe.encodedReport(report))
            Foundation.exit(report.summary.passed ? 0 : 2)
        }

        if CommandLine.arguments.contains("--summary-panel-probe") {
            Task.detached {
                let report = await SummaryPanelProbe.run()
                print(SummaryPanelProbe.encodedReport(report))
                Foundation.exit(report.summary.passed ? 0 : 2)
            }
            dispatchMain()
        }

        if CommandLine.arguments.contains("--foundation-models-smoke-probe") {
            Task.detached {
                let report = await FoundationModelsSummarySmokeProbe.run()
                print(FoundationModelsSummarySmokeProbe.encodedReport(report))
                Foundation.exit(report.summary.passed ? 0 : 2)
            }
            dispatchMain()
        }

        if CommandLine.arguments.contains("--foundation-models-performance-probe") {
            Task.detached {
                let report = await FoundationModelsSummaryPerformanceProbe.run(arguments: CommandLine.arguments)
                print(FoundationModelsSummaryPerformanceProbe.encodedReport(report))
                Foundation.exit(report.summary.passed ? 0 : 2)
            }
            dispatchMain()
        }

        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(editorFontSettings)
                .frame(minWidth: 1180, minHeight: 720)
                .toolbar(removing: .title)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            EditorCommands()
            VaultCommands()
            AppContentZoomCommands()
            GraphCommands(appState: appState)
        }

        Settings {
            GraniteSettingsView()
                .environmentObject(appState)
                .environmentObject(editorFontSettings)
        }
        .windowResizability(.contentSize)
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
