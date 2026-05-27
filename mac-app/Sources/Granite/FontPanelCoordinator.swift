import AppKit

@MainActor
final class FontPanelCoordinator: NSObject {
    weak var editorFontSettings: EditorFontSettings?
    var activeRole: (() -> FontPreferenceRole?)?
    private static weak var currentOwner: FontPanelCoordinator?
    private weak var previousTarget: AnyObject?
    private var previousAction: Selector?

    func beginOwningFontPanel() {
        let manager = NSFontManager.shared
        previousTarget = manager.target
        previousAction = manager.action
        Self.currentOwner = self
        manager.target = self
        manager.action = #selector(changeFont(_:))
    }

    func clearFontPanelOwnershipIfCurrent() {
        guard Self.currentOwner === self else {
            return
        }
        let manager = NSFontManager.shared
        if manager.target === self && manager.action == #selector(changeFont(_:)) {
            manager.target = previousTarget
            if let previousAction {
                manager.action = previousAction
            }
        }
        previousTarget = nil
        previousAction = nil
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
