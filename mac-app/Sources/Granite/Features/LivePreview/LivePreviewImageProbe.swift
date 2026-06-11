import AppKit
import Foundation
import NativeMarkdownCore

struct LivePreviewImageProbeReport: Codable, Equatable {
    var summary: ProbeCheckSummary
    var localImageSnapshotCreated: Bool
    var localImageParagraphHeightReserved: Bool
    var localImagePreservesSource: Bool
    var remoteDisabledCreatesNoSnapshot: Bool
    var sourceModePreservesSource: Bool
}

@MainActor
enum LivePreviewImageProbe {
    static func run() async -> LivePreviewImageProbeReport {
        let local = await localImageProbe()
        let remoteDisabled = remoteDisabledProbe()
        let sourceMode = sourceModeProbe()
        let checks = [
            ("localImageSnapshotCreated", local.snapshotCreated),
            ("localImageParagraphHeightReserved", local.paragraphHeightReserved),
            ("localImagePreservesSource", local.preservesSource),
            ("remoteDisabledCreatesNoSnapshot", remoteDisabled),
            ("sourceModePreservesSource", sourceMode)
        ]
        let failures = checks.filter { !$0.1 }.map(\.0).sorted()
        return LivePreviewImageProbeReport(
            summary: ProbeCheckSummary(
                passed: failures.isEmpty,
                unexpectedFailures: failures,
                expectedFailures: []
            ),
            localImageSnapshotCreated: local.snapshotCreated,
            localImageParagraphHeightReserved: local.paragraphHeightReserved,
            localImagePreservesSource: local.preservesSource,
            remoteDisabledCreatesNoSnapshot: remoteDisabled,
            sourceModePreservesSource: sourceMode
        )
    }

    static func encodedReport(_ report: LivePreviewImageProbeReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private static func localImageProbe() async -> (
        snapshotCreated: Bool,
        paragraphHeightReserved: Bool,
        preservesSource: Bool
    ) {
        let source = "![[image.png|120]]\n"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("granite-live-preview-image-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
            try writePNG(to: tempURL.appendingPathComponent("image.png"))
        } catch {
            return (false, false, false)
        }
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let references = [
            AttachmentReferenceItem(
                id: "0-wikiEmbed-image.png",
                source: .wikiEmbed,
                rawTarget: "image.png",
                state: .resolved(FileTreeItem(relativePath: "image.png"))
            )
        ]
        let previewStates = livePreviewProbeStates(vaultURL: tempURL, references: references)
        let map = LivePreviewEmbedPreviewMap(
            source: source,
            references: references,
            previewStatesByID: previewStates
        )
        let textView = configuredTextView(source: source)
        let controller = LivePreviewImageController()
        var loaded = false
        controller.update(
            textView: textView,
            embedPreviewMap: map,
            vaultURL: tempURL,
            remotePolicy: .defaultValue,
            livePreviewMode: .livePreview,
            scale: AppContentZoom.defaultScale
        ) {
            loaded = true
        }

        for _ in 0..<40 where !loaded {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        controller.update(
            textView: textView,
            embedPreviewMap: map,
            vaultURL: tempURL,
            remotePolicy: .defaultValue,
            livePreviewMode: .livePreview,
            scale: AppContentZoom.defaultScale
        ) {}
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            range: NSRange(location: 0, length: (source as NSString).length),
            livePreviewMode: .livePreview,
            revealRange: NSRange(location: source.utf16.count + 32, length: 0),
            embedPreviewMap: map,
            imageSnapshot: textView.livePreviewImageSnapshot
        )

        let paragraphStyle = textView.textStorage?.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle

        return (
            snapshotCreated: textView.livePreviewImageSnapshot.count == 1,
            paragraphHeightReserved: (paragraphStyle?.minimumLineHeight ?? 0) >= 70,
            preservesSource: textView.string == source
        )
    }

    private static func remoteDisabledProbe() -> Bool {
        let source = "![remote](https://example.com/image.png)\n"
        let references = [
            AttachmentReferenceItem(
                id: "0-markdownImage-remote",
                source: .markdownImage,
                rawTarget: "https://example.com/image.png",
                state: .remote
            )
        ]
        let map = LivePreviewEmbedPreviewMap(
            source: source,
            references: references,
            previewStatesByID: [references[0].id: .blocked(.remote)]
        )
        let textView = configuredTextView(source: source)
        let controller = LivePreviewImageController()
        controller.update(
            textView: textView,
            embedPreviewMap: map,
            vaultURL: nil,
            remotePolicy: LivePreviewRemoteImagePolicy(isEnabled: false),
            livePreviewMode: .livePreview,
            scale: AppContentZoom.defaultScale
        ) {}
        return textView.livePreviewImageSnapshot.count == 0
    }

    private static func sourceModeProbe() -> Bool {
        let source = "![[image.png|120]]\n"
        let textView = configuredTextView(source: source)
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .source,
            imageSnapshot: .empty
        )
        return textView.string == source
    }

    private static func configuredTextView(source: String) -> MarkdownInteractionTextView {
        let textView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        textView.textContainer?.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        textView.string = source
        textView.livePreviewMode = .livePreview
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    private static func livePreviewProbeStates(
        vaultURL: URL,
        references: [AttachmentReferenceItem]
    ) -> [String: AttachmentPreviewState] {
        let gate = FileSystemAttachmentPreviewGate()
        return Dictionary(uniqueKeysWithValues: references.map { reference in
            (reference.id, gate.previewState(vaultURL: vaultURL, reference: reference))
        })
    }

    private static func writePNG(to url: URL) throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 160,
            pixelsHigh: 90,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 90).fill()
        NSColor.white.setFill()
        NSRect(x: 16, y: 16, width: 128, height: 58).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
