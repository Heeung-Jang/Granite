import AppKit
import NativeMarkdownCore

@MainActor
final class AppLifecycleController {
    static let shared = AppLifecycleController()

    var appState: AppState?
    private weak var pendingCloseWindow: NSWindow?

    private init() {}

    func requestWindowClose(_ window: NSWindow) -> Bool {
        guard let appState else {
            return true
        }

        let canClose = appState.requestWindowClose()
        if !canClose {
            pendingCloseWindow = window
        }
        return canClose
    }

    func requestAppQuit() -> Bool {
        appState?.requestAppQuit() ?? true
    }

    func performDiscardedLifecycleAction(_ action: DirtyLifecycleAction) {
        switch action {
        case .closeWindow:
            let window = pendingCloseWindow ?? NSApp.mainWindow ?? NSApp.keyWindow
            pendingCloseWindow = nil
            window?.performClose(nil)
        case .quitApp:
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class GraniteAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            self.openWindowIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        if !flag {
            openWindowIfNeeded()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycleController.shared.requestAppQuit() ? .terminateNow : .terminateCancel
    }

    private func openWindowIfNeeded() {
        guard !NSApp.windows.contains(where: \.isVisible),
              let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
              let newWindowItem = fileMenu.item(withTitle: "New Window"),
              let action = newWindowItem.action
        else {
            return
        }

        NSApp.sendAction(action, to: newWindowItem.target, from: newWindowItem)
    }
}
