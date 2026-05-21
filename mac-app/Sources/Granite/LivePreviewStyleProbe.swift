import AppKit
import Foundation
import NativeMarkdownCore

struct LivePreviewStyleProbeReport: Codable, Equatable {
    var summary: ProbeCheckSummary
    var headingFontScaleApplied: Bool
    var headingParagraphSpacingApplied: Bool
    var headingMarkerGeometry: HeadingMarkerGeometryProbeReport
    var headingMarkerGeometryMeasured: Bool
    var headingMarkerTextXPositionMeasured: Bool
    var collapsedHeadingMarkerWidthReduced: Bool
    var collapsedHeadingMarkerLineHeightPreserved: Bool
    var collapsedHeadingMarkerSelectionSafe: Bool
    var collapsedHeadingMarkerMarkedTextSafe: Bool
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
    var obsidianUnorderedMarkerConcealedOutsideReveal: Bool
    var obsidianUnorderedMarkerRevealedInsideLine: Bool
    var obsidianOrderedMarkerConcealedOutsideReveal: Bool
    var obsidianOrderedMarkerRevealedInsideLine: Bool
    var obsidianTaskSourceTokenConcealedOutsideReveal: Bool
    var obsidianTaskSourceTokenRevealedInsideLine: Bool
    var obsidianTaskCheckboxVisualVisibleOutsideReveal: Bool
    var markerGeometry: MarkerGeometryProbeReport
    var unorderedMarkerGeometryReported: Bool
    var orderedMarkerGeometryReported: Bool
    var taskMarkerGeometryReported: Bool
    var unorderedDashMarkerDetected: Bool
    var unorderedAsteriskMarkerDetected: Bool
    var unorderedPlusMarkerDetected: Bool
    var unorderedNestedMarkerDetected: Bool
    var unorderedTabbedMarkerDetected: Bool
    var nestedListIndentStable: Bool
    var listRenderPreservesSource: Bool
    var blockquoteParagraphIndentApplied: Bool
    var blockquoteMarkerStyledAsBar: Bool
    var blockquoteRenderPreservesSource: Bool
    var calloutChromeApplied: Bool
    var calloutSyntaxConcealedOutsideReveal: Bool
    var calloutSyntaxStaysConcealedInsideBlock: Bool
    var calloutVariantAccentColorsResolved: Bool
    var calloutBackgroundUsesAccentAlpha: Bool
    var calloutRenderPreservesSource: Bool
    var propertiesChromeApplied: Bool
    var propertiesTitleSpacingApplied: Bool
    var propertiesSectionSpacingApplied: Bool
    var propertiesRowSpacingApplied: Bool
    var propertiesHeaderGeometrySeparated: Bool
    var propertyYamlConcealedOutsideReveal: Bool
    var propertiesSourceStaysConcealedInsideBlock: Bool
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
    var tableSourceStaysConcealedInsideBlock: Bool
    var tableRenderPreservesSource: Bool
    var horizontalRuleDashVariantRendered: Bool
    var horizontalRuleAsteriskVariantRendered: Bool
    var horizontalRuleUnderscoreVariantRendered: Bool
    var horizontalRuleFalsePositivesRejected: Bool
    var tableRenderedStateVisible: Bool
    var tableActiveCellEditStateVisible: Bool
    var tableRowAddControlVisibleWhenFocused: Bool
    var tableColumnAddControlVisibleWhenFocused: Bool
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

struct HeadingMarkerGeometryProbeReport: Codable, Equatable {
    var originalMarkerWidth: Double
    var originalTextX: Double
    var collapsedMarkerWidth: Double
    var collapsedTextX: Double

