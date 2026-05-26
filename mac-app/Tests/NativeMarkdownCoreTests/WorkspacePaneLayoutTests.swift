import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func workspacePaneLayoutDefaults() {
    let layout = WorkspacePaneLayout.default

    #expect(layout.leftSidebarWidth == WorkspacePaneLayout.defaultLeftSidebarWidth)
    #expect(layout.rightSidebarWidth == WorkspacePaneLayout.defaultRightSidebarWidth)
    #expect(!layout.isLeftSidebarCollapsed)
    #expect(!layout.isRightSidebarCollapsed)
}

@Test
func workspacePaneLayoutNormalizesInvalidWidths() throws {
    let layout = WorkspacePaneLayout(
        leftSidebarWidth: .nan,
        rightSidebarWidth: 0,
        isLeftSidebarCollapsed: true,
        isRightSidebarCollapsed: true
    )

    #expect(layout.leftSidebarWidth == WorkspacePaneLayout.defaultLeftSidebarWidth)
    #expect(layout.rightSidebarWidth == WorkspacePaneLayout.minSidebarWidth)
    #expect(layout.isLeftSidebarCollapsed)
    #expect(layout.isRightSidebarCollapsed)

    let data = Data("""
    {
      "leftSidebarWidth": 120,
      "rightSidebarWidth": 199,
      "isLeftSidebarCollapsed": true,
      "isRightSidebarCollapsed": false
    }
    """.utf8)

    let decoded = try JSONDecoder().decode(WorkspacePaneLayout.self, from: data)
    #expect(decoded.leftSidebarWidth == WorkspacePaneLayout.minSidebarWidth)
    #expect(decoded.rightSidebarWidth == WorkspacePaneLayout.minSidebarWidth)
    #expect(decoded.isLeftSidebarCollapsed)
    #expect(!decoded.isRightSidebarCollapsed)
}

@Test
func workspacePaneLayoutDragDeltaMath() {
    #expect(WorkspacePaneLayout.proposedLeftSidebarWidth(startWidth: 272, translationWidth: 30) == 302)
    #expect(WorkspacePaneLayout.proposedLeftSidebarWidth(startWidth: 272, translationWidth: -30) == 242)
    #expect(WorkspacePaneLayout.proposedRightSidebarWidth(startWidth: 300, translationWidth: 30) == 270)
    #expect(WorkspacePaneLayout.proposedRightSidebarWidth(startWidth: 300, translationWidth: -30) == 330)
}

@Test
func workspacePaneLayoutClampsSidebarsAndProtectsCenterWhenPossible() {
    let layout = WorkspacePaneLayout(leftSidebarWidth: 272, rightSidebarWidth: 300)

    #expect(layout.settingLeftSidebarWidth(80, availableWidth: 1_200).leftSidebarWidth == 200)
    #expect(layout.settingRightSidebarWidth(80, availableWidth: 1_200).rightSidebarWidth == 200)

    let expandedLeft = layout.settingLeftSidebarWidth(900, availableWidth: 1_000)
    #expect(expandedLeft.leftSidebarWidth == 340)

    let expandedRight = layout.settingRightSidebarWidth(900, availableWidth: 1_000)
    #expect(expandedRight.rightSidebarWidth == 368)

    let collapsedRight = WorkspacePaneLayout(
        leftSidebarWidth: 272,
        rightSidebarWidth: 300,
        isRightSidebarCollapsed: true
    )
    #expect(collapsedRight.settingLeftSidebarWidth(900, availableWidth: 1_000).leftSidebarWidth == 640)
}

@Test
func workspacePaneLayoutTogglesPreserveWidths() {
    let layout = WorkspacePaneLayout(leftSidebarWidth: 312, rightSidebarWidth: 344)

    let leftCollapsed = layout.togglingLeftSidebarCollapsed()
    #expect(leftCollapsed.leftSidebarWidth == 312)
    #expect(leftCollapsed.isLeftSidebarCollapsed)

    let rightCollapsed = leftCollapsed.togglingRightSidebarCollapsed()
    #expect(rightCollapsed.rightSidebarWidth == 344)
    #expect(rightCollapsed.isRightSidebarCollapsed)
}

@Test
func userDefaultsWorkspacePaneLayoutStoreRoundTripsPrivately() throws {
    let suiteName = "WorkspacePaneLayoutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsWorkspacePaneLayoutStore(defaults: defaults, keyPrefix: "testPane")
    let vaultURL = URL(fileURLWithPath: "/tmp/private-pane-vault", isDirectory: true)
    let layout = WorkspacePaneLayout(
        leftSidebarWidth: 333,
        rightSidebarWidth: 444,
        isLeftSidebarCollapsed: true,
        isRightSidebarCollapsed: false
    )

    store.saveLayout(layout, forVaultAt: vaultURL)

    #expect(store.loadLayout(forVaultAt: vaultURL) == layout)
    let key = store.storageKey(for: vaultURL)
    #expect(!key.contains(vaultURL.path))

    let data = try #require(defaults.data(forKey: key))
    let payload = try #require(String(data: data, encoding: .utf8))
    #expect(!payload.contains(vaultURL.path))
}

@Test
func userDefaultsWorkspacePaneLayoutStoreReturnsNilForMissingAndCorruptPayloads() throws {
    let suiteName = "WorkspacePaneLayoutCorruptTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = UserDefaultsWorkspacePaneLayoutStore(defaults: defaults, keyPrefix: "testPane")
    let vaultURL = URL(fileURLWithPath: "/tmp/corrupt-pane-vault", isDirectory: true)

    #expect(store.loadLayout(forVaultAt: vaultURL) == nil)

    defaults.set(Data("not-json".utf8), forKey: store.storageKey(for: vaultURL))
    #expect(store.loadLayout(forVaultAt: vaultURL) == nil)
}
