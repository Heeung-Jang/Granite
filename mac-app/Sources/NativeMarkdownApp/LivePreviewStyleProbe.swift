import AppKit
import Foundation
import NativeMarkdownCore

struct LivePreviewStyleProbeReport: Codable, Equatable {
    var headingFontScaleApplied: Bool
    var headingParagraphSpacingApplied: Bool
    var baseParagraphSpacingApplied: Bool
    var inlineCodeStyleApplied: Bool
    var inlineCodePreservesSource: Bool
    var fencedCodeStyleApplied: Bool
    var fencedCodeFenceConcealedOutsideReveal: Bool
    var fencedCodeFenceRevealedInsideBlock: Bool
    var fencedCodePreservesSource: Bool
    var listParagraphIndentApplied: Bool
    var listMarkerConcealedOutsideReveal: Bool
    var listMarkerStyledInsideReveal: Bool
    var taskCheckboxVisibleOutsideReveal: Bool
    var nestedListIndentStable: Bool
    var listRenderPreservesSource: Bool
    var blockquoteParagraphIndentApplied: Bool
    var blockquoteMarkerStyledAsBar: Bool
    var blockquoteRenderPreservesSource: Bool
    var calloutChromeApplied: Bool
    var calloutSyntaxConcealedOutsideReveal: Bool
    var calloutSyntaxRevealedInsideBlock: Bool
    var calloutRenderPreservesSource: Bool
    var propertiesChromeApplied: Bool
    var propertyYamlConcealedOutsideReveal: Bool
    var propertyYamlRevealedInsideBlock: Bool
    var propertiesRenderPreservesSource: Bool
    var imageEmbedPreviewStyled: Bool
    var blockedEmbedPreviewStyled: Bool
    var nonImageEmbedPreviewStyled: Bool
    var embedSizeSyntaxConcealedOutsideReveal: Bool
    var embedSyntaxRevealedInsideBlock: Bool
    var embedRenderPreservesSource: Bool
    var tableHeaderChromeApplied: Bool
    var tableBodyChromeApplied: Bool
    var tableSyntaxConcealedOutsideReveal: Bool
    var tableSyntaxRevealedInsideBlock: Bool
    var tableRenderPreservesSource: Bool
    var wikiLinkAliasVisible: Bool
    var wikiLinkSourceConcealedOutsideReveal: Bool
    var wikiLinkRenderPreservesSource: Bool
    var missingLinkStateStyled: Bool
    var duplicateLinkStateStyled: Bool
    var missingHeadingLinkStateStyled: Bool
    var markdownLinkLabelVisible: Bool
    var markdownLinkDestinationConcealed: Bool
    var markdownLinkRenderPreservesSource: Bool
    var nestedTagStyled: Bool
    var koreanTagStyled: Bool
    var tagMarkerConcealedOutsideReveal: Bool
    var tagRenderPreservesSource: Bool
    var headingRenderPreservesSource: Bool
}

