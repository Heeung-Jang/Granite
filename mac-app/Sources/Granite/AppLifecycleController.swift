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
        AppContentZoomMenuController.shared.installWhenMainMenuIsReady()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycleController.shared.requestAppQuit() ? .terminateNow : .terminateCancel
    }
}
