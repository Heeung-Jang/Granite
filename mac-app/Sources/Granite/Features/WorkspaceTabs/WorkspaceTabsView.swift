import AppKit
import NativeMarkdownCore
import SwiftUI
import UniformTypeIdentifiers

struct ObsidianTabBar: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let tabs: [WorkspaceTab]
    let activeTabID: WorkspaceTab.ID?
    let isDirty: (FileTreeItem) -> Bool
    let activateTab: (WorkspaceTab.ID) -> Void
    let closeTab: (WorkspaceTab.ID) -> Void
    let moveTab: (Int, Int) -> Void
    let newTab: () -> Void
    let showsRightSidebarToggle: Bool
    let isRightSidebarCollapsed: Bool
    let toggleRightSidebar: () -> Void
    @State private var draggedTabID: WorkspaceTab.ID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            ObsidianTabItem(
                                tab: tab,
                                isActive: tab.id == activeTabID,
                                isDirty: tab.file.map(isDirty) ?? false,
                                activate: {
                                    activateTab(tab.id)
                                },
                                close: {
                                    closeTab(tab.id)
                                }
                            )
                            .id(tab.id)
                            .onDrag {
                                draggedTabID = tab.id
                                return NSItemProvider(object: tab.id.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: ObsidianTabDropDelegate(
                                    targetTabID: tab.id,
                                    tabs: tabs,
                                    draggedTabID: $draggedTabID,
                                    moveTab: moveTab
                                )
                            )

                            Divider()
                                .frame(height: ObsidianUI.tabBarHeight(scale: appContentZoomScale))
                        }
                    }
                }
                .onChange(of: activeTabID) { _, newValue in
                    guard let newValue else {
                        return
                    }
                    withAnimation(.snappy(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            ObsidianIconButton(
                systemName: "plus",
                accessibilityLabel: "New tab",
                action: newTab
            )

            Spacer()

            if showsRightSidebarToggle {
                ObsidianIconButton(
                    systemName: "sidebar.right",
                    accessibilityLabel: isRightSidebarCollapsed ? "Expand right inspector" : "Collapse right inspector",
                    isSelected: !isRightSidebarCollapsed,
                    action: toggleRightSidebar
                )
                .padding(.trailing, ObsidianUI.scaled(4, scale: appContentZoomScale))
            }

            Image(systemName: "chevron.down")
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
                .padding(.trailing, ObsidianUI.scaled(14, scale: appContentZoomScale))
        }
        .frame(height: ObsidianUI.tabBarHeight(scale: appContentZoomScale))
        .background(ObsidianUI.sidebarBackground.opacity(0.55))
    }
}

private struct ObsidianTabDropDelegate: DropDelegate {
    let targetTabID: WorkspaceTab.ID
    let tabs: [WorkspaceTab]
    @Binding var draggedTabID: WorkspaceTab.ID?
    let moveTab: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedTabID,
              draggedTabID != targetTabID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == draggedTabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetTabID })
        else {
            return
        }
        moveTab(sourceIndex, targetIndex)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }
}

private struct ObsidianTabItem: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let tab: WorkspaceTab
    let isActive: Bool
    let isDirty: Bool
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: activate) {
                Text(displayTitle)
                    .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isDirty {
                Circle()
                    .fill(.secondary)
                    .frame(
                        width: ObsidianUI.scaled(6, scale: appContentZoomScale),
                        height: ObsidianUI.scaled(6, scale: appContentZoomScale)
                    )
                    .accessibilityLabel("Unsaved changes")
                    .padding(.leading, ObsidianUI.scaled(8, scale: appContentZoomScale))
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: ObsidianUI.fontSize(11, scale: appContentZoomScale)))
                    .foregroundStyle(.secondary)
                    .frame(
                        width: ObsidianUI.scaled(18, scale: appContentZoomScale),
                        height: ObsidianUI.scaled(18, scale: appContentZoomScale)
                    )
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .accessibilityLabel("Close tab")
            .padding(.leading, ObsidianUI.scaled(8, scale: appContentZoomScale))
        }
        .padding(.horizontal, ObsidianUI.scaled(14, scale: appContentZoomScale))
        .frame(height: ObsidianUI.tabBarHeight(scale: appContentZoomScale))
        .frame(width: ObsidianUI.scaled(220, scale: appContentZoomScale), alignment: .leading)
        .contentShape(Rectangle())
        .background(isActive ? ObsidianUI.editorBackground : Color.clear)
    }

    private var displayTitle: String {
        guard let file = tab.file else {
            return "Untitled"
        }
        return (file.displayName as NSString).deletingPathExtension
    }
}

