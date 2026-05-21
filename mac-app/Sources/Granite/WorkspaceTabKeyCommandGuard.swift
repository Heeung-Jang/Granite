import AppKit
import SwiftUI

struct WorkspaceTabKeyCommandGuard: NSViewRepresentable {
    let action: WorkspaceTabAction

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> KeyCommandAttachmentView {
        let view = KeyCommandAttachmentView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: KeyCommandAttachmentView, context: Context) {
        context.coordinator.action = action
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: KeyCommandAttachmentView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.detach()
    }

    final class KeyCommandAttachmentView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator {
        var action: WorkspaceTabAction
        private weak var window: NSWindow?
        private var monitor: Any?

        init(action: WorkspaceTabAction) {
            self.action = action
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else {
                detach()
                return
            }
            if let window, window !== newWindow {
                WorkspaceTabCommandRegistry.shared.unregister(window: window)
            }
            window = newWindow
            WorkspaceTabCommandRegistry.shared.register(action: action, for: newWindow)
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handle(event) == true ? nil : event
                }
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            WorkspaceTabCommandRegistry.shared.unregister(window: window)
            monitor = nil
            window = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard action.isAvailable,
                  event.window === window || event.window == nil && NSApp.keyWindow === window
            else {
                return false
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
                return false
            }

            switch (characters, modifiers) {
            case ("t", [.command]):
                action.newTab()
            case ("w", [.command]):
                action.closeActiveTab()
            case ("t", [.command, .shift]):
                action.restoreClosedTab()
            case ("\t", [.control]):
                action.activateNextTab()
            case ("\t", [.control, .shift]):
                action.activatePreviousTab()
            case ("1", [.command]), ("2", [.command]), ("3", [.command]),
                 ("4", [.command]), ("5", [.command]), ("6", [.command]),
                 ("7", [.command]), ("8", [.command]), ("9", [.command]):
                if let index = Int(characters) {
                    action.activateTabAtShortcutIndex(index)
                }
            default:
                return false
            }

            return true
        }
    }
}