@MainActor
enum LivePreviewStyleProbe {
    static func encodedReport() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(run())
        return String(decoding: data, as: UTF8.self)
    }

    static func run() -> LivePreviewStyleProbeReport {
        let source = """
        ---
        status: draft
        aliases:
          - live preview fixture
        secret_token: "fixture-secret-not-real"
        ---

        # Heading 1
        Paragraph one wraps with `code` and normal live-preview rhythm.

        Paragraph two keeps source text exact.

        ```swift
        let value = 1
        ```

        - Bullet item
          - Nested item
        1. Ordered item
        - [x] Done item

        > Quote line
        > [!note] Callout body

        [[Target#Heading|Alias]] and [[Missing Target]]
        [[Duplicate Target]] and [[Heading Target#Absent]]
        [Label](https://example.com/path)
        #project/native #상태/검토
        ![[image.png|100]]
        ![[wide.png|640x480]]
        ![[missing.png]]
        ![[Note]]
        ![Alt](nested/photo.jpg)
        | Name | Status |
        | --- | --- |
        | Alpha | Draft |

        ## Heading 2
        ### Heading 3
        #### Heading 4
        ##### Heading 5
        ###### Heading 6
        """
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = source
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        let linkStyleMap = linkStyleMap(for: source)
        let embedPreviewMap = embedPreviewMap(for: source)

        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            linkStyleMap: linkStyleMap,
            embedPreviewMap: embedPreviewMap
        )

        let fonts = (1...6).compactMap { font(in: textView, source: source, marker: "Heading \($0)") }
        let paragraphStyles = (1...6).compactMap {
            paragraphStyle(in: textView, source: source, marker: "Heading \($0)")
        }
        let baseParagraphStyle = paragraphStyle(in: textView, source: source, marker: "Paragraph one")
        let inlineCodeAttributes = attributes(in: textView, source: source, marker: "code")
        let fencedCodeAttributes = attributes(in: textView, source: source, marker: "let value")
        let hiddenFenceColor = foregroundColor(in: textView, source: source, marker: "```swift")
        let listParagraphStyle = paragraphStyle(in: textView, source: source, marker: "Bullet item")
        let nestedListParagraphStyle = paragraphStyle(in: textView, source: source, marker: "Nested item")
        let hiddenListMarkerColor = foregroundColor(in: textView, source: source, marker: "- Bullet")
        let visibleTaskCheckboxColor = foregroundColor(in: textView, source: source, marker: "[x]")
        let blockquoteParagraphStyle = paragraphStyle(in: textView, source: source, marker: "Quote line")
        let blockquoteMarkerColor = foregroundColor(in: textView, source: source, marker: "> Quote")
        let calloutAttributes = attributes(in: textView, source: source, marker: "Callout body")
        let hiddenCalloutSyntaxColor = foregroundColor(in: textView, source: source, marker: "> [!note]")
        let propertyKeyAttributes = attributes(in: textView, source: source, marker: "status")
        let propertyValueAttributes = attributes(in: textView, source: source, marker: "draft")
        let hiddenPropertyDelimiterColor = foregroundColor(in: textView, source: source, marker: "---")
        let hiddenPropertyColonColor = foregroundColor(in: textView, source: source, marker: ": draft")
        let wikiAliasColor = foregroundColor(in: textView, source: source, marker: "Alias")
        let hiddenWikiSourceColor = foregroundColor(in: textView, source: source, marker: "[[Target#Heading|")
        let missingLinkColor = foregroundColor(in: textView, source: source, marker: "Missing Target")
        let duplicateLinkColor = foregroundColor(in: textView, source: source, marker: "Duplicate Target")
        let missingHeadingLinkColor = foregroundColor(in: textView, source: source, marker: "Heading Target")
        let markdownLinkLabelColor = foregroundColor(in: textView, source: source, marker: "Label")
        let markdownLinkDestinationColor = foregroundColor(in: textView, source: source, marker: "https://example.com/path")
        let nestedTagAttributes = attributes(in: textView, source: source, marker: "project/native")
        let koreanTagAttributes = attributes(in: textView, source: source, marker: "상태/검토")
        let hiddenTagMarkerColor = foregroundColor(in: textView, source: source, marker: "#project")
        let imageEmbedColor = foregroundColor(in: textView, source: source, marker: "image.png")
        let missingEmbedColor = foregroundColor(in: textView, source: source, marker: "missing.png")
        let nonImageEmbedColor = foregroundColor(in: textView, source: source, marker: "Note")
        let hiddenEmbedSizeColor = foregroundColor(in: textView, source: source, marker: "|100")
        let hiddenEmbedOpeningColor = foregroundColor(in: textView, source: source, marker: "![[image.png")
        let tableHeaderAttributes = attributes(in: textView, source: source, marker: "Name")
        let tableBodyAttributes = attributes(in: textView, source: source, marker: "Alpha")
        let hiddenTablePipeColor = foregroundColor(in: textView, source: source, marker: "| Name")
        let hiddenTableAlignmentColor = foregroundColor(in: textView, source: source, marker: "--- | ---")

        if let codeOffset = utf16Offset(of: "let value", in: source) {
            textView.setSelectedRange(NSRange(location: codeOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                linkStyleMap: linkStyleMap,
                embedPreviewMap: embedPreviewMap
            )
        }
        let revealedFenceColor = foregroundColor(in: textView, source: source, marker: "```swift")

        if let listOffset = utf16Offset(of: "Bullet item", in: source) {
            textView.setSelectedRange(NSRange(location: listOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                linkStyleMap: linkStyleMap,
                embedPreviewMap: embedPreviewMap
            )
        }
        let revealedListMarkerColor = foregroundColor(in: textView, source: source, marker: "- Bullet")

        if let calloutOffset = utf16Offset(of: "Callout body", in: source) {
            textView.setSelectedRange(NSRange(location: calloutOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                linkStyleMap: linkStyleMap,
                embedPreviewMap: embedPreviewMap
            )
        }
        let revealedCalloutSyntaxColor = foregroundColor(in: textView, source: source, marker: "> [!note]")

        if let propertyOffset = utf16Offset(of: "status", in: source) {
            textView.setSelectedRange(NSRange(location: propertyOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                linkStyleMap: linkStyleMap,
                embedPreviewMap: embedPreviewMap
            )
        }
        let revealedPropertyDelimiterColor = foregroundColor(in: textView, source: source, marker: "---")
        let revealedPropertyColonColor = foregroundColor(in: textView, source: source, marker: ": draft")

        if let embedOffset = utf16Offset(of: "image.png", in: source) {
            textView.setSelectedRange(NSRange(location: embedOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                linkStyleMap: linkStyleMap,
                embedPreviewMap: embedPreviewMap
            )
        }
        let revealedEmbedSizeColor = foregroundColor(in: textView, source: source, marker: "|100")
        let revealedEmbedOpeningColor = foregroundColor(in: textView, source: source, marker: "![[image.png")

        if let tableOffset = utf16Offset(of: "Alpha", in: source) {
            textView.setSelectedRange(NSRange(location: tableOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                linkStyleMap: linkStyleMap,
                embedPreviewMap: embedPreviewMap
            )
        }
        let revealedTablePipeColor = foregroundColor(in: textView, source: source, marker: "| Name")
        let revealedTableAlignmentColor = foregroundColor(in: textView, source: source, marker: "--- | ---")

        return LivePreviewStyleProbeReport(
            headingFontScaleApplied: fonts.map(\.pointSize) == [
                LivePreviewTheme.h1Font.pointSize,
                LivePreviewTheme.h2Font.pointSize,
                LivePreviewTheme.h3Font.pointSize,
                LivePreviewTheme.h4Font.pointSize,
                LivePreviewTheme.h5Font.pointSize,
                LivePreviewTheme.h6Font.pointSize
            ],
            headingParagraphSpacingApplied: paragraphStyles.count == 6
                && paragraphStyles.allSatisfy { $0.paragraphSpacing > 0 && $0.paragraphSpacingBefore > 0 },
            baseParagraphSpacingApplied: baseParagraphStyle?.lineHeightMultiple ?? 0 > 1
                && baseParagraphStyle?.paragraphSpacing ?? 0 > 0,
            inlineCodeStyleApplied: inlineCodeAttributes?[.font] as? NSFont == LivePreviewTheme.codeFont
                && inlineCodeAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.codeColor
                && inlineCodeAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.inlineCodeBackgroundColor,
            inlineCodePreservesSource: textView.string.contains("`code`"),
            fencedCodeStyleApplied: fencedCodeAttributes?[.font] as? NSFont == LivePreviewTheme.codeFont
                && fencedCodeAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.codeColor
                && fencedCodeAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.codeBlockBackgroundColor
                && (fencedCodeAttributes?[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacing ?? 0 > 0,
            fencedCodeFenceConcealedOutsideReveal: hiddenFenceColor == LivePreviewTheme.concealedColor,
            fencedCodeFenceRevealedInsideBlock: revealedFenceColor != LivePreviewTheme.concealedColor,
            fencedCodePreservesSource: textView.string.contains("```swift\nlet value = 1\n```"),
            listParagraphIndentApplied: listParagraphStyle?.headIndent ?? 0 > 0,
            listMarkerConcealedOutsideReveal: hiddenListMarkerColor == LivePreviewTheme.concealedColor,
            listMarkerStyledInsideReveal: revealedListMarkerColor == LivePreviewTheme.listMarkerColor,
            taskCheckboxVisibleOutsideReveal: visibleTaskCheckboxColor != LivePreviewTheme.concealedColor,
            nestedListIndentStable: nestedListParagraphStyle?.headIndent == listParagraphStyle?.headIndent,
            listRenderPreservesSource: textView.string.contains("- [x] Done item"),
            blockquoteParagraphIndentApplied: blockquoteParagraphStyle?.headIndent ?? 0 > 0,
            blockquoteMarkerStyledAsBar: blockquoteMarkerColor == LivePreviewTheme.quoteBarColor,
            blockquoteRenderPreservesSource: textView.string.contains("> Quote line"),
            calloutChromeApplied: calloutAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.calloutBackgroundColor
                && (calloutAttributes?[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0 > 0,
            calloutSyntaxConcealedOutsideReveal: hiddenCalloutSyntaxColor == LivePreviewTheme.concealedColor,
            calloutSyntaxRevealedInsideBlock: revealedCalloutSyntaxColor != LivePreviewTheme.concealedColor,
            calloutRenderPreservesSource: textView.string.contains("> [!note] Callout body"),
            propertiesChromeApplied: propertyKeyAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.propertyKeyColor
                && propertyKeyAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.propertyBackgroundColor
                && propertyValueAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.propertyValueColor
                && propertyValueAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.propertyBackgroundColor,
            propertyYamlConcealedOutsideReveal: hiddenPropertyDelimiterColor == LivePreviewTheme.concealedColor
                && hiddenPropertyColonColor == LivePreviewTheme.concealedColor,
            propertyYamlRevealedInsideBlock: revealedPropertyDelimiterColor != LivePreviewTheme.concealedColor
                && revealedPropertyColonColor != LivePreviewTheme.concealedColor,
            propertiesRenderPreservesSource: textView.string.contains("secret_token: \"fixture-secret-not-real\""),
            imageEmbedPreviewStyled: imageEmbedColor == LivePreviewTheme.embedImageColor,
            blockedEmbedPreviewStyled: missingEmbedColor == LivePreviewTheme.embedBlockedColor,
            nonImageEmbedPreviewStyled: nonImageEmbedColor == LivePreviewTheme.embedFallbackColor,
            embedSizeSyntaxConcealedOutsideReveal: hiddenEmbedSizeColor == LivePreviewTheme.concealedColor
                && hiddenEmbedOpeningColor == LivePreviewTheme.concealedColor,
            embedSyntaxRevealedInsideBlock: revealedEmbedSizeColor != LivePreviewTheme.concealedColor
                && revealedEmbedOpeningColor != LivePreviewTheme.concealedColor,
            embedRenderPreservesSource: textView.string.contains("![[image.png|100]]")
                && textView.string.contains("![[wide.png|640x480]]")
                && textView.string.contains("![[missing.png]]")
                && textView.string.contains("![[Note]]")
                && textView.string.contains("![Alt](nested/photo.jpg)"),
            tableHeaderChromeApplied: tableHeaderAttributes?[.font] as? NSFont == LivePreviewTheme.strongFont
                && tableHeaderAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.tableHeaderBackgroundColor,
            tableBodyChromeApplied: tableBodyAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.tableCellBackgroundColor,
            tableSyntaxConcealedOutsideReveal: hiddenTablePipeColor == LivePreviewTheme.concealedColor
                && hiddenTableAlignmentColor == LivePreviewTheme.concealedColor,
            tableSyntaxRevealedInsideBlock: revealedTablePipeColor != LivePreviewTheme.concealedColor
                && revealedTableAlignmentColor != LivePreviewTheme.concealedColor,
            tableRenderPreservesSource: textView.string.contains("| Name | Status |")
                && textView.string.contains("| --- | --- |")
                && textView.string.contains("| Alpha | Draft |"),
            wikiLinkAliasVisible: wikiAliasColor == LivePreviewTheme.linkColor,
            wikiLinkSourceConcealedOutsideReveal: hiddenWikiSourceColor == LivePreviewTheme.concealedColor,
            wikiLinkRenderPreservesSource: textView.string.contains("[[Target#Heading|Alias]]"),
            missingLinkStateStyled: missingLinkColor == LivePreviewTheme.missingLinkColor
                && underlineStyle(in: textView, source: source, marker: "Missing Target") == NSUnderlineStyle.single.rawValue,
            duplicateLinkStateStyled: duplicateLinkColor == LivePreviewTheme.duplicateLinkColor
                && underlineStyle(in: textView, source: source, marker: "Duplicate Target") == NSUnderlineStyle.single.rawValue,
            missingHeadingLinkStateStyled: missingHeadingLinkColor == LivePreviewTheme.missingHeadingLinkColor
                && underlineStyle(in: textView, source: source, marker: "Heading Target") == NSUnderlineStyle.single.rawValue,
            markdownLinkLabelVisible: markdownLinkLabelColor == LivePreviewTheme.linkColor,
            markdownLinkDestinationConcealed: markdownLinkDestinationColor == LivePreviewTheme.concealedColor,
            markdownLinkRenderPreservesSource: textView.string.contains("[Label](https://example.com/path)"),
            nestedTagStyled: nestedTagAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.tagColor
                && nestedTagAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.tagBackgroundColor,
            koreanTagStyled: koreanTagAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.tagColor
                && koreanTagAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.tagBackgroundColor,
            tagMarkerConcealedOutsideReveal: hiddenTagMarkerColor == LivePreviewTheme.concealedColor,
            tagRenderPreservesSource: textView.string.contains("#project/native #상태/검토"),
            headingRenderPreservesSource: textView.string == source
        )
    }

    private static func linkStyleMap(for source: String) -> LivePreviewLinkStyleMap {
        var states: [LivePreviewSourceRange: LivePreviewLinkStyleState] = [:]
        record("[[Target#Heading|Alias]]", state: .resolved, in: source, states: &states)
        record("[[Missing Target]]", state: .missing, in: source, states: &states)
        record("[[Duplicate Target]]", state: .duplicate, in: source, states: &states)
        record("[[Heading Target#Absent]]", state: .missingHeading, in: source, states: &states)
        return LivePreviewLinkStyleMap(statesByRange: states)
    }

    private static func embedPreviewMap(for source: String) -> LivePreviewEmbedPreviewMap {
        let references = [
            AttachmentReferenceItem(
                id: "0-wikiEmbed-image.png",
                source: .wikiEmbed,
                rawTarget: "image.png",
                state: .resolved(FileTreeItem(relativePath: "image.png"))
            ),
            AttachmentReferenceItem(
                id: "1-wikiEmbed-wide.png",
                source: .wikiEmbed,
                rawTarget: "wide.png",
                state: .resolved(FileTreeItem(relativePath: "wide.png"))
            ),
            AttachmentReferenceItem(
                id: "2-wikiEmbed-missing.png",
                source: .wikiEmbed,
                rawTarget: "missing.png",
                state: .missing
            ),
            AttachmentReferenceItem(
                id: "3-wikiEmbed-Note",
                source: .wikiEmbed,
                rawTarget: "Note",
                state: .unsupported
            ),
            AttachmentReferenceItem(
                id: "4-markdownImage-nested/photo.jpg",
                source: .markdownImage,
                rawTarget: "nested/photo.jpg",
                state: .resolved(FileTreeItem(relativePath: "nested/photo.jpg"))
            )
        ]
        let states: [String: AttachmentPreviewState] = [
            references[0].id: .eligible(AttachmentPreviewInfo(
                file: FileTreeItem(relativePath: "image.png"),
                url: URL(fileURLWithPath: "/tmp/vault/image.png"),
                byteSize: 128,
                pixelWidth: 320,
                pixelHeight: 240
            )),
            references[1].id: .eligible(AttachmentPreviewInfo(
                file: FileTreeItem(relativePath: "wide.png"),
                url: URL(fileURLWithPath: "/tmp/vault/wide.png"),
                byteSize: 128,
                pixelWidth: 640,
                pixelHeight: 480
            )),
            references[2].id: .blocked(.missing),
            references[3].id: .blocked(.unsupportedResolution),
            references[4].id: .eligible(AttachmentPreviewInfo(
                file: FileTreeItem(relativePath: "nested/photo.jpg"),
                url: URL(fileURLWithPath: "/tmp/vault/nested/photo.jpg"),
                byteSize: 128,
                pixelWidth: 100,
                pixelHeight: 80
            ))
        ]
        return LivePreviewEmbedPreviewMap(
            source: source,
            references: references,
            previewStatesByID: states
        )
    }

    private static func record(
        _ marker: String,
        state: LivePreviewLinkStyleState,
        in source: String,
        states: inout [LivePreviewSourceRange: LivePreviewLinkStyleState]
    ) {
        guard let range = source.range(of: marker) else {
            return
        }
        let nsRange = NSRange(range, in: source)
        states[LivePreviewSourceRange(location: nsRange.location, length: nsRange.length)] = state
    }

    private static func font(in textView: NSTextView, source: String, marker: String) -> NSFont? {
        guard let offset = utf16Offset(of: marker, in: source) else {
            return nil
        }
        return textView.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
    }

    private static func paragraphStyle(
        in textView: NSTextView,
        source: String,
        marker: String
    ) -> NSParagraphStyle? {
        guard let offset = utf16Offset(of: marker, in: source) else {
            return nil
        }
        return textView.textStorage?.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
    }

    private static func attributes(
        in textView: NSTextView,
        source: String,
        marker: String
    ) -> [NSAttributedString.Key: Any]? {
        guard let offset = utf16Offset(of: marker, in: source) else {
            return nil
        }
        return textView.textStorage?.attributes(at: offset, effectiveRange: nil)
    }

    private static func foregroundColor(in textView: NSTextView, source: String, marker: String) -> NSColor? {
        guard let offset = utf16Offset(of: marker, in: source) else {
            return nil
        }
        return textView.textStorage?.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }

    private static func underlineStyle(in textView: NSTextView, source: String, marker: String) -> Int? {
        guard let offset = utf16Offset(of: marker, in: source) else {
            return nil
        }
        return textView.textStorage?.attribute(.underlineStyle, at: offset, effectiveRange: nil) as? Int
    }

    private static func utf16Offset(of marker: String, in source: String) -> Int? {
        guard let range = source.range(of: marker) else {
            return nil
        }
        return NSRange(range, in: source).location
    }
}
