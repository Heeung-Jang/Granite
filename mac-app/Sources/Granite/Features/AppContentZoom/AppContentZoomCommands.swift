import NativeMarkdownCore
import SwiftUI

struct AppContentZoomCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Actual Size") {
                setZoom(.actualSize)
            }
            .keyboardShortcut("0", modifiers: [.command])

            Button("Zoom In") {
                setZoom(currentZoom().zoomedIn())
            }
            .keyboardShortcut("+", modifiers: [.command])

            Button("Zoom Out") {
                setZoom(currentZoom().zoomedOut())
            }
            .keyboardShortcut("-", modifiers: [.command])
        }
    }

    private func currentZoom() -> AppContentZoom {
        guard UserDefaults.standard.object(forKey: AppContentZoom.storageKey) != nil else {
            return .actualSize
        }
        return AppContentZoom(rawScale: UserDefaults.standard.double(forKey: AppContentZoom.storageKey))
    }

    private func setZoom(_ zoom: AppContentZoom) {
        UserDefaults.standard.set(zoom.scale, forKey: AppContentZoom.storageKey)
    }
}
