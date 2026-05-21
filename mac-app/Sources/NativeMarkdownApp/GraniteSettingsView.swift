import NativeMarkdownCore
import SwiftUI

struct GraniteSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Application") {
                LabeledContent("Name", value: "Granite")
                LabeledContent("Engine", value: appState.engineHealth.displayText)
            }

            Section("Vault") {
                LabeledContent("State", value: vaultState)
                if let path = appState.vaultSelection.url?.path {
                    LabeledContent("Path") {
                        Text(path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 460, height: 260)
    }

    private var vaultState: String {
        switch appState.vaultSelection {
        case .noVault:
            return "No vault open"
        case .selected(let url):
            return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        case .unavailable(let issue):
            return issue.displayTitle
        }
    }
}
