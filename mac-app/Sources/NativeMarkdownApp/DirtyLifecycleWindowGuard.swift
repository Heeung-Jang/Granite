import AppKit
import SwiftUI

struct DirtyLifecycleWindowGuard: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowAttachmentView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.detach()
    }

    final class WindowAttachmentView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else {
                detach()
                return
            }

            if window === newWindow, newWindow.delegate === self {
                return
            }

            detach()
            window = newWindow
            previousDelegate = newWindow.delegate
            newWindow.delegate = self
        }

        func detach() {
            if window?.delegate === self {
                window?.delegate = previousDelegate
            }
            window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard AppLifecycleController.shared.requestWindowClose(sender) else {
                return false
            }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
        }
    }
}
