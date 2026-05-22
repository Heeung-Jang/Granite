import AppKit
import NativeMarkdownCore
import SwiftUI

struct GraphMagnificationGestureBridge: NSViewRepresentable {
    let canvasSize: GraphSize
    let onMagnify: (GraphMagnificationEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMagnify: onMagnify)
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.canvasSize = canvasSize
        context.coordinator.onMagnify = onMagnify
        view.coordinator = context.coordinator
        context.coordinator.attach(from: view)
    }

    static func dismantleNSView(_ view: AttachmentView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.detach()
    }

    final class AttachmentView: NSView {
        weak var coordinator: Coordinator?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.attach(from: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(from: self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var canvasSize: GraphSize?
        var onMagnify: (GraphMagnificationEvent) -> Void
        private weak var bridgeView: AttachmentView?
        private weak var attachedView: NSView?
        private var recognizer: NSMagnificationGestureRecognizer?

        init(onMagnify: @escaping (GraphMagnificationEvent) -> Void) {
            self.onMagnify = onMagnify
        }

        func attach(from view: AttachmentView) {
            guard let targetView = view.superview else {
                detach()
                bridgeView = view
                return
            }
            if attachedView !== targetView {
                detach()
                let recognizer = NSMagnificationGestureRecognizer(
                    target: self,
                    action: #selector(handleMagnification(_:))
                )
                recognizer.delegate = self
                targetView.addGestureRecognizer(recognizer)
                attachedView = targetView
                self.recognizer = recognizer
            } else {
                recognizer?.delegate = self
            }
            bridgeView = view
        }

        func detach() {
            if let recognizer,
               let attachedView {
                attachedView.removeGestureRecognizer(recognizer)
                recognizer.delegate = nil
            }
            recognizer = nil
            attachedView = nil
            bridgeView = nil
        }

        @objc private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                emitMagnification(recognizer)
                recognizer.magnification = 0
            case .ended, .cancelled, .failed:
                recognizer.magnification = 0
            default:
                break
            }
        }

        private func emitMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
            guard let bridgeView,
                  let attachedView,
                  let canvasSize,
                  canvasSize.width > 0,
                  canvasSize.height > 0
            else {
                return
            }
            let attachedLocation = recognizer.location(in: attachedView)
            let localLocation = bridgeView.convert(attachedLocation, from: attachedView)
            guard bridgeView.bounds.contains(localLocation),
                  recognizer.magnification.isFinite,
                  recognizer.magnification != 0
            else {
                return
            }
            onMagnify(GraphMagnificationEvent(
                magnification: Double(recognizer.magnification),
                localPoint: GraphPoint(
                    x: Double(localLocation.x),
                    y: Double(localLocation.y)
                ),
                canvasSize: canvasSize
            ))
        }

        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
        ) -> Bool {
            gestureRecognizer === recognizer || otherGestureRecognizer === recognizer
        }
    }
}