struct EditorTabContentStack: View {
    @EnvironmentObject private var appState: AppState
    let vaultURL: URL
    let tabs: [WorkspaceTab]
    let activeTabID: WorkspaceTab.ID?
    let activeFile: FileTreeItem?
    @State private var mountedTabIDs: [WorkspaceTab.ID] = []
    @State private var focusRequestID: WorkspaceTab.ID?

    var body: some View {
        ZStack {
            ForEach(mountedTabs) { tab in
                if let file = tab.file {
                    ObsidianEditorPane(
                        vaultURL: vaultURL,
                        file: file,
                        isActive: tab.id == activeTabID,
                        focusRequestID: tab.id == activeTabID ? focusRequestID : nil
                    )
                        .opacity(tab.id == activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == activeTabID)
                        .accessibilityHidden(tab.id != activeTabID)
                        .zIndex(tab.id == activeTabID ? 1 : 0)
                }
            }
        }
        .onAppear {
            focusRequestID = activeFile == nil ? nil : activeTabID
            reconcileMountedTabs()
        }
        .onChange(of: activeTabID) { _, _ in
            focusRequestID = activeFile == nil ? nil : activeTabID
            reconcileMountedTabs()
        }
        .onChange(of: tabs.map(\.id)) { _, _ in
            reconcileMountedTabs()
        }
        .onChange(of: activeFile?.id) { _, _ in
            reconcileMountedTabs()
        }
    }

    private var mountedTabs: [WorkspaceTab] {
        mountedTabIDs.compactMap { id in
            tabs.first { $0.id == id && $0.file != nil }
        }
    }

    private func reconcileMountedTabs() {
        let plan = WorkspaceMountedEditorPlanner.reconcile(
            tabs: tabs,
            activeTabID: activeTabID,
            existingMountedTabIDs: mountedTabIDs
        ) { tab in
            guard let file = tab.file else {
                return false
            }
            return appState.isEditorDirty(file: file)
        }
        mountedTabIDs = plan.mountedTabIDs
    }
}

private struct ObsidianEditorPane: View {
    let vaultURL: URL
    let file: FileTreeItem
    var isActive = true
    var focusRequestID: WorkspaceTab.ID?

    var body: some View {
        VStack(spacing: 0) {
            ObsidianNoteToolbar(file: file)

            Divider()

            SourceNoteView(
                vaultURL: vaultURL,
                file: file,
                chrome: .obsidian,
                isActive: isActive,
                focusRequestID: focusRequestID
            )
        }
    }
}

private struct ObsidianNoteToolbar: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let file: FileTreeItem

    var body: some View {
        HStack(spacing: ObsidianUI.scaled(10, scale: appContentZoomScale)) {
            ObsidianIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: {})
            ObsidianIconButton(systemName: "chevron.right", accessibilityLabel: "Forward", action: {})

            Text(breadcrumb)
                .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer()

            ObsidianIconButton(systemName: "book", accessibilityLabel: "Reading view", action: {})
            ObsidianMarkerStyleMenu()
        }
        .padding(.horizontal, ObsidianUI.scaled(14, scale: appContentZoomScale))
        .frame(height: ObsidianUI.noteToolbarHeight(scale: appContentZoomScale))
        .background(ObsidianUI.editorBackground)
    }

    private var breadcrumb: String {
        let title = (file.displayName as NSString).deletingPathExtension
        return file.parentPath.isEmpty ? title : "\(file.parentPath) / \(title)"
    }
}

private struct ObsidianMarkerStyleMenu: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    @AppStorage(LivePreviewMarkerStyle.storageKey) private var markerStyleRaw = LivePreviewMarkerStyle.defaultValue.rawValue

    var body: some View {
        Menu {
            Picker("Marker Style", selection: $markerStyleRaw) {
                ForEach(LivePreviewMarkerStyle.allCases) { style in
                    Text(style.menuTitle).tag(style.rawValue)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: ObsidianUI.iconFontSize(scale: appContentZoomScale)))
                .foregroundStyle(.secondary)
                .frame(
                    width: ObsidianUI.iconButtonSize(scale: appContentZoomScale),
                    height: ObsidianUI.iconButtonSize(scale: appContentZoomScale)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Marker style")
        .accessibilityLabel("Marker style")
    }
}
