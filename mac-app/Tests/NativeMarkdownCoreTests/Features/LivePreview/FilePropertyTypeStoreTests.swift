import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func filePropertyTypeStoreSavesTypesPerVault() throws {
    let suiteName = "FilePropertyTypeStoreTests-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsFilePropertyTypeStore(defaults: suite)
    let firstVault = URL(fileURLWithPath: "/tmp/vault-a")
    let secondVault = URL(fileURLWithPath: "/tmp/vault-b")

    store.saveType(.tags, for: "status", vaultURL: firstVault)

    #expect(store.loadType(for: "status", vaultURL: firstVault) == .tags)
    #expect(store.loadTypes(forVaultAt: firstVault) == ["status": .tags])
    #expect(store.loadType(for: "status", vaultURL: secondVault) == nil)
}

@Test
func filePropertyTypeStoreIgnoresInvalidStoredJSON() throws {
    let suiteName = "FilePropertyTypeStoreTests-\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsFilePropertyTypeStore(defaults: suite)
    let vault = URL(fileURLWithPath: "/tmp/vault")
    suite.set(Data("not-json".utf8), forKey: store.storageKey(for: vault))

    #expect(store.loadType(for: "status", vaultURL: vault) == nil)
}
