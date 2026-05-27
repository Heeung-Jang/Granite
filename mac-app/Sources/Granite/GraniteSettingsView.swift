import AppKit
import NativeMarkdownCore
import SwiftUI

struct GraniteSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var editorFontSettings: EditorFontSettings
    @State private var activeFontRole: FontPreferenceRole?
    @State private var fontPanelCoordinator = FontPanelCoordinator()

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

            Section("Appearance") {
                FontPreferenceRow(
                    role: .text,
                    familyDisplayName: editorFontSettings.textFamilyDisplayName,
                    previewFont: editorFontSettings.textPreviewFont,
                    previewText: "The quick brown fox jumps over the lazy dog.",
                    isResetDisabled: !editorFontSettings.hasCustomTextFont,
                    warningText: nil,
                    chooseAction: chooseTextFont,
                    resetAction: { editorFontSettings.resetTextFont() }
                )
                FontPreferenceRow(
                    role: .monospace,
                    familyDisplayName: editorFontSettings.monospaceFamilyDisplayName,
                    previewFont: editorFontSettings.monospacePreviewFont,
                    previewText: "`code`, tables, and source syntax",
                    isResetDisabled: !editorFontSettings.hasCustomMonospaceFont,
                    warningText: editorFontSettings.monospaceWarningMessage,
                    chooseAction: chooseMonospaceFont,
                    resetAction: { editorFontSettings.resetMonospaceFont() }
                )
            }
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 560, height: 420)
        .onDisappear {
            activeFontRole = nil
            fontPanelCoordinator.clearFontPanelOwnershipIfCurrent()
        }
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

    private func chooseTextFont() {
        openFontPanel(role: .text, currentFont: editorFontSettings.textPreviewFont)
    }

    private func chooseMonospaceFont() {
        openFontPanel(role: .monospace, currentFont: editorFontSettings.monospacePreviewFont)
    }

    private func openFontPanel(role: FontPreferenceRole, currentFont: NSFont) {
        activeFontRole = role
        fontPanelCoordinator.editorFontSettings = editorFontSettings
        fontPanelCoordinator.activeRole = { activeFontRole }
        fontPanelCoordinator.beginOwningFontPanel()

        NSFontManager.shared.setSelectedFont(currentFont, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }
}

private struct FontPreferenceRow: View {
    let role: FontPreferenceRole
    let familyDisplayName: String
    let previewFont: NSFont
    let previewText: String
    let isResetDisabled: Bool
    let warningText: String?
    let chooseAction: () -> Void
    let resetAction: () -> Void

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(familyDisplayName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Button("Choose...", action: chooseAction)
                        .accessibilityLabel(role.chooseAccessibilityLabel)

                    Button("Reset", action: resetAction)
                        .disabled(isResetDisabled)
                        .accessibilityLabel(role.resetAccessibilityLabel)
                }

                Text(previewText)
                    .font(previewSwiftUIFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let warningText {
                    Text(warningText)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityLabel(role.warningAccessibilityLabel)
                }
            }
        } label: {
            Text(role.displayLabel)
        }
        .padding(.vertical, 2)
    }

    private var previewSwiftUIFont: Font {
        .custom(previewFont.fontName, size: previewFont.pointSize)
    }
}
