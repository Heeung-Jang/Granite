import Foundation

public struct EditorFontPreferences: Codable, Equatable, Sendable {
    public var textFamilyName: String?
    public var monospaceFamilyName: String?

    public init(
        textFamilyName: String? = nil,
        monospaceFamilyName: String? = nil
    ) {
        self.textFamilyName = Self.normalizedFamilyName(textFamilyName)
        self.monospaceFamilyName = Self.normalizedFamilyName(monospaceFamilyName)
    }

    static func normalizedFamilyName(_ familyName: String?) -> String? {
        guard let familyName else {
            return nil
        }
        let trimmed = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol EditorFontPreferenceStoring {
    func load() -> EditorFontPreferences
    func saveTextFamilyName(_ familyName: String?)
    func saveMonospaceFamilyName(_ familyName: String?)
    func resetTextFamilyName()
    func resetMonospaceFamilyName()
}

public struct UserDefaultsEditorFontPreferenceStore: EditorFontPreferenceStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "editorFontPreferences.v1"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func load() -> EditorFontPreferences {
        EditorFontPreferences(
            textFamilyName: defaults.string(forKey: textFamilyNameKey),
            monospaceFamilyName: defaults.string(forKey: monospaceFamilyNameKey)
        )
    }

    public func saveTextFamilyName(_ familyName: String?) {
        save(familyName, forKey: textFamilyNameKey)
    }

    public func saveMonospaceFamilyName(_ familyName: String?) {
        save(familyName, forKey: monospaceFamilyNameKey)
    }

    public func resetTextFamilyName() {
        defaults.removeObject(forKey: textFamilyNameKey)
    }

    public func resetMonospaceFamilyName() {
        defaults.removeObject(forKey: monospaceFamilyNameKey)
    }

    private var textFamilyNameKey: String {
        "\(keyPrefix).textFamilyName"
    }

    private var monospaceFamilyNameKey: String {
        "\(keyPrefix).monospaceFamilyName"
    }

    private func save(_ familyName: String?, forKey key: String) {
        guard let familyName = EditorFontPreferences.normalizedFamilyName(familyName) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(familyName, forKey: key)
    }
}
