import Foundation
import Testing
@testable import NativeMarkdownCore

@Test
func paneLayoutStoreStartsWithDefaultLayoutWithoutVault() {
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(initialVaultURL: nil, storage: memoryStore)

    #expect(store.layout == .default)
    #expect(memoryStore.saveCount == 0)
    #expect(memoryStore.clearCount == 0)
}

@Test
func paneLayoutStoreLoadsSavedInitialVaultLayout() {
    let vaultURL = URL(fileURLWithPath: "/tmp/initial-saved-pane-vault", isDirectory: true)
    let savedLayout = WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444)
    let memoryStore = MemoryPaneLayoutStore(layouts: [
        RecentVault.storageKey(for: vaultURL): savedLayout
    ])

    let store = PaneLayoutStore(initialVaultURL: vaultURL, storage: memoryStore)

    #expect(store.layout == savedLayout)
    #expect(memoryStore.saveCount == 0)
}

@Test
func paneLayoutStoreFallsBackToDefaultForInitialVaultWithoutSavedLayout() {
    let vaultURL = URL(fileURLWithPath: "/tmp/initial-missing-pane-vault", isDirectory: true)
    let memoryStore = MemoryPaneLayoutStore()

    let store = PaneLayoutStore(initialVaultURL: vaultURL, storage: memoryStore)

    #expect(store.layout == .default)
    #expect(memoryStore.saveCount == 0)
}

@Test
func restoreLayoutLoadsSavedLayoutWithoutSaving() {
    let vaultURL = URL(fileURLWithPath: "/tmp/restore-saved-pane-vault", isDirectory: true)
    let savedLayout = WorkspacePaneLayout(
        leftSidebarWidth: 301,
        rightSidebarWidth: 402,
        isRightSidebarCollapsed: true
    )
    let memoryStore = MemoryPaneLayoutStore(layouts: [
        RecentVault.storageKey(for: vaultURL): savedLayout
    ])
    let store = PaneLayoutStore(storage: memoryStore)

    let restored = store.restoreLayout(forVaultAt: vaultURL)

    #expect(restored == savedLayout)
    #expect(store.layout == savedLayout)
    #expect(memoryStore.saveCount == 0)
}

@Test
func restoreLayoutFallsBackToDefaultWithoutSaving() {
    let vaultURL = URL(fileURLWithPath: "/tmp/restore-missing-pane-vault", isDirectory: true)
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)

    let restored = store.restoreLayout(forVaultAt: vaultURL)

    #expect(restored == .default)
    #expect(store.layout == .default)
    #expect(memoryStore.saveCount == 0)
}

@Test
func resetToDefaultOnlyUpdatesMemory() {
    let vaultURL = URL(fileURLWithPath: "/tmp/reset-pane-vault", isDirectory: true)
    let savedLayout = WorkspacePaneLayout(leftSidebarWidth: 350, rightSidebarWidth: 450)
    let memoryStore = MemoryPaneLayoutStore(layouts: [
        RecentVault.storageKey(for: vaultURL): savedLayout
    ])
    let store = PaneLayoutStore(initialVaultURL: vaultURL, storage: memoryStore)

    let resetLayout = store.resetToDefault()

    #expect(resetLayout == .default)
    #expect(store.layout == .default)
    #expect(memoryStore.loadLayout(forVaultAt: vaultURL) == savedLayout)
    #expect(memoryStore.saveCount == 0)
    #expect(memoryStore.clearCount == 0)
}

@Test
func clearStoredLayoutClearsOnlyTargetVaultWithoutChangingCurrentLayout() {
    let vaultURL = URL(fileURLWithPath: "/tmp/clear-target-pane-vault", isDirectory: true)
    let otherURL = URL(fileURLWithPath: "/tmp/clear-other-pane-vault", isDirectory: true)
    let currentLayout = WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444)
    let otherLayout = WorkspacePaneLayout(leftSidebarWidth: 355, rightSidebarWidth: 466)
    let memoryStore = MemoryPaneLayoutStore(layouts: [
        RecentVault.storageKey(for: vaultURL): currentLayout,
        RecentVault.storageKey(for: otherURL): otherLayout
    ])
    let store = PaneLayoutStore(initialVaultURL: vaultURL, storage: memoryStore)

    store.clearStoredLayout(forVaultAt: vaultURL)

    #expect(memoryStore.loadLayout(forVaultAt: vaultURL) == nil)
    #expect(memoryStore.loadLayout(forVaultAt: otherURL) == otherLayout)
    #expect(store.layout == currentLayout)
    #expect(memoryStore.clearCount == 1)
}

@Test
func setLayoutClampsAndPersistsWhenVaultExists() {
    let vaultURL = URL(fileURLWithPath: "/tmp/set-layout-pane-vault", isDirectory: true)
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)
    let layout = WorkspacePaneLayout(leftSidebarWidth: 900, rightSidebarWidth: 300)

    let updated = store.setLayout(layout, availableWidth: 1_000, vaultURL: vaultURL)

    #expect(updated.leftSidebarWidth == 340)
    #expect(updated.rightSidebarWidth == 300)
    #expect(store.layout == updated)
    #expect(memoryStore.saveCount == 1)
    #expect(memoryStore.loadLayout(forVaultAt: vaultURL) == updated)
}

