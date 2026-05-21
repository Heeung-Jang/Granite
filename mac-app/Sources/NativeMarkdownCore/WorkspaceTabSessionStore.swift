import Foundation

public struct WorkspaceTabSession: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxStoredTabs = 100

    public let version: Int
    public let tabs: [String]
    public let activeRelativePath: String?

    public init(
        version: Int = Self.currentVersion,
        tabs: [String],
        activeRelativePath: String?
    ) {
        self.version = version

        var seen = Set<String>()
        var normalizedTabs: [String] = []
        for tab in tabs {
            guard let key = WorkspacePathIdentity.canonicalRelativePath(tab),
                  seen.insert(key).inserted
            else {
                continue
            }
            normalizedTabs.append(key)
            if normalizedTabs.count == Self.maxStoredTabs {
                break
            }
        }

        self.tabs = normalizedTabs
        if let activeRelativePath,
           let activeKey = WorkspacePathIdentity.canonicalRelativePath(activeRelativePath),
           seen.contains(activeKey) {
            self.activeRelativePath = activeKey
        } else {
            self.activeRelativePath = nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        let tabs = try container.decodeIfPresent([String].self, forKey: .tabs) ?? []
        let activeRelativePath = try container.decodeIfPresent(String.self, forKey: .activeRelativePath)
        self.init(version: version, tabs: tabs, activeRelativePath: activeRelativePath)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(activeRelativePath, forKey: .activeRelativePath)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tabs
        case activeRelativePath
    }
}

public protocol WorkspaceTabSessionStoring {
    func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession?
    func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL)
    func clearSession(forVaultAt vaultURL: URL)
}

public struct UserDefaultsWorkspaceTabSessionStore: WorkspaceTabSessionStoring {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "workspaceTabSession"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func loadSession(forVaultAt vaultURL: URL) -> WorkspaceTabSession? {
        guard let data = defaults.data(forKey: storageKey(for: vaultURL)) else {
            return nil
        }
        return try? JSONDecoder().decode(WorkspaceTabSession.self, from: data)
    }

    public func saveSession(_ session: WorkspaceTabSession, forVaultAt vaultURL: URL) {
        let normalized = WorkspaceTabSession(
            version: session.version,
            tabs: session.tabs,
            activeRelativePath: session.activeRelativePath
        )
        guard !normalized.tabs.isEmpty,
              let data = try? JSONEncoder().encode(normalized)
        else {
            clearSession(forVaultAt: vaultURL)
            return
        }
        defaults.set(data, forKey: storageKey(for: vaultURL))
    }

    public func clearSession(forVaultAt vaultURL: URL) {
        defaults.removeObject(forKey: storageKey(for: vaultURL))
    }

    private func storageKey(for vaultURL: URL) -> String {
        "\(keyPrefix).\(RecentVault.storageKey(for: vaultURL))"
    }
}
