import NativeMarkdownCore
import SwiftUI

struct GraphCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Graph") {
            Button("Open Graph View") {
                appState.openGraph(source: .keyboard)
            }
            .keyboardShortcut("g", modifiers: [.command])
        }
    }
}