    static let empty = HeadingMarkerGeometryProbeReport(
        originalMarkerWidth: 0,
        originalTextX: 0,
        collapsedMarkerWidth: 0,
        collapsedTextX: 0
    )
}

struct MarkerGeometryProbeReport: Codable, Equatable {
    var unorderedMarkerWidth: Double
    var unorderedMarkerX: Double
    var orderedMarkerWidth: Double
    var orderedMarkerX: Double
    var taskCheckboxWidth: Double
    var taskCheckboxX: Double
}

@MainActor
enum LivePreviewStyleProbe {
    private static let expectedFailures: Set<String> = [
        "obsidianUnorderedMarkerConcealedOutsideReveal",
        "obsidianOrderedMarkerConcealedOutsideReveal",
        "obsidianTaskSourceTokenConcealedOutsideReveal",
        "tableActiveCellEditStateVisible",
        "tableRowAddControlVisibleWhenFocused",
        "tableColumnAddControlVisibleWhenFocused"
    ]

    static func encodedReport(_ report: LivePreviewStyleProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(report)
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
            embedPreviewMap: embedPreviewMap,
            markerStyle: .hidden
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
        let propertyTitleParagraphStyle = paragraphStyle(in: textView, source: source, marker: "---")
        let propertySectionParagraphStyle = paragraphStyle(in: textView, source: source, marker: "status")
        let propertyRowParagraphStyle = paragraphStyle(in: textView, source: source, marker: "aliases")
        let propertyTitleLineRect = lineRect(in: textView, source: source, marker: "---")
        let propertySectionLineRect = lineRect(in: textView, source: source, marker: "status")
        let propertyRowLineRect = lineRect(in: textView, source: source, marker: "aliases")
        let propertyBodyLineRect = lineRect(in: textView, source: source, marker: "Heading 1")
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
                embedPreviewMap: embedPreviewMap,
                markerStyle: .hidden
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
                embedPreviewMap: embedPreviewMap,
                markerStyle: .hidden
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
                embedPreviewMap: embedPreviewMap,
                markerStyle: .hidden
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
                embedPreviewMap: embedPreviewMap,
                markerStyle: .hidden
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
                embedPreviewMap: embedPreviewMap,
                markerStyle: .hidden
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
                embedPreviewMap: embedPreviewMap,
                markerStyle: .hidden
            )
        }
        let revealedTablePipeColor = foregroundColor(in: textView, source: source, marker: "| Name")
        let revealedTableAlignmentColor = foregroundColor(in: textView, source: source, marker: "--- | ---")
        let obsidianMarkerFields = probeObsidianMarkerFields()
        let horizontalRuleFields = probeHorizontalRuleFields()
        let headingMarkerFields = probeHeadingMarkerGeometry()
        let markerGeometryFields = probeMarkerGeometry()
        let unorderedMarkerFields = probeUnorderedMarkerDetection()

