import AppKit
import NativeMarkdownCore
import SwiftUI

struct AppContentZoomCommands: Commands {
    @AppStorage(AppContentZoom.storageKey) private var rawScale = AppContentZoom.defaultScale

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Actual Size") {
                rawScale = AppContentZoom.actualSize.scale
            }
            .keyboardShortcut("0", modifiers: [.command])

            Button("Zoom In") {
                rawScale = AppContentZoom(rawScale: rawScale).zoomedIn().scale
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button("Zoom Out") {
                rawScale = AppContentZoom(rawScale: rawScale).zoomedOut().scale
            }
            .keyboardShortcut("-", modifiers: [.command])
        }
    }
}

@MainActor
final class AppContentZoomMenuController: NSObject {
    static let shared = AppContentZoomMenuController()

    private let itemIdentifierPrefix = "granite.appContentZoom."
    private let maxInstallAttempts = 20

    private override init() {}

    func installWhenMainMenuIsReady() {
        installWhenMainMenuIsReady(remainingAttempts: maxInstallAttempts)
    }

    private func installWhenMainMenuIsReady(remainingAttempts: Int) {
        if install() || remainingAttempts <= 0 {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.installWhenMainMenuIsReady(remainingAttempts: remainingAttempts - 1)
        }
    }

    @discardableResult
    func install(in mainMenu: NSMenu? = NSApp.mainMenu) -> Bool {
        guard let viewMenu = mainMenu?.item(withTitle: "View")?.submenu else {
            return false
        }
        guard !containsZoomItems(in: viewMenu) else {
            return true
        }

        let insertionIndex = viewMenu.items.firstIndex { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
            ?? viewMenu.numberOfItems
        var items: [NSMenuItem] = []
        if insertionIndex == 0 || viewMenu.item(at: insertionIndex - 1)?.isSeparatorItem != true {
            items.append(separatorItem())
        }
        items.append(contentsOf: [
            menuItem(
                title: "Actual Size",
                action: #selector(resetZoom(_:)),
                keyEquivalent: "0"
            ),
            menuItem(
                title: "Zoom In",
                action: #selector(zoomIn(_:)),
                keyEquivalent: "="
            ),
            menuItem(
                title: "Zoom Out",
                action: #selector(zoomOut(_:)),
                keyEquivalent: "-"
            )
        ])

        for (offset, item) in items.enumerated() {
            viewMenu.insertItem(item, at: insertionIndex + offset)
        }
        return true
    }

    private func containsZoomItems(in menu: NSMenu) -> Bool {
        menu.items.contains { $0.identifier?.rawValue.hasPrefix(itemIdentifierPrefix) == true }
    }

    private func separatorItem() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.identifier = NSUserInterfaceItemIdentifier(itemIdentifierPrefix + "separator")
        return item
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier(itemIdentifierPrefix + title)
        return item
    }

    @objc private func resetZoom(_ sender: Any?) {
        setScale(AppContentZoom.actualSize.scale)
    }

    @objc private func zoomIn(_ sender: Any?) {
        setScale(currentZoom().zoomedIn().scale)
    }

    @objc private func zoomOut(_ sender: Any?) {
        setScale(currentZoom().zoomedOut().scale)
    }

    private func currentZoom() -> AppContentZoom {
        AppContentZoom(rawScale: UserDefaults.standard.double(forKey: AppContentZoom.storageKey))
    }

    private func setScale(_ scale: Double) {
        UserDefaults.standard.set(AppContentZoom(rawScale: scale).scale, forKey: AppContentZoom.storageKey)
    }
}
