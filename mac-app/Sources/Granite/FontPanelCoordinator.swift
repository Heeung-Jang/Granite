import AppKit

@MainActor
final class FontPanelCoordinator: NSObject {
    weak var editorFontSettings: EditorFontSettings?
    var activeRole: (() -> FontPreferenceRole?)?
    private static weak var currentOwner: FontPanelCoordinator?

    func beginOwningFontPanel() {
        Self.currentOwner = self
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
    }

    func clearFontPanelOwnershipIfCurrent() {
        guard Self.currentOwner === self else {
            return
        }
        if NSFontManager.shared.target === self {
            NSFontManager.shared.target = nil
        }
        Self.currentOwner = nil
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let role = activeRole?(),
              let selectedFont = sender?.selectedFont ?? NSFontManager.shared.selectedFont,
              let editorFontSettings
        else {
            return
        }

        switch role {
        case .text:
            guard let familyName = normalizedFamilyName(selectedFont.familyName) else {
                return
            }
            editorFontSettings.setTextFontFamily(familyName)
        case .monospace:
            editorFontSettings.selectMonospaceFont(selectedFont)
        }
    }

    private func normalizedFamilyName(_ familyName: String?) -> String? {
        guard let familyName else {
            return nil
        }
        let trimmed = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
