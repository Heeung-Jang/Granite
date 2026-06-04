import Foundation

public protocol FilePropertyTypeStoring {
    func loadTypes(forVaultAt vaultURL: URL) -> [String: FilePropertyType]
    func loadType(for propertyName: String, vaultURL: URL) -> FilePropertyType?
    func saveType(_ type: FilePropertyType, for propertyName: String, vaultURL: URL)
    func clearTypes(forVaultAt vaultURL: URL)
}

public struct UserDefaultsFilePropertyTypeStore: FilePropertyTypeStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "filePropertyTypes") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func loadTypes(forVaultAt vaultURL: URL) -> [String: FilePropertyType] {
        mapping(for: vaultURL).compactMapValues(FilePropertyType.init(rawValue:))
    }

    public func loadType(for propertyName: String, vaultURL: URL) -> FilePropertyType? {
        mapping(for: vaultURL)[normalizedName(propertyName)].flatMap(FilePropertyType.init(rawValue:))
    }

    public func saveType(_ type: FilePropertyType, for propertyName: String, vaultURL: URL) {
        let key = normalizedName(propertyName)
        guard !key.isEmpty else {
            return
        }
        var mapping = mapping(for: vaultURL)
        mapping[key] = type.rawValue
        save(mapping, for: vaultURL)
    }

    public func clearTypes(forVaultAt vaultURL: URL) {
        defaults.removeObject(forKey: storageKey(for: vaultURL))
    }

    func storageKey(for vaultURL: URL) -> String {
        "\(keyPrefix).v1.\(Self.stableHashHex(RecentVault.storageKey(for: vaultURL)))"
    }

    private func mapping(for vaultURL: URL) -> [String: String] {
        guard let data = defaults.data(forKey: storageKey(for: vaultURL)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded.filter { FilePropertyType(rawValue: $0.value) != nil }
    }

    private func save(_ mapping: [String: String], for vaultURL: URL) {
        guard let data = try? JSONEncoder().encode(mapping) else {
            return
        }
        defaults.set(data, forKey: storageKey(for: vaultURL))
    }

    private func normalizedName(_ propertyName: String) -> String {
        propertyName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func stableHashHex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
