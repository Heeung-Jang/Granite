import AppKit
import Foundation
import NativeMarkdownCore

struct TextKitStrategyProbeReport: Codable, Equatable {
    var selectedStrategy: String
    var thresholdBytes: Int
    var loadMeasurements: [TextKitLoadMeasurement]
    var visibleDecoration: TextKitOperationMeasurement
    var koreanMarkedTextSupported: Bool
    var headlessUndoRestoredInsertedText: Bool
    var requiresH02UndoValidation: Bool
    var selectionStableAfterDecoration: Bool
    var firstResponderAccepted: Bool
    var attachmentPlaceholderSupported: Bool
}

struct TextKitLoadMeasurement: Codable, Equatable {
    var label: String
    var bytes: Int
    var milliseconds: Double
}

struct TextKitOperationMeasurement: Codable, Equatable {
    var rangeLength: Int
    var milliseconds: Double
}

@MainActor
enum TextKitStrategyProbe {
    static func encodedReport() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(run())
        return String(decoding: data, as: UTF8.self)
    }

    static func run() -> TextKitStrategyProbeReport {
        let decision = EditorStrategyDecision()
        let loadMeasurements = [
            loadMeasurement(label: "100KB", targetBytes: 100 * 1024),
            loadMeasurement(label: "1MB", targetBytes: 1024 * 1024),
            loadMeasurement(label: "5MB", targetBytes: 5 * 1024 * 1024)
        ]
        let visibleDecoration = measureVisibleDecoration()
        let interactionProbe = measureInteractionCapabilities()

        return TextKitStrategyProbeReport(
            selectedStrategy: decision.textSystem.rawValue,
            thresholdBytes: decision.thresholds.maxDecoratedFileBytes,
            loadMeasurements: loadMeasurements,
            visibleDecoration: visibleDecoration,
            koreanMarkedTextSupported: interactionProbe.koreanMarkedTextSupported,
            headlessUndoRestoredInsertedText: interactionProbe.undoRestoredInsertedText,
            requiresH02UndoValidation: !interactionProbe.undoRestoredInsertedText,
            selectionStableAfterDecoration: interactionProbe.selectionStableAfterDecoration,
            firstResponderAccepted: interactionProbe.firstResponderAccepted,
            attachmentPlaceholderSupported: interactionProbe.attachmentPlaceholderSupported
        )
    }

    private static func loadMeasurement(label: String, targetBytes: Int) -> TextKitLoadMeasurement {
        let document = markdownDocument(targetBytes: targetBytes)
        let textView = makeTextView()
        let milliseconds = measureMilliseconds {
            textView.string = document
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        }

        return TextKitLoadMeasurement(
            label: label,
            bytes: document.utf8.count,
            milliseconds: milliseconds
        )
    }

    private static func measureVisibleDecoration() -> TextKitOperationMeasurement {
        let document = markdownDocument(targetBytes: 1024 * 1024)
        let textView = makeTextView()
        textView.string = document
        let length = min(16_384, (textView.string as NSString).length)
        let range = NSRange(location: 0, length: length)
        let milliseconds = measureMilliseconds {
            textView.textStorage?.beginEditing()
            textView.textStorage?.addAttributes([
                .foregroundColor: NSColor.systemBlue,
                .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            ], range: range)
            textView.textStorage?.endEditing()
        }

        return TextKitOperationMeasurement(rangeLength: length, milliseconds: milliseconds)
    }

    private static func measureInteractionCapabilities() -> (
        koreanMarkedTextSupported: Bool,
        undoRestoredInsertedText: Bool,
        selectionStableAfterDecoration: Bool,
        firstResponderAccepted: Bool,
        attachmentPlaceholderSupported: Bool
    ) {
        let textView = makeTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = scrollView
        let firstResponderAccepted = window.makeFirstResponder(textView)

        textView.string = ""
        textView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let koreanMarkedTextSupported = textView.hasMarkedText()
        textView.unmarkText()

        textView.string = "abc"
        let insertionRange = NSRange(location: 3, length: 0)
        textView.setSelectedRange(insertionRange)
        if textView.shouldChangeText(in: insertionRange, replacementString: "한글") {
            textView.replaceCharacters(in: insertionRange, with: "한글")
            textView.didChangeText()
        }
        let undoManager = textView.undoManager
        let canUndo = undoManager?.canUndo ?? false
        undoManager?.undo()
        let undoRestoredInsertedText = canUndo && textView.string == "abc"

        textView.string = "0123456789"
        let expectedSelection = NSRange(location: 4, length: 2)
        textView.setSelectedRange(expectedSelection)
        textView.textStorage?.addAttribute(
            .foregroundColor,
            value: NSColor.systemRed,
            range: NSRange(location: 0, length: 3)
        )
        let selectionStableAfterDecoration = NSEqualRanges(
            textView.selectedRange(),
            expectedSelection
        )

        let attributed = NSMutableAttributedString(string: "before ")
        attributed.append(NSAttributedString(attachment: NSTextAttachment()))
        attributed.append(NSAttributedString(string: " after"))
        textView.textStorage?.setAttributedString(attributed)
        let attachmentPlaceholderSupported = textView.textStorage?.attribute(
            .attachment,
            at: 7,
            effectiveRange: nil
        ) is NSTextAttachment

        return (
            koreanMarkedTextSupported,
            undoRestoredInsertedText,
            selectionStableAfterDecoration,
            firstResponderAccepted,
            attachmentPlaceholderSupported
        )
    }

    private static func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    private static func markdownDocument(targetBytes: Int) -> String {
        let line = "# Heading\n한글 English [[Link]] ![[image.png]] `code`\n\n"
        let repeatCount = targetBytes / line.utf8.count + 1
        return String(repeating: line, count: repeatCount)
    }

    private static func measureMilliseconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        let end = DispatchTime.now().uptimeNanoseconds
        return (Double(end - start) / 1_000_000).rounded(toPlaces: 3)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