        var report = LivePreviewStyleProbeReport(
            summary: .passed,
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
            headingMarkerGeometry: headingMarkerFields.geometry,
            headingMarkerGeometryMeasured: headingMarkerFields.geometryMeasured,
            headingMarkerTextXPositionMeasured: headingMarkerFields.textXPositionMeasured,
            collapsedHeadingMarkerWidthReduced: headingMarkerFields.collapsedWidthReduced,
            collapsedHeadingMarkerLineHeightPreserved: headingMarkerFields.collapsedLineHeightPreserved,
            collapsedHeadingMarkerSelectionSafe: headingMarkerFields.collapsedSelectionSafe,
            collapsedHeadingMarkerMarkedTextSafe: headingMarkerFields.collapsedMarkedTextSafe,
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
            obsidianUnorderedMarkerConcealedOutsideReveal: obsidianMarkerFields.unorderedConcealedOutsideReveal,
            obsidianUnorderedMarkerRevealedInsideLine: obsidianMarkerFields.unorderedRevealedInsideLine,
            obsidianOrderedMarkerConcealedOutsideReveal: obsidianMarkerFields.orderedConcealedOutsideReveal,
            obsidianOrderedMarkerRevealedInsideLine: obsidianMarkerFields.orderedRevealedInsideLine,
            obsidianTaskSourceTokenConcealedOutsideReveal: obsidianMarkerFields.taskSourceTokenConcealedOutsideReveal,
            obsidianTaskSourceTokenRevealedInsideLine: obsidianMarkerFields.taskSourceTokenRevealedInsideLine,
            obsidianTaskCheckboxVisualVisibleOutsideReveal: obsidianMarkerFields.taskCheckboxVisualVisibleOutsideReveal,
            markerGeometry: markerGeometryFields.geometry,
            unorderedMarkerGeometryReported: markerGeometryFields.unorderedReported,
            orderedMarkerGeometryReported: markerGeometryFields.orderedReported,
            taskMarkerGeometryReported: markerGeometryFields.taskReported,
            unorderedDashMarkerDetected: unorderedMarkerFields.dashDetected,
            unorderedAsteriskMarkerDetected: unorderedMarkerFields.asteriskDetected,
            unorderedPlusMarkerDetected: unorderedMarkerFields.plusDetected,
            unorderedNestedMarkerDetected: unorderedMarkerFields.nestedDetected,
            unorderedTabbedMarkerDetected: unorderedMarkerFields.tabbedDetected,
            nestedListIndentStable: nestedListParagraphStyle?.headIndent == listParagraphStyle?.headIndent,
            listRenderPreservesSource: textView.string.contains("- [x] Done item"),
            blockquoteParagraphIndentApplied: blockquoteParagraphStyle?.headIndent ?? 0 > 0,
            blockquoteMarkerStyledAsBar: blockquoteMarkerColor == LivePreviewTheme.quoteBarColor,
            blockquoteRenderPreservesSource: textView.string.contains("> Quote line"),
            calloutChromeApplied: calloutAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.textColor
                && (calloutAttributes?[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0 > 0,
            calloutSyntaxConcealedOutsideReveal: hiddenCalloutSyntaxColor == LivePreviewTheme.concealedColor,
            calloutSyntaxStaysConcealedInsideBlock: revealedCalloutSyntaxColor == LivePreviewTheme.concealedColor,
            calloutVariantAccentColorsResolved: LivePreviewTheme.calloutAccentColor(for: .callout(kind: "warning")) == NSColor.systemOrange
                && LivePreviewTheme.calloutAccentColor(for: .callout(kind: "success")) == NSColor.systemGreen
                && LivePreviewTheme.calloutAccentColor(for: .callout(kind: "danger")) == NSColor.systemRed
                && LivePreviewTheme.calloutAccentColor(for: .callout(kind: "quote")) == NSColor.systemGray,
            calloutBackgroundUsesAccentAlpha: LivePreviewTheme.calloutBackgroundColor(for: .callout(kind: "warning")) == NSColor.systemOrange.withAlphaComponent(0.12),
            calloutRenderPreservesSource: textView.string.contains("> [!note] Callout body"),
            propertiesChromeApplied: propertyKeyAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.concealedColor
                && propertyValueAttributes?[.foregroundColor] as? NSColor == LivePreviewTheme.concealedColor
                && propertyKeyAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.propertyBackgroundColor,
            propertiesTitleSpacingApplied: propertyTitleParagraphStyle?.minimumLineHeight == LivePreviewTheme.propertyTitleLineHeight
                && propertyTitleParagraphStyle?.maximumLineHeight == LivePreviewTheme.propertyTitleLineHeight
                && propertyTitleParagraphStyle?.paragraphSpacing == LivePreviewTheme.propertyTitleParagraphSpacing,
            propertiesSectionSpacingApplied: propertySectionParagraphStyle?.minimumLineHeight == LivePreviewTheme.propertySectionLineHeight
                && propertySectionParagraphStyle?.maximumLineHeight == LivePreviewTheme.propertySectionLineHeight
                && propertySectionParagraphStyle?.paragraphSpacing == LivePreviewTheme.propertySectionParagraphSpacing,
            propertiesRowSpacingApplied: propertyRowParagraphStyle?.minimumLineHeight == LivePreviewTheme.propertyRowLineHeight
                && propertyRowParagraphStyle?.maximumLineHeight == LivePreviewTheme.propertyRowLineHeight
                && propertyRowParagraphStyle?.paragraphSpacing == LivePreviewTheme.propertyRowParagraphSpacing,
            propertiesHeaderGeometrySeparated: propertyHeaderGeometrySeparated(
                title: propertyTitleLineRect,
                section: propertySectionLineRect,
                row: propertyRowLineRect,
                body: propertyBodyLineRect
            ),
            propertyYamlConcealedOutsideReveal: hiddenPropertyDelimiterColor == LivePreviewTheme.concealedColor
                && hiddenPropertyColonColor == LivePreviewTheme.concealedColor,
            propertiesSourceStaysConcealedInsideBlock: revealedPropertyDelimiterColor == LivePreviewTheme.concealedColor
                && revealedPropertyColonColor == LivePreviewTheme.concealedColor,
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
            tableSourceStaysConcealedInsideBlock: revealedTablePipeColor == LivePreviewTheme.concealedColor
                && revealedTableAlignmentColor == LivePreviewTheme.concealedColor,
            tableRenderPreservesSource: textView.string.contains("| Name | Status |")
                && textView.string.contains("| --- | --- |")
                && textView.string.contains("| Alpha | Draft |"),
            horizontalRuleDashVariantRendered: horizontalRuleFields.dashVariantRendered,
            horizontalRuleAsteriskVariantRendered: horizontalRuleFields.asteriskVariantRendered,
            horizontalRuleUnderscoreVariantRendered: horizontalRuleFields.underscoreVariantRendered,
            horizontalRuleFalsePositivesRejected: horizontalRuleFields.falsePositivesRejected,
            tableRenderedStateVisible: tableHeaderAttributes?[.font] as? NSFont == LivePreviewTheme.strongFont
                && tableBodyAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.tableCellBackgroundColor
                && hiddenTablePipeColor == LivePreviewTheme.concealedColor
                && hiddenTableAlignmentColor == LivePreviewTheme.concealedColor,
            tableActiveCellEditStateVisible: false,
            tableRowAddControlVisibleWhenFocused: false,
            tableColumnAddControlVisibleWhenFocused: false,
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
        report.summary = ProbeCheckSummary.evaluate(report: report, expectedFailures: expectedFailures)
        return report
    }

    private static func probeObsidianMarkerFields() -> (
        unorderedConcealedOutsideReveal: Bool,
        unorderedRevealedInsideLine: Bool,
        orderedConcealedOutsideReveal: Bool,
        orderedRevealedInsideLine: Bool,
        taskSourceTokenConcealedOutsideReveal: Bool,
        taskSourceTokenRevealedInsideLine: Bool,
        taskCheckboxVisualVisibleOutsideReveal: Bool
    ) {
        let source = """
        - Unordered
        1. Ordered
        - [x] Done
        """
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = source
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )
        let hiddenUnorderedMarkerColor = foregroundColor(in: textView, source: source, marker: "- Unordered")
        let hiddenOrderedMarkerColor = foregroundColor(in: textView, source: source, marker: "1. Ordered")
        let hiddenTaskMarkerColor = foregroundColor(in: textView, source: source, marker: "- [x]")
        let hiddenTaskCheckboxColor = foregroundColor(in: textView, source: source, marker: "[x]")

        if let unorderedOffset = utf16Offset(of: "Unordered", in: source) {
            textView.setSelectedRange(NSRange(location: unorderedOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                markerStyle: .obsidian
            )
        }
        let revealedUnorderedMarkerColor = foregroundColor(in: textView, source: source, marker: "- Unordered")

        if let orderedOffset = utf16Offset(of: "Ordered", in: source) {
            textView.setSelectedRange(NSRange(location: orderedOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                markerStyle: .obsidian
            )
        }
        let revealedOrderedMarkerColor = foregroundColor(in: textView, source: source, marker: "1. Ordered")

        if let taskOffset = utf16Offset(of: "Done", in: source) {
            textView.setSelectedRange(NSRange(location: taskOffset, length: 0))
            MarkdownVisibleRangeDecorator.decorateVisibleRange(
                in: textView,
                livePreviewMode: .livePreview,
                revealRange: textView.selectedRange(),
                markerStyle: .obsidian
            )
        }
        let revealedTaskMarkerColor = foregroundColor(in: textView, source: source, marker: "- [x]")
        let revealedTaskCheckboxColor = foregroundColor(in: textView, source: source, marker: "[x]")

        return (
            hiddenUnorderedMarkerColor == LivePreviewTheme.concealedColor,
            revealedUnorderedMarkerColor != LivePreviewTheme.concealedColor,
            hiddenOrderedMarkerColor == LivePreviewTheme.concealedColor,
            revealedOrderedMarkerColor != LivePreviewTheme.concealedColor,
            hiddenTaskMarkerColor == LivePreviewTheme.concealedColor
                && hiddenTaskCheckboxColor == LivePreviewTheme.concealedColor,
            revealedTaskMarkerColor != LivePreviewTheme.concealedColor
                && revealedTaskCheckboxColor != LivePreviewTheme.concealedColor,
            hiddenTaskCheckboxColor != LivePreviewTheme.concealedColor
        )
    }

    private static func probeHorizontalRuleFields() -> (
        dashVariantRendered: Bool,
        asteriskVariantRendered: Bool,
        underscoreVariantRendered: Bool,
        falsePositivesRejected: Bool
    ) {
        let source = """
        Before
        ---

        ***

        ___

        --- text

        ```markdown
        ---
        ```

        | Name | Status |
        | --- | --- |
        | Alpha | Draft |
        """
        let result = LivePreviewParser.parse(source)
        let rules = result.blocks
            .filter { $0.kind == .horizontalRule }
            .compactMap { sourceText(for: $0.sourceRange, in: source)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let tableFound = result.blocks.contains { $0.kind == .table }
        let fencedCodeFound = result.blocks.contains {
            if case .fencedCode = $0.kind {
                return true
            }
            return false
        }

        return (
            rules.contains("---"),
            rules.contains("***"),
            rules.contains("___"),
            rules.count == 3 && tableFound && fencedCodeFound && !rules.contains("--- text")
        )
    }

    private static func probeHeadingMarkerGeometry() -> (
        geometry: HeadingMarkerGeometryProbeReport,
        geometryMeasured: Bool,
        textXPositionMeasured: Bool,
        collapsedWidthReduced: Bool,
        collapsedLineHeightPreserved: Bool,
        collapsedSelectionSafe: Bool,
        collapsedMarkedTextSafe: Bool
    ) {
        let source = "# Probe Heading\n\nBody"
        let markerRange = NSRange(location: 0, length: 2)
        let visibleTextView = MarkdownEditorTextViewFactory.makeTextView()
        visibleTextView.string = source
        visibleTextView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: visibleTextView,
            livePreviewMode: .livePreview,
            revealRange: visibleTextView.selectedRange(),
            markerStyle: .accent
        )

        let collapsedTextView = MarkdownEditorTextViewFactory.makeTextView()
        collapsedTextView.string = source
        collapsedTextView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: collapsedTextView,
            livePreviewMode: .livePreview,
            revealRange: collapsedTextView.selectedRange(),
            markerStyle: .obsidian
        )

        guard let headingOffset = utf16Offset(of: "Probe Heading", in: source),
              let originalMarkerRect = boundingRect(in: visibleTextView, range: markerRange),
              let originalTextRect = boundingRect(in: visibleTextView, range: NSRange(location: headingOffset, length: 1)),
              let originalLineRect = lineRect(in: visibleTextView, source: source, marker: "Probe Heading")
        else {
            return (.empty, false, false, false, false, false, false)
        }

        let geometryMeasured = originalMarkerRect.width > 0 && originalTextRect.width > 0
        let textXPositionMeasured = originalTextRect.minX > originalMarkerRect.minX

        guard let collapsedMarkerRect = boundingRect(in: collapsedTextView, range: markerRange),
              let collapsedTextRect = boundingRect(in: collapsedTextView, range: NSRange(location: headingOffset, length: 1)),
              let collapsedLineRect = lineRect(in: collapsedTextView, source: source, marker: "Probe Heading")
        else {
            let geometry = HeadingMarkerGeometryProbeReport(
                originalMarkerWidth: Double(originalMarkerRect.width),
                originalTextX: Double(originalTextRect.minX),
                collapsedMarkerWidth: 0,
                collapsedTextX: 0
            )
            return (geometry, geometryMeasured, textXPositionMeasured, false, false, false, false)
        }

        let geometry = HeadingMarkerGeometryProbeReport(
            originalMarkerWidth: Double(originalMarkerRect.width),
            originalTextX: Double(originalTextRect.minX),
            collapsedMarkerWidth: Double(collapsedMarkerRect.width),
            collapsedTextX: Double(collapsedTextRect.minX)
        )

        let collapsedWidthReduced = collapsedMarkerRect.width < originalMarkerRect.width
            && collapsedTextRect.minX < originalTextRect.minX
        let collapsedLineHeightPreserved = abs(collapsedLineRect.height - originalLineRect.height) <= 1

        collapsedTextView.setSelectedRange(NSRange(location: markerRange.location, length: 0))
        let caretAtMarkerStartPreserved = collapsedTextView.selectedRange() == NSRange(location: markerRange.location, length: 0)
        collapsedTextView.setSelectedRange(NSRange(location: markerRange.upperBound, length: 0))
        let caretAfterMarkerPreserved = collapsedTextView.selectedRange() == NSRange(location: markerRange.upperBound, length: 0)
        collapsedTextView.setSelectedRange(markerRange)
        let selectedMarkerText = (collapsedTextView.string as NSString).substring(with: markerRange)
        let collapsedSelectionSafe = caretAtMarkerStartPreserved
            && caretAfterMarkerPreserved
            && selectedMarkerText == "# "

        let collapsedMarkedTextSafe = probeCollapsedHeadingMarkerMarkedText(source: source, markerRange: markerRange)

        return (
            geometry,
            geometryMeasured,
            textXPositionMeasured,
            collapsedWidthReduced,
            collapsedLineHeightPreserved,
            collapsedSelectionSafe,
            collapsedMarkedTextSafe
        )
    }

    private static func probeMarkerGeometry() -> (
        geometry: MarkerGeometryProbeReport,
        unorderedReported: Bool,
        orderedReported: Bool,
        taskReported: Bool
    ) {
        let source = """
        - Unordered
        1. Ordered
        - [x] Done
        """
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = source
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )

        let geometries = LivePreviewOverlayRenderer.markerGeometries(in: textView)
        let unordered = geometries.first { $0.kind == .unorderedListMarker }
        let ordered = geometries.first { $0.kind == .orderedListMarker }
        let task = geometries.first { $0.kind == .taskCheckbox }
        let geometry = MarkerGeometryProbeReport(
            unorderedMarkerWidth: Double(unordered?.rect.width ?? 0),
            unorderedMarkerX: Double(unordered?.rect.minX ?? 0),
            orderedMarkerWidth: Double(ordered?.rect.width ?? 0),
            orderedMarkerX: Double(ordered?.rect.minX ?? 0),
            taskCheckboxWidth: Double(task?.rect.width ?? 0),
            taskCheckboxX: Double(task?.rect.minX ?? 0)
        )

        return (
            geometry,
            unordered?.rect.width ?? 0 > 0,
            ordered?.rect.width ?? 0 > 0,
            task?.rect.width ?? 0 > 0
        )
    }

    private static func probeUnorderedMarkerDetection() -> (
        dashDetected: Bool,
        asteriskDetected: Bool,
        plusDetected: Bool,
        nestedDetected: Bool,
        tabbedDetected: Bool
    ) {
        let source = "- Dash\n* Star\n+ Plus\n  - Nested\n\t- Tabbed\n"
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = source
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )

        let markerTexts = LivePreviewOverlayRenderer.markerGeometries(in: textView)
            .filter { $0.kind == .unorderedListMarker }
            .compactMap { geometry -> String? in
                sourceText(
                    for: LivePreviewSourceRange(
                        location: geometry.sourceRange.location,
                        length: geometry.sourceRange.length
                    ),
                    in: source
                )
            }

        return (
            markerTexts.contains("- "),
            markerTexts.contains("* "),
            markerTexts.contains("+ "),
            markerTexts.contains("  - "),
            markerTexts.contains("\t- ")
        )
    }

