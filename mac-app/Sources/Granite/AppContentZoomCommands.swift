import NativeMarkdownCore
import SwiftUI

struct AppContentZoomCommands: Commands {
    @AppStorage(AppContentZoom.storageKey) private var rawScale = AppContentZoom.defaultScale

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Actual Size") {
                rawScale = AppContentZoom.actualSize.scale
            }
            .keyboardShortcut("0", modifiers: [.command])

            Button("Zoom In") {
                rawScale = AppContentZoom(rawScale: rawScale).zoomedIn().scale
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Zoom Out") {
                rawScale = AppContentZoom(rawScale: rawScale).zoomedOut().scale
            }
            .keyboardShortcut("-", modifiers: [.command])
        }
    }
}
