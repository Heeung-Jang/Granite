import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func workspacePathIdentityCanonicalizesVaultRelativePaths() {
    #expect(WorkspacePathIdentity.canonicalRelativePath("Codex//Daily/./Note.md") == "Codex/Daily/Note.md")
    #expect(WorkspacePathIdentity.canonicalRelativePath("  Codex/Note.md  ") == "Codex/Note.md")
    #expect(WorkspacePathIdentity.canonicalRelativePath("") == nil)
    #expect(WorkspacePathIdentity.canonicalRelativePath("/Codex/Note.md") == nil)
    #expect(WorkspacePathIdentity.canonicalRelativePath("../Note.md") == nil)
    #expect(WorkspacePathIdentity.canonicalRelativePath("Codex/../Note.md") == nil)
}

@Test
func workspaceTabModelsEmptyAndFileTabs() {
    let file = FileTreeItem(relativePath: "Codex//Daily/Note.md")
    let emptyTab = WorkspaceTab()
    let fileTab = WorkspaceTab(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, file: file)

    #expect(emptyTab.isEmpty)
    #expect(emptyTab.displayTitle == "Untitled")
    #expect(emptyTab.relativePathKey == nil)

    #expect(!fileTab.isEmpty)
    #expect(fileTab.file == file)
    #expect(fileTab.displayTitle == "Note.md")
    #expect(fileTab.relativePathKey == "Codex/Daily/Note.md")
}

@Test
func workspaceTabSessionNormalizesAndCapsPaths() {
    let paths = (0..<120).map { "Folder/Note-\($0).md" }
    let session = WorkspaceTabSession(
        tabs: ["Folder//Note.md", "Folder/./Note.md", "../escape.md"] + paths,
        activeRelativePath: "Folder/./Note.md"
    )

    #expect(session.tabs.first == "Folder/Note.md")
    #expect(session.tabs.count == WorkspaceTabSession.maxStoredTabs)
    #expect(session.tabs.filter { $0 == "Folder/Note.md" }.count == 1)
    #expect(!session.tabs.contains("../escape.md"))
    #expect(session.activeRelativePath == "Folder/Note.md")
}

@Test
func workspaceTabSessionDecodeNormalizesStoredPayloads() throws {
    let data = Data("""
    {
      "version": 1,
      "tabs": ["Folder//Note.md", "Folder/./Note.md", "/abs.md", "../escape.md"],
      "activeRelativePath": "/abs.md"
    }
    """.utf8)

    let session = try JSONDecoder().decode(WorkspaceTabSession.self, from: data)

    #expect(session.tabs == ["Folder/Note.md"])
    #expect(session.activeRelativePath == nil)
}

@Test
func userDefaultsWorkspaceTabSessionStoreKeepsPayloadRelative() throws {
    let suiteName = "WorkspaceTabStateTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsWorkspaceTabSessionStore(defaults: defaults, keyPrefix: "testTabs")
    let vaultURL = URL(fileURLWithPath: "/tmp/private-vault", isDirectory: true)
    let session = WorkspaceTabSession(
        tabs: ["Codex/Note.md", "Codex/Other.md"],
        activeRelativePath: "Codex/Other.md"
    )

    store.saveSession(session, forVaultAt: vaultURL)

    #expect(store.loadSession(forVaultAt: vaultURL) == session)
    let key = "testTabs.\(RecentVault.storageKey(for: vaultURL))"
    let data = try #require(defaults.data(forKey: key))
    let payload = try #require(String(data: data, encoding: .utf8))
    #expect(payload.contains("Codex"))
    #expect(!payload.contains(vaultURL.path))
}

@Test
func userDefaultsStartupVaultRestoreStorageRoundTrips() throws {
    let suiteName = "StartupVaultRestoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsStartupVaultRestoreStorage(defaults: defaults, key: "testSuppress")

    #expect(!store.loadSuppressesLastVaultRestore())

    store.saveSuppressesLastVaultRestore(true)
    #expect(store.loadSuppressesLastVaultRestore())

    store.saveSuppressesLastVaultRestore(false)
    #expect(!store.loadSuppressesLastVaultRestore())
}
