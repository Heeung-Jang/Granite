import Foundation

public protocol WorkspacePaneLayoutStoring {
    func loadLayout(forVaultAt vaultURL: URL) -> WorkspacePaneLayout?
    func saveLayout(_ layout: WorkspacePaneLayout, forVaultAt vaultURL: URL)
    func clearLayout(forVaultAt vaultURL: URL)
}

public struct UserDefaultsWorkspacePaneLayoutStore: WorkspacePaneLayoutStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "workspacePaneLayout"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func loadLayout(forVaultAt vaultURL: URL) -> WorkspacePaneLayout? {
        guard let data = defaults.data(forKey: storageKey(for: vaultURL)) else {
            return nil
        }
        return try? JSONDecoder().decode(WorkspacePaneLayout.self, from: data)
    }

    public func saveLayout(_ layout: WorkspacePaneLayout, forVaultAt vaultURL: URL) {
        guard let data = try? JSONEncoder().encode(layout) else {
            return
        }
        defaults.set(data, forKey: storageKey(for: vaultURL))
    }

    public func clearLayout(forVaultAt vaultURL: URL) {
        defaults.removeObject(forKey: storageKey(for: vaultURL))
    }

    func storageKey(for vaultURL: URL) -> String {
        "\(keyPrefix).v1.\(Self.stableHashHex(RecentVault.storageKey(for: vaultURL)))"
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