    private static func probeCollapsedHeadingMarkerMarkedText(source: String, markerRange: NSRange) -> Bool {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = scrollView
        window.makeFirstResponder(textView)

        textView.string = source
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: .obsidian
        )
        textView.setSelectedRange(NSRange(location: markerRange.upperBound, length: 0))
        textView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let hadMarkedText = textView.hasMarkedText()
        textView.textStorage?.addAttributes([
            .font: LivePreviewTheme.collapsedSyntaxFont,
            .foregroundColor: LivePreviewTheme.concealedColor
        ], range: markerRange)
        let markerStillPresent = (textView.string as NSString).substring(with: markerRange) == "# "
        let markedTextStillActive = textView.hasMarkedText()
        textView.unmarkText()

        return hadMarkedText && markedTextStillActive && markerStillPresent
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

    private static func lineRect(in textView: NSTextView, source: String, marker: String) -> NSRect? {
        guard let offset = utf16Offset(of: marker, in: source),
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: offset, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else {
            return nil
        }

        let origin = textView.textContainerOrigin
        var result: NSRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, stop in
            guard lineGlyphRange.location < glyphRange.location + glyphRange.length,
                  glyphRange.location < lineGlyphRange.location + lineGlyphRange.length
            else {
                return
            }
            result = NSRect(
                x: lineRect.minX + origin.x,
                y: lineRect.minY + origin.y,
                width: lineRect.width,
                height: lineRect.height
            )
            stop.pointee = true
        }
        return result
    }

    private static func boundingRect(in textView: NSTextView, range: NSRange) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return nil
        }

        let stringLength = (textView.string as NSString).length
        let textRange = NSIntersectionRange(range, NSRange(location: 0, length: stringLength))
        guard textRange.length > 0 else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: textRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            return nil
        }

        let origin = textView.textContainerOrigin
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: origin.x, dy: origin.y)
    }

    private static func propertyHeaderGeometrySeparated(
        title: NSRect?,
        section: NSRect?,
        row: NSRect?,
        body: NSRect?
    ) -> Bool {
        guard let title, let section, let row, let body else {
            return false
        }
        return section.minY - title.minY >= LivePreviewTheme.propertyTitleLineHeight
            && row.minY - section.minY >= LivePreviewTheme.propertySectionLineHeight
            && body.minY - row.minY >= LivePreviewTheme.propertyRowLineHeight
    }

    private static func utf16Offset(of marker: String, in source: String) -> Int? {
        guard let range = source.range(of: marker) else {
            return nil
        }
        return NSRange(range, in: source).location
    }

    private static func sourceText(for sourceRange: LivePreviewSourceRange, in source: String) -> String? {
        guard let range = LivePreviewRangeMapper.stringRange(for: sourceRange, in: source) else {
            return nil
        }
        return String(source[range])
    }
}
