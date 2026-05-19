import Foundation

public struct RecentVault: Identifiable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public var id: String {
        Self.storageKey(for: url)
    }

    public var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    public var displayPath: String {
        url.deletingLastPathComponent().path
    }

    static func storageKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

public protocol RecentVaultStoring {
    func loadRecentVaultURLs() -> [URL]
    func saveRecentVaultURLs(_ urls: [URL])
}

public struct UserDefaultsRecentVaultStorage: RecentVaultStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "recentVaultPaths"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func loadRecentVaultURLs() -> [URL] {
        defaults.stringArray(forKey: key)?
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? []
    }

    public func saveRecentVaultURLs(_ urls: [URL]) {
        defaults.set(urls.map { RecentVault.storageKey(for: $0) }, forKey: key)
    }
}
