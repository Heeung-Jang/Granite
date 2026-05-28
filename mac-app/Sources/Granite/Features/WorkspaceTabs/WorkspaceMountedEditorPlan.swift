import NativeMarkdownCore

struct WorkspaceMountedEditorPlan: Equatable {
    let mountedTabIDs: [WorkspaceTab.ID]
    let openTabCount: Int
    let mountedEditorCount: Int
    let dirtyMountedCount: Int
    let cleanMountedCount: Int
    let cleanInactiveMountedCount: Int
}

enum WorkspaceMountedEditorPlanner {
    static let cleanInactiveBudget = 10

    static func reconcile(
        tabs: [WorkspaceTab],
        activeTabID: WorkspaceTab.ID?,
        existingMountedTabIDs: [WorkspaceTab.ID],
        cleanInactiveBudget: Int = Self.cleanInactiveBudget,
        isDirty: (WorkspaceTab) -> Bool
    ) -> WorkspaceMountedEditorPlan {
        let fileTabs = tabs.filter { $0.file != nil }
        let fileTabIDs = Set(fileTabs.map(\.id))
        var mounted = existingMountedTabIDs.filter { fileTabIDs.contains($0) }
        let dirtyIDs = Set(fileTabs.compactMap { tab in
            isDirty(tab) ? tab.id : nil
        })

        if let activeTabID, fileTabIDs.contains(activeTabID) {
            mounted.removeAll { $0 == activeTabID }
            mounted.append(activeTabID)
        }

        for tab in fileTabs where dirtyIDs.contains(tab.id) && !mounted.contains(tab.id) {
            mounted.append(tab.id)
        }

        var cleanInactiveIDs = mounted.filter { id in
            id != activeTabID && !dirtyIDs.contains(id)
        }
        while cleanInactiveIDs.count > cleanInactiveBudget {
            let evictedID = cleanInactiveIDs.removeFirst()
            mounted.removeAll { $0 == evictedID }
        }

        let mountedSet = Set(mounted)
        let dirtyMountedCount = dirtyIDs.intersection(mountedSet).count
        let cleanMountedCount = mounted.count - dirtyMountedCount
        let cleanInactiveMountedCount = mounted.filter { id in
            id != activeTabID && !dirtyIDs.contains(id)
        }.count

        return WorkspaceMountedEditorPlan(
            mountedTabIDs: mounted,
            openTabCount: fileTabs.count,
            mountedEditorCount: mounted.count,
            dirtyMountedCount: dirtyMountedCount,
            cleanMountedCount: cleanMountedCount,
            cleanInactiveMountedCount: cleanInactiveMountedCount
        )
    }
}
