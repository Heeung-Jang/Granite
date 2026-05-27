import AppKit
import NativeMarkdownCore

@MainActor
final class EditorFontSettings: ObservableObject {
    @Published private(set) var preferences: EditorFontPreferences
    @Published private(set) var monospaceWarningMessage: String?

    private let store: any EditorFontPreferenceStoring

    init(store: any EditorFontPreferenceStoring = UserDefaultsEditorFontPreferenceStore()) {
        self.store = store
        preferences = store.load()
    }

    var fontSet: LivePreviewFontSet {
        LivePreviewFontResolver.fontSet(for: preferences)
    }

    var textFamilyDisplayName: String {
        displayName(
            for: fontSet.baseFont,
            defaultFont: LivePreviewTheme.defaultFontSet.baseFont,
            defaultDisplayName: "System"
        )
    }

    var monospaceFamilyDisplayName: String {
        displayName(
            for: fontSet.codeFont,
            defaultFont: LivePreviewTheme.defaultFontSet.codeFont,
            defaultDisplayName: "System Monospace"
        )
    }

    var textPreviewFont: NSFont {
        fontSet.baseFont
    }

    var monospacePreviewFont: NSFont {
        fontSet.codeFont
    }

    var hasCustomTextFont: Bool {
        preferences.textFamilyName != nil
    }

    var hasCustomMonospaceFont: Bool {
        preferences.monospaceFamilyName != nil
    }

    func setTextFontFamily(_ familyName: String?) {
        let normalizedFamilyName = normalizedFamilyName(familyName)
        store.saveTextFamilyName(normalizedFamilyName)
        preferences = EditorFontPreferences(
            textFamilyName: normalizedFamilyName,
            monospaceFamilyName: preferences.monospaceFamilyName
        )
    }

    func setMonospaceFontFamily(_ familyName: String?) {
        let normalizedFamilyName = normalizedFamilyName(familyName)
        store.saveMonospaceFamilyName(normalizedFamilyName)
        preferences = EditorFontPreferences(
            textFamilyName: preferences.textFamilyName,
            monospaceFamilyName: normalizedFamilyName
        )
    }

    func resetTextFont() {
        store.resetTextFamilyName()
        preferences = EditorFontPreferences(monospaceFamilyName: preferences.monospaceFamilyName)
    }

    func resetMonospaceFont() {
        store.resetMonospaceFamilyName()
        preferences = EditorFontPreferences(textFamilyName: preferences.textFamilyName)
        monospaceWarningMessage = nil
    }

    func clearMonospaceWarning() {
        monospaceWarningMessage = nil
    }

    @discardableResult
    func selectMonospaceFont(_ font: NSFont) -> Bool {
        guard LivePreviewFontResolver.isFixedPitch(font),
              let familyName = normalizedFamilyName(font.familyName)
        else {
            monospaceWarningMessage = "Choose a fixed-width font for Monospace font."
            return false
        }
        setMonospaceFontFamily(familyName)
        monospaceWarningMessage = nil
        return true
    }

    private func displayName(
        for font: NSFont,
        defaultFont: NSFont,
        defaultDisplayName: String
    ) -> String {
        if font.familyName == defaultFont.familyName {
            return defaultDisplayName
        }
        return font.familyName ?? font.displayName ?? defaultDisplayName
    }

    private func normalizedFamilyName(_ familyName: String?) -> String? {
        guard let familyName else {
            return nil
        }
        let trimmed = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