@Test
func setLayoutDoesNotPersistWithoutVault() {
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)
    let layout = WorkspacePaneLayout(leftSidebarWidth: 321, rightSidebarWidth: 432)

    let updated = store.setLayout(layout, availableWidth: nil, vaultURL: nil)

    #expect(updated == layout)
    #expect(store.layout == layout)
    #expect(memoryStore.saveCount == 0)
}

@Test
func setLeftSidebarWidthClampsAndPersistsWhenVaultExists() {
    let vaultURL = URL(fileURLWithPath: "/tmp/left-width-pane-vault", isDirectory: true)
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)

    let minimum = store.setLeftSidebarWidth(80, availableWidth: 1_200, vaultURL: vaultURL)
    let protectedCenter = store.setLeftSidebarWidth(900, availableWidth: 1_000, vaultURL: vaultURL)

    #expect(minimum.leftSidebarWidth == 200)
    #expect(protectedCenter.leftSidebarWidth == 340)
    #expect(memoryStore.saveCount == 2)
    #expect(memoryStore.loadLayout(forVaultAt: vaultURL) == protectedCenter)
}

@Test
func setLeftSidebarWidthDoesNotPersistWithoutVault() {
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)

    let updated = store.setLeftSidebarWidth(320, availableWidth: 1_200, vaultURL: nil)

    #expect(updated.leftSidebarWidth == 320)
    #expect(memoryStore.saveCount == 0)
}

@Test
func setRightSidebarWidthClampsAndPersistsWhenVaultExists() {
    let vaultURL = URL(fileURLWithPath: "/tmp/right-width-pane-vault", isDirectory: true)
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)

    let minimum = store.setRightSidebarWidth(80, availableWidth: 1_200, vaultURL: vaultURL)
    let protectedCenter = store.setRightSidebarWidth(900, availableWidth: 1_000, vaultURL: vaultURL)

    #expect(minimum.rightSidebarWidth == 200)
    #expect(protectedCenter.rightSidebarWidth == 368)
    #expect(memoryStore.saveCount == 2)
    #expect(memoryStore.loadLayout(forVaultAt: vaultURL) == protectedCenter)
}

@Test
func setRightSidebarWidthDoesNotPersistWithoutVault() {
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)

    let updated = store.setRightSidebarWidth(320, availableWidth: 1_200, vaultURL: nil)

    #expect(updated.rightSidebarWidth == 320)
    #expect(memoryStore.saveCount == 0)
}

@Test
func toggleLeftSidebarCollapsedPreservesWidthsAndPersists() {
    let vaultURL = URL(fileURLWithPath: "/tmp/left-collapse-pane-vault", isDirectory: true)
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)
    _ = store.setLayout(
        WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444),
        availableWidth: nil,
        vaultURL: nil
    )

    let collapsed = store.toggleLeftSidebarCollapsed(vaultURL: vaultURL)

    #expect(collapsed.leftSidebarWidth == 333)
    #expect(collapsed.rightSidebarWidth == 444)
    #expect(collapsed.isLeftSidebarCollapsed)
    #expect(memoryStore.saveCount == 1)
    #expect(memoryStore.loadLayout(forVaultAt: vaultURL) == collapsed)
}

@Test
func toggleLeftSidebarCollapsedDoesNotPersistWithoutVault() {
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)

    let collapsed = store.toggleLeftSidebarCollapsed(vaultURL: nil)

    #expect(collapsed.isLeftSidebarCollapsed)
    #expect(memoryStore.saveCount == 0)
}

@Test
func toggleRightSidebarCollapsedPreservesWidthsAndPersists() {
    let vaultURL = URL(fileURLWithPath: "/tmp/right-collapse-pane-vault", isDirectory: true)
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)
    _ = store.setLayout(
        WorkspacePaneLayout(leftSidebarWidth: 333, rightSidebarWidth: 444),
        availableWidth: nil,
        vaultURL: nil
    )

    let collapsed = store.toggleRightSidebarCollapsed(vaultURL: vaultURL)

    #expect(collapsed.leftSidebarWidth == 333)
    #expect(collapsed.rightSidebarWidth == 444)
    #expect(collapsed.isRightSidebarCollapsed)
    #expect(memoryStore.saveCount == 1)
    #expect(memoryStore.loadLayout(forVaultAt: vaultURL) == collapsed)
}

@Test
func toggleRightSidebarCollapsedDoesNotPersistWithoutVault() {
    let memoryStore = MemoryPaneLayoutStore()
    let store = PaneLayoutStore(storage: memoryStore)

    let collapsed = store.toggleRightSidebarCollapsed(vaultURL: nil)

    #expect(collapsed.isRightSidebarCollapsed)
    #expect(memoryStore.saveCount == 0)
}

private final class MemoryPaneLayoutStore: WorkspacePaneLayoutStoring {
    private(set) var savedLayouts: [String: WorkspacePaneLayout]
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    init(layouts: [String: WorkspacePaneLayout] = [:]) {
        self.savedLayouts = layouts
    }

    func loadLayout(forVaultAt vaultURL: URL) -> WorkspacePaneLayout? {
        savedLayouts[RecentVault.storageKey(for: vaultURL)]
    }

    func saveLayout(_ layout: WorkspacePaneLayout, forVaultAt vaultURL: URL) {
        saveCount += 1
        savedLayouts[RecentVault.storageKey(for: vaultURL)] = layout
    }

    func clearLayout(forVaultAt vaultURL: URL) {
        clearCount += 1
        savedLayouts.removeValue(forKey: RecentVault.storageKey(for: vaultURL))
    }
}
