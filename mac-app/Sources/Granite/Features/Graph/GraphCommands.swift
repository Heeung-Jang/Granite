import AppKit
import NativeMarkdownCore
import SwiftUI

struct GraphCommandActions {
    let resetView: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let clearSelection: () -> Void
    let openSelectedNode: () -> Void
    let toggleControls: () -> Void
    let canOpenSelectedNode: Bool
}

private struct GraphCommandActionsKey: FocusedValueKey {
    typealias Value = GraphCommandActions
}

extension FocusedValues {
    var graphCommandActions: GraphCommandActions? {
        get { self[GraphCommandActionsKey.self] }
        set { self[GraphCommandActionsKey.self] = newValue }
    }
}

struct GraphCommands: Commands {
    let appState: AppState
    @FocusedValue(\.graphCommandActions) private var graphCommandActions

    var body: some Commands {
        CommandMenu("Graph") {
            Button("Open Graph View") {
                appState.openGraph(source: .keyboard)
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(!GraphCommandShortcutPolicy.canOpenGraph(
                firstResponder: NSApp.keyWindow?.firstResponder
            ))

            Divider()

            Button("Reset Graph View") {
                graphCommandActions?.resetView()
            }
            .disabled(graphCommandActions == nil)

            Button("Zoom In") {
                graphCommandActions?.zoomIn()
            }
            .disabled(graphCommandActions == nil)

            Button("Zoom Out") {
                graphCommandActions?.zoomOut()
            }
            .disabled(graphCommandActions == nil)

            Button("Open Selected Node") {
                graphCommandActions?.openSelectedNode()
            }
            .disabled(graphCommandActions?.canOpenSelectedNode != true)

            Button("Clear Graph Selection") {
                graphCommandActions?.clearSelection()
            }
            .disabled(graphCommandActions == nil)

            Button("Toggle Graph Controls") {
                graphCommandActions?.toggleControls()
            }
            .disabled(graphCommandActions == nil)
        }
    }
}

private enum GraphCommandShortcutPolicy {
    static func canOpenGraph(firstResponder: NSResponder?) -> Bool {
        guard let firstResponder else {
            return true
        }
        return !(firstResponder is NSTextView) && !(firstResponder is NSTextField)
    }
}
