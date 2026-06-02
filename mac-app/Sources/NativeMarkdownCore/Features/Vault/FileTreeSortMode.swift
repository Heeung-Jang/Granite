import Foundation

public enum FileTreeSortMode: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case nameAscending
    case nameDescending
    case modifiedNewest
    case modifiedOldest

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .nameAscending:
            return "Name A to Z"
        case .nameDescending:
            return "Name Z to A"
        case .modifiedNewest:
            return "Modified newest"
        case .modifiedOldest:
            return "Modified oldest"
        }
    }
}

public protocol FileTreeSortModeStoring {
    func loadSortMode(forVaultAt vaultURL: URL) -> FileTreeSortMode
    func saveSortMode(_ mode: FileTreeSortMode, forVaultAt vaultURL: URL)
    func clearSortMode(forVaultAt vaultURL: URL)
}

public struct UserDefaultsFileTreeSortModeStore: FileTreeSortModeStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "fileTreeSortMode"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func loadSortMode(forVaultAt vaultURL: URL) -> FileTreeSortMode {
        guard let rawValue = defaults.string(forKey: storageKey(for: vaultURL)),
              let mode = FileTreeSortMode(rawValue: rawValue)
        else {
            return .nameAscending
        }
        return mode
    }

    public func saveSortMode(_ mode: FileTreeSortMode, forVaultAt vaultURL: URL) {
        defaults.set(mode.rawValue, forKey: storageKey(for: vaultURL))
    }

    public func clearSortMode(forVaultAt vaultURL: URL) {
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
