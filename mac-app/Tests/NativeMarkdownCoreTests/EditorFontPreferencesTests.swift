import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func editorFontPreferencesNormalizeBlankFamilyNames() {
    let preferences = EditorFontPreferences(
        textFamilyName: "  ",
        monospaceFamilyName: "\n\t"
    )

    #expect(preferences.textFamilyName == nil)
    #expect(preferences.monospaceFamilyName == nil)
}

@Test
func userDefaultsEditorFontPreferenceStoreReturnsDefaultsForEmptyDomain() throws {
    let suiteName = "EditorFontPreferences.empty.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsEditorFontPreferenceStore(defaults: defaults, keyPrefix: "testFonts")

    #expect(store.load() == EditorFontPreferences())
}

@Test
func userDefaultsEditorFontPreferenceStoreSavesTextFamilyOnly() throws {
    let suiteName = "EditorFontPreferences.text.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsEditorFontPreferenceStore(defaults: defaults, keyPrefix: "testFonts")

    store.saveTextFamilyName("  Avenir Next  ")

    #expect(store.load() == EditorFontPreferences(textFamilyName: "Avenir Next"))
}

@Test
func userDefaultsEditorFontPreferenceStoreSavesMonospaceFamilyOnly() throws {
    let suiteName = "EditorFontPreferences.monospace.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsEditorFontPreferenceStore(defaults: defaults, keyPrefix: "testFonts")

    store.saveMonospaceFamilyName("  Menlo  ")

    #expect(store.load() == EditorFontPreferences(monospaceFamilyName: "Menlo"))
}

@Test
func userDefaultsEditorFontPreferenceStoreResetsTextAndMonospaceIndependently() throws {
    let suiteName = "EditorFontPreferences.reset.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsEditorFontPreferenceStore(defaults: defaults, keyPrefix: "testFonts")

    store.saveTextFamilyName("Avenir Next")
    store.saveMonospaceFamilyName("Menlo")
    store.resetTextFamilyName()

    #expect(store.load() == EditorFontPreferences(monospaceFamilyName: "Menlo"))

    store.saveTextFamilyName("Avenir Next")
    store.resetMonospaceFamilyName()

    #expect(store.load() == EditorFontPreferences(textFamilyName: "Avenir Next"))
}
