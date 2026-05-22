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
    var obsidianTaskCheckboxOverlayDrawsOutsideReveal: Bool
    var obsidianTaskCheckboxOverlaySuppressedInsideReveal: Bool
    var markerGeometry: MarkerGeometryProbeReport
    var unorderedMarkerGeometryReported: Bool
    var orderedMarkerGeometryReported: Bool
    var taskMarkerGeometryReported: Bool
    var unorderedDashMarkerDetected: Bool
    var unorderedAsteriskMarkerDetected: Bool
    var unorderedPlusMarkerDetected: Bool
    var unorderedNestedMarkerDetected: Bool
    var unorderedTabbedMarkerDetected: Bool
    var obsidianUnorderedMarkerOverlayDrawsOutsideReveal: Bool
    var obsidianUnorderedMarkerOverlaySuppressedInsideReveal: Bool
    var orderedDotMarkerDetected: Bool
    var orderedParenMarkerDetected: Bool
    var orderedMultiDigitMarkerDetected: Bool
    var taskUncheckedMarkerDetected: Bool
    var taskLowercaseCheckedMarkerDetected: Bool
    var taskUppercaseCheckedMarkerDetected: Bool
    var obsidianOrderedMarkerOverlayDrawsOutsideReveal: Bool
    var obsidianOrderedMarkerOverlaySuppressedInsideReveal: Bool
    var markerStyleCompatibilityPreserved: Bool
    var nestedListProbeVersion: Int
    var nestedListFixtureID: String
    var nestedListFailureIDs: [String]
    var nestedListCheckResults: [NestedListCheckProbeReport]
    var nestedListGeometryCases: [NestedListGeometryProbeCase]
    var nestedListGuideSegments: [NestedListGuideSegmentProbeReport]
    var nestedListPixelChecks: [NestedListPixelCheckProbeReport]
    var nestedListResolverScannedLineCount: Int
    var nestedListResolverScannedUTF16Length: Int
    var nestedListUnorderedDepthsResolved: Bool
    var nestedListOrderedDepthsResolved: Bool
    var nestedListTaskDepthsResolved: Bool
    var nestedListMixedDepthsResolved: Bool
    var nestedListTabsNormalizeToDepth: Bool
    var nestedListClusterBreakRespected: Bool
    var nestedListContextIncompleteHandled: Bool
    var nestedListVisibleRangeDepthsResolved: Bool
    var nestedListDepthAwareIndentApplied: Bool
    var nestedListMarkerXIncreasesByDepth: Bool
    var nestedListTextXIncreasesByDepth: Bool
    var nestedListOrderedWidthTextStartNormalized: Bool
    var nestedListGuideSegmentsReported: Bool
    var nestedListGuideStartsBelowParent: Bool
    var nestedListGuideEndsAtDescendant: Bool
    var nestedListGuidePositivePixelsPresent: Bool
    var nestedListGuideNegativePixelsClear: Bool
    var nestedListGuideDirtyRectClipped: Bool
    var nestedListWrappedContinuationAligned: Bool
    var nestedListEOFGeometryMeasured: Bool
    var nestedListRenderPreservesSource: Bool
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
    var tableCompactWidthApplied: Bool
    var tableAlignmentApplied: Bool
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

struct NestedListGeometryProbeCase: Codable, Equatable {
    var caseID: String
    var lineLabel: String
    var kind: String
    var depth: Int
    var leadingColumn: Int
    var markerX: Double
    var textX: Double
    var markerToTextGap: Double
    var sourceLocation: Int
    var visibleRangeCase: String
}

struct NestedListGuideSegmentProbeReport: Codable, Equatable {
    var depth: Int
    var x: Double
    var startY: Double
    var endY: Double
}

struct NestedListCheckProbeReport: Codable, Equatable {
    var failureID: String
    var caseID: String
    var expected: String
    var actual: String
    var tolerance: Double?
    var passed: Bool
}

struct NestedListPixelCheckProbeReport: Codable, Equatable {
    var checkID: String
    var x: Double
    var y: Double
    var expectedPainted: Bool
    var actualPainted: Bool
    var passed: Bool
}

@MainActor
enum LivePreviewStyleProbe {
    private static let expectedFailures: Set<String> = [
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
        let unorderedOverlayFields = probeUnorderedMarkerOverlayPolicy()
        let orderedMarkerFields = probeOrderedMarkerDetection()
        let orderedOverlayFields = probeOrderedMarkerOverlayPolicy()
        let taskMarkerFields = probeTaskMarkerVariantDetection()
        let taskOverlayFields = probeTaskCheckboxOverlayPolicy()
        let tableGeometryFields = probeTableGeometry()
        let tableActiveCellControls = probeTableActiveCellControls()
        let nestedListFields = probeNestedListHierarchy()

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
            obsidianTaskCheckboxVisualVisibleOutsideReveal: taskOverlayFields.drawsOutsideReveal,
            obsidianTaskCheckboxOverlayDrawsOutsideReveal: taskOverlayFields.drawsOutsideReveal,
            obsidianTaskCheckboxOverlaySuppressedInsideReveal: taskOverlayFields.suppressedInsideReveal,
            markerGeometry: markerGeometryFields.geometry,
            unorderedMarkerGeometryReported: markerGeometryFields.unorderedReported,
            orderedMarkerGeometryReported: markerGeometryFields.orderedReported,
            taskMarkerGeometryReported: markerGeometryFields.taskReported,
            unorderedDashMarkerDetected: unorderedMarkerFields.dashDetected,
            unorderedAsteriskMarkerDetected: unorderedMarkerFields.asteriskDetected,
            unorderedPlusMarkerDetected: unorderedMarkerFields.plusDetected,
            unorderedNestedMarkerDetected: unorderedMarkerFields.nestedDetected,
            unorderedTabbedMarkerDetected: unorderedMarkerFields.tabbedDetected,
            obsidianUnorderedMarkerOverlayDrawsOutsideReveal: unorderedOverlayFields.drawsOutsideReveal,
            obsidianUnorderedMarkerOverlaySuppressedInsideReveal: unorderedOverlayFields.suppressedInsideReveal,
            orderedDotMarkerDetected: orderedMarkerFields.dotDetected,
            orderedParenMarkerDetected: orderedMarkerFields.parenDetected,
            orderedMultiDigitMarkerDetected: orderedMarkerFields.multiDigitDetected,
            taskUncheckedMarkerDetected: taskMarkerFields.uncheckedDetected,
            taskLowercaseCheckedMarkerDetected: taskMarkerFields.lowercaseCheckedDetected,
            taskUppercaseCheckedMarkerDetected: taskMarkerFields.uppercaseCheckedDetected,
            obsidianOrderedMarkerOverlayDrawsOutsideReveal: orderedOverlayFields.drawsOutsideReveal,
            obsidianOrderedMarkerOverlaySuppressedInsideReveal: orderedOverlayFields.suppressedInsideReveal,
            markerStyleCompatibilityPreserved: unorderedOverlayFields.compatibilityPreserved
                && orderedOverlayFields.compatibilityPreserved,
            nestedListProbeVersion: nestedListFields.probeVersion,
            nestedListFixtureID: nestedListFields.fixtureID,
            nestedListFailureIDs: nestedListFields.failureIDs,
            nestedListCheckResults: nestedListFields.checkResults,
            nestedListGeometryCases: nestedListFields.geometryCases,
            nestedListGuideSegments: nestedListFields.guideSegments,
            nestedListPixelChecks: nestedListFields.pixelChecks,
            nestedListResolverScannedLineCount: nestedListFields.scannedLineCount,
            nestedListResolverScannedUTF16Length: nestedListFields.scannedUTF16Length,
            nestedListUnorderedDepthsResolved: nestedListFields.unorderedDepthsResolved,
            nestedListOrderedDepthsResolved: nestedListFields.orderedDepthsResolved,
            nestedListTaskDepthsResolved: nestedListFields.taskDepthsResolved,
            nestedListMixedDepthsResolved: nestedListFields.mixedDepthsResolved,
            nestedListTabsNormalizeToDepth: nestedListFields.tabsNormalizeToDepth,
            nestedListClusterBreakRespected: nestedListFields.clusterBreakRespected,
            nestedListContextIncompleteHandled: nestedListFields.contextIncompleteHandled,
            nestedListVisibleRangeDepthsResolved: nestedListFields.visibleRangeDepthsResolved,
            nestedListDepthAwareIndentApplied: (nestedListParagraphStyle?.headIndent ?? 0) > (listParagraphStyle?.headIndent ?? 0),
            nestedListMarkerXIncreasesByDepth: nestedListFields.markerXIncreasesByDepth,
            nestedListTextXIncreasesByDepth: nestedListFields.textXIncreasesByDepth,
            nestedListOrderedWidthTextStartNormalized: nestedListFields.orderedWidthTextStartNormalized,
            nestedListGuideSegmentsReported: nestedListFields.guideSegmentsReported,
            nestedListGuideStartsBelowParent: nestedListFields.guideStartsBelowParent,
            nestedListGuideEndsAtDescendant: nestedListFields.guideEndsAtDescendant,
            nestedListGuidePositivePixelsPresent: nestedListFields.guidePositivePixelsPresent,
            nestedListGuideNegativePixelsClear: nestedListFields.guideNegativePixelsClear,
            nestedListGuideDirtyRectClipped: nestedListFields.guideDirtyRectClipped,
            nestedListWrappedContinuationAligned: nestedListFields.wrappedContinuationAligned,
            nestedListEOFGeometryMeasured: nestedListFields.eofGeometryMeasured,
            nestedListRenderPreservesSource: nestedListFields.renderPreservesSource,
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
            tableCompactWidthApplied: tableGeometryFields.compactWidthApplied,
            tableAlignmentApplied: tableGeometryFields.alignmentApplied,
            horizontalRuleDashVariantRendered: horizontalRuleFields.dashVariantRendered,
            horizontalRuleAsteriskVariantRendered: horizontalRuleFields.asteriskVariantRendered,
            horizontalRuleUnderscoreVariantRendered: horizontalRuleFields.underscoreVariantRendered,
            horizontalRuleFalsePositivesRejected: horizontalRuleFields.falsePositivesRejected,
            tableRenderedStateVisible: tableHeaderAttributes?[.font] as? NSFont == LivePreviewTheme.strongFont
                && tableBodyAttributes?[.backgroundColor] as? NSColor == LivePreviewTheme.tableCellBackgroundColor
                && hiddenTablePipeColor == LivePreviewTheme.concealedColor
                && hiddenTableAlignmentColor == LivePreviewTheme.concealedColor,
            tableActiveCellEditStateVisible: tableActiveCellControls.editStateVisible,
            tableRowAddControlVisibleWhenFocused: tableActiveCellControls.rowControlVisible,
            tableColumnAddControlVisibleWhenFocused: tableActiveCellControls.columnControlVisible,
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
        taskSourceTokenRevealedInsideLine: Bool
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
                && revealedTaskCheckboxColor != LivePreviewTheme.concealedColor
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
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        return (
            markerTexts.contains("-"),
            markerTexts.contains("*"),
            markerTexts.contains("+"),
            markerTexts.filter { $0 == "-" }.count >= 3,
            markerTexts.filter { $0 == "-" }.count >= 3
        )
    }

    private static func probeUnorderedMarkerOverlayPolicy() -> (
        drawsOutsideReveal: Bool,
        suppressedInsideReveal: Bool,
        compatibilityPreserved: Bool
    ) {
        let source = "- Bullet\n"
        let result = LivePreviewParser.parse(source)
        guard let block = result.blocks.first,
              let markerKind = LivePreviewOverlayRenderer.markerGeometries(
                in: configuredTextView(source: source, markerStyle: .obsidian)
              ).first?.kind,
              let bulletOffset = utf16Offset(of: "Bullet", in: source)
        else {
            return (false, false, false)
        }

        let outsideState = LivePreviewOverlayState(
            markerStyle: .obsidian,
            revealRange: NSRange(location: (source as NSString).length, length: 0)
        )
        let insideState = LivePreviewOverlayState(
            markerStyle: .obsidian,
            revealRange: NSRange(location: bulletOffset, length: 0)
        )
        let accentState = LivePreviewOverlayState(
            markerStyle: .accent,
            revealRange: outsideState.revealRange
        )
        let hiddenState = LivePreviewOverlayState(
            markerStyle: .hidden,
            revealRange: outsideState.revealRange
        )

        return (
            LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
                for: block,
                markerKind: markerKind,
                state: outsideState
            ),
            !LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
                for: block,
                markerKind: markerKind,
                state: insideState
            ),
            !LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
                for: block,
                markerKind: markerKind,
                state: accentState
            ) && !LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
                for: block,
                markerKind: markerKind,
                state: hiddenState
            )
        )
    }

    private static func probeOrderedMarkerDetection() -> (
        dotDetected: Bool,
        parenDetected: Bool,
        multiDigitDetected: Bool
    ) {
        let source = "1. Dot\n2) Paren\n10. Ten\n"
        let markerTexts = LivePreviewOverlayRenderer.markerGeometries(
            in: configuredTextView(source: source, markerStyle: .obsidian)
        )
        .filter { $0.kind == .orderedListMarker }
        .compactMap { geometry -> String? in
            sourceText(
                for: LivePreviewSourceRange(
                    location: geometry.sourceRange.location,
                    length: geometry.sourceRange.length
                ),
                in: source
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (
            markerTexts.contains("1."),
            markerTexts.contains("2)"),
            markerTexts.contains("10.")
        )
    }

    private static func probeOrderedMarkerOverlayPolicy() -> (
        drawsOutsideReveal: Bool,
        suppressedInsideReveal: Bool,
        compatibilityPreserved: Bool
    ) {
        let source = "1. Ordered\n"
        let result = LivePreviewParser.parse(source)
        guard let block = result.blocks.first,
              let markerKind = LivePreviewOverlayRenderer.markerGeometries(
                in: configuredTextView(source: source, markerStyle: .obsidian)
              ).first?.kind,
              let textOffset = utf16Offset(of: "Ordered", in: source)
        else {
            return (false, false, false)
        }

        let outsideState = LivePreviewOverlayState(
            markerStyle: .obsidian,
            revealRange: NSRange(location: (source as NSString).length, length: 0)
        )
        let drawsOutsideReveal = LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
            for: block,
            markerKind: markerKind,
            state: outsideState
        )
        let suppressedInsideReveal = !LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
            for: block,
            markerKind: markerKind,
            state: LivePreviewOverlayState(
                markerStyle: .obsidian,
                revealRange: NSRange(location: textOffset, length: 0)
            )
        )
        let compatibilityPreserved = !LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
            for: block,
            markerKind: markerKind,
            state: LivePreviewOverlayState(markerStyle: .accent, revealRange: outsideState.revealRange)
        ) && !LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
            for: block,
            markerKind: markerKind,
            state: LivePreviewOverlayState(markerStyle: .hidden, revealRange: outsideState.revealRange)
        )

        return (
            drawsOutsideReveal,
            suppressedInsideReveal,
            compatibilityPreserved
        )
    }

    private static func probeTaskMarkerVariantDetection() -> (
        uncheckedDetected: Bool,
        lowercaseCheckedDetected: Bool,
        uppercaseCheckedDetected: Bool
    ) {
        let source = "- [ ] Unchecked\n- [x] Lowercase\n- [X] Uppercase\n"
        let parsed = LivePreviewParser.parse(source)
        let resolution = LivePreviewListMarkerResolver.resolve(source: source, blocks: parsed.blocks)
        let prefixes = resolution.contextsByBlockRange.values.compactMap { context in
            sourceText(
                for: LivePreviewSourceRange(
                    location: context.prefixRange.location,
                    length: context.prefixRange.length
                ),
                in: source
            )
        }

        return (
            prefixes.contains { $0.contains("[ ]") },
            prefixes.contains { $0.contains("[x]") },
            prefixes.contains { $0.contains("[X]") }
        )
    }

    private static func probeTaskCheckboxOverlayPolicy() -> (
        drawsOutsideReveal: Bool,
        suppressedInsideReveal: Bool
    ) {
        let source = "- [x] Done\n"
        let result = LivePreviewParser.parse(source)
        guard let block = result.blocks.first,
              let markerKind = LivePreviewOverlayRenderer.markerGeometries(
                in: configuredTextView(source: source, markerStyle: .obsidian)
              ).first?.kind,
              let textOffset = utf16Offset(of: "Done", in: source)
        else {
            return (false, false)
        }

        return (
            LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
                for: block,
                markerKind: markerKind,
                state: LivePreviewOverlayState(
                    markerStyle: .obsidian,
                    revealRange: NSRange(location: (source as NSString).length, length: 0)
                )
            ),
            !LivePreviewOverlayRenderer.shouldDrawMarkerOverlay(
                for: block,
                markerKind: markerKind,
                state: LivePreviewOverlayState(
                    markerStyle: .obsidian,
                    revealRange: NSRange(location: textOffset, length: 0)
                )
            )
        )
    }

    private static func probeNestedListHierarchy() -> (
        probeVersion: Int,
        fixtureID: String,
        failureIDs: [String],
        checkResults: [NestedListCheckProbeReport],
        geometryCases: [NestedListGeometryProbeCase],
        guideSegments: [NestedListGuideSegmentProbeReport],
        pixelChecks: [NestedListPixelCheckProbeReport],
        scannedLineCount: Int,
        scannedUTF16Length: Int,
        unorderedDepthsResolved: Bool,
        orderedDepthsResolved: Bool,
        taskDepthsResolved: Bool,
        mixedDepthsResolved: Bool,
        tabsNormalizeToDepth: Bool,
        clusterBreakRespected: Bool,
        contextIncompleteHandled: Bool,
        visibleRangeDepthsResolved: Bool,
        markerXIncreasesByDepth: Bool,
        textXIncreasesByDepth: Bool,
        orderedWidthTextStartNormalized: Bool,
        guideSegmentsReported: Bool,
        guideStartsBelowParent: Bool,
        guideEndsAtDescendant: Bool,
        guidePositivePixelsPresent: Bool,
        guideNegativePixelsClear: Bool,
        guideDirtyRectClipped: Bool,
        wrappedContinuationAligned: Bool,
        eofGeometryMeasured: Bool,
        renderPreservesSource: Bool
    ) {
        let source = """
        - bullet parent
          - bullet child
            - bullet grandchild
        1. number parent
           1. number child
              10. number grandchild
        - [ ] task parent
          - [x] task child
            - [ ] task grandchild
        - mixed parent
          1. mixed ordered child
             - [ ] mixed task grandchild
        - tab parent
        \t- tab child
          - space child
        1. width one
        10. width ten
        - cluster parent
          - cluster child

        paragraph break
          - indented new cluster root
        ---
        | A | B |
        | --- | --- |
        | C | D |
        ```markdown
        - code bullet
        ```
        """
        let fixtureID = "nested-list-hierarchy-v1"
        let textView = configuredTextView(source: source, markerStyle: .obsidian)
        let parsed = LivePreviewParser.parse(source)
        let resolution = LivePreviewListMarkerResolver.resolve(source: source, blocks: parsed.blocks)
        let contexts = resolution.contextsByBlockRange.values.sorted {
            $0.blockRange.location < $1.blockRange.location
        }
        let markerGeometries = LivePreviewOverlayRenderer.markerGeometries(in: textView)

        func kindName(_ kind: LivePreviewListMarkerContext.Kind) -> String {
            switch kind {
            case .unordered:
                return "unordered"
            case .ordered:
                return "ordered"
            case .task:
                return "task"
            }
        }

        func context(containing label: String) -> LivePreviewListMarkerContext? {
            guard let offset = utf16Offset(of: label, in: source) else {
                return nil
            }
            return contexts.first { NSLocationInRange(offset, $0.blockRange) }
        }

        func markerGeometry(for context: LivePreviewListMarkerContext) -> LivePreviewMarkerGeometry? {
            markerGeometries.first {
                $0.sourceRange.location == context.markerRange.location
                    && $0.sourceRange.length == context.markerRange.length
            }
        }

        func textRect(for label: String) -> NSRect? {
            guard let offset = utf16Offset(of: label, in: source) else {
                return nil
            }
            return boundingRect(in: textView, range: NSRange(location: offset, length: 1))
        }

        let caseSpecs: [(caseID: String, label: String, visibleRangeCase: String)] = [
            ("unordered-parent", "bullet parent", "full"),
            ("unordered-child", "bullet child", "full"),
            ("unordered-grandchild", "bullet grandchild", "full"),
            ("ordered-parent", "number parent", "full"),
            ("ordered-child", "number child", "full"),
            ("ordered-grandchild", "number grandchild", "full"),
            ("task-parent", "task parent", "full"),
            ("task-child", "task child", "full"),
            ("task-grandchild", "task grandchild", "full"),
            ("mixed-parent", "mixed parent", "full"),
            ("mixed-ordered-child", "mixed ordered child", "full"),
            ("mixed-task-grandchild", "mixed task grandchild", "full"),
            ("tab-child", "tab child", "full"),
            ("space-child", "space child", "full"),
            ("ordered-width-one", "width one", "full"),
            ("ordered-width-ten", "width ten", "full"),
            ("indented-new-cluster-root", "indented new cluster root", "full")
        ]

        let geometryCases = caseSpecs.compactMap { spec -> NestedListGeometryProbeCase? in
            guard let context = context(containing: spec.label),
                  let markerGeometry = markerGeometry(for: context),
                  let textRect = textRect(for: spec.label)
            else {
                return nil
            }
            return NestedListGeometryProbeCase(
                caseID: spec.caseID,
                lineLabel: spec.label,
                kind: kindName(context.kind),
                depth: context.depth,
                leadingColumn: context.leadingColumn,
                markerX: Double(markerGeometry.rect.minX),
                textX: Double(textRect.minX),
                markerToTextGap: Double(textRect.minX - markerGeometry.rect.maxX),
                sourceLocation: context.blockRange.location,
                visibleRangeCase: spec.visibleRangeCase
            )
        }

        func depths(_ labels: [String]) -> [Int]? {
            let values = labels.compactMap { context(containing: $0)?.depth }
            return values.count == labels.count ? values : nil
        }

        func xs(_ labels: [String], keyPath: KeyPath<NestedListGeometryProbeCase, Double>) -> [Double]? {
            let values = labels.compactMap { label in
                geometryCases.first { $0.lineLabel == label }?[keyPath: keyPath]
            }
            return values.count == labels.count ? values : nil
        }

        func strictlyIncreasing(_ values: [Double]?) -> Bool {
            guard let values, values.count >= 2 else {
                return false
            }
            return zip(values, values.dropFirst()).allSatisfy { previous, next in
                next > previous + 1
            }
        }

        let unorderedLabels = ["bullet parent", "bullet child", "bullet grandchild"]
        let orderedLabels = ["number parent", "number child", "number grandchild"]
        let taskLabels = ["task parent", "task child", "task grandchild"]
        let mixedLabels = ["mixed parent", "mixed ordered child", "mixed task grandchild"]
        let unorderedDepthsResolved = depths(unorderedLabels) == [0, 1, 2]
        let orderedDepthsResolved = depths(orderedLabels) == [0, 1, 2]
        let taskDepthsResolved = depths(taskLabels) == [0, 1, 2]
        let mixedDepthsResolved = depths(mixedLabels) == [0, 1, 2]

        let tabCase = geometryCases.first { $0.lineLabel == "tab child" }
        let spaceCase = geometryCases.first { $0.lineLabel == "space child" }
        let tabsNormalizeToDepth = tabCase?.depth == 1
            && spaceCase?.depth == 1
            && abs((tabCase?.markerX ?? 0) - (spaceCase?.markerX ?? .infinity)) <= 1
            && abs((tabCase?.textX ?? 0) - (spaceCase?.textX ?? .infinity)) <= 1
        let clusterBreakRespected = context(containing: "indented new cluster root")?.depth == 0

        let allLabels = unorderedLabels + orderedLabels + taskLabels + mixedLabels
        let markerXIncreasesByDepth = strictlyIncreasing(xs(unorderedLabels, keyPath: \.markerX))
            && strictlyIncreasing(xs(orderedLabels, keyPath: \.markerX))
            && strictlyIncreasing(xs(taskLabels, keyPath: \.markerX))
            && strictlyIncreasing(xs(mixedLabels, keyPath: \.markerX))
        let textXIncreasesByDepth = strictlyIncreasing(xs(unorderedLabels, keyPath: \.textX))
            && strictlyIncreasing(xs(orderedLabels, keyPath: \.textX))
            && strictlyIncreasing(xs(taskLabels, keyPath: \.textX))
            && strictlyIncreasing(xs(mixedLabels, keyPath: \.textX))
            && allLabels.allSatisfy { label in geometryCases.contains { $0.lineLabel == label } }
        let widthOne = geometryCases.first { $0.lineLabel == "width one" }
        let widthTen = geometryCases.first { $0.lineLabel == "width ten" }
        let orderedWidthTextStartNormalized = widthOne?.kind == "ordered"
            && widthTen?.kind == "ordered"
            && widthOne?.depth == widthTen?.depth
            && abs((widthOne?.textX ?? 0) - (widthTen?.textX ?? .infinity)) <= 1

        let guideSegments = LivePreviewOverlayRenderer.guideSegments(in: textView)
        let guideReports = guideSegments.map {
            NestedListGuideSegmentProbeReport(
                depth: $0.depth,
                x: $0.x,
                startY: $0.startY,
                endY: $0.endY
            )
        }
        let depthOneGuide = guideSegments.first { $0.depth == 1 }
        let parentLine = lineRect(in: textView, source: source, marker: "bullet parent")
        let childLine = lineRect(in: textView, source: source, marker: "bullet child")
        let grandchildLine = lineRect(in: textView, source: source, marker: "bullet grandchild")
        let guideStartsBelowParent = {
            guard let depthOneGuide, let parentLine, let childLine else {
                return false
            }
            return depthOneGuide.startY > parentLine.minY
                && abs(depthOneGuide.startY - childLine.minY) <= 1
        }()
        let guideEndsAtDescendant = {
            guard let depthOneGuide, let grandchildLine else {
                return false
            }
            return abs(depthOneGuide.endY - grandchildLine.maxY) <= 1
        }()
        let pixelChecks = nestedListGuidePixelChecks(
            textView: textView,
            source: source,
            depthOneGuide: depthOneGuide
        )
        let guidePositivePixelsPresent = pixelChecks
            .filter(\.expectedPainted)
            .allSatisfy(\.passed)
        let guideNegativePixelsClear = pixelChecks
            .filter { !$0.expectedPainted }
            .allSatisfy(\.passed)
        let guideDirtyRectClipped = nestedListGuideDirtyRectClipped(
            textView: textView,
            source: source,
            depthOneGuide: depthOneGuide
        )

        let clippedWindow = context(containing: "bullet child").map(\.blockRange.location).map {
            LivePreviewSourceRange(location: $0, length: (source as NSString).length - $0)
        }
        let clippedDepthResolved = clippedWindow.map { window in
            let clippedParsed = LivePreviewParser.parse(source, in: window)
            let clippedResolution = LivePreviewListMarkerResolver.resolve(
                source: source,
                blocks: clippedParsed.blocks,
                parseWindow: window
            )
            return clippedResolution.contextsByBlockRange.values.first { context in
                sourceText(
                    for: LivePreviewSourceRange(location: context.blockRange.location, length: context.blockRange.length),
                    in: source
                )?.contains("bullet child") == true
            }?.depth == 1
        } ?? false
        let clippedContextHandled = clippedDepthResolved
        let wrappedContinuationAligned = probeWrappedNestedListGeometry()
        let eofGeometryMeasured = probeEOFNestedListGeometry()

        let checkResults: [NestedListCheckProbeReport] = [
            checkResult(
                failureID: "nestedListUnorderedDepthsResolved",
                caseID: "unordered-depths",
                expected: "[0, 1, 2]",
                actual: String(describing: depths(unorderedLabels)),
                passed: unorderedDepthsResolved
            ),
            checkResult(
                failureID: "nestedListOrderedDepthsResolved",
                caseID: "ordered-depths",
                expected: "[0, 1, 2]",
                actual: String(describing: depths(orderedLabels)),
                passed: orderedDepthsResolved
            ),
            checkResult(
                failureID: "nestedListTaskDepthsResolved",
                caseID: "task-depths",
                expected: "[0, 1, 2]",
                actual: String(describing: depths(taskLabels)),
                passed: taskDepthsResolved
            ),
            checkResult(
                failureID: "nestedListMixedDepthsResolved",
                caseID: "mixed-depths",
                expected: "[0, 1, 2]",
                actual: String(describing: depths(mixedLabels)),
                passed: mixedDepthsResolved
            ),
            checkResult(
                failureID: "nestedListTabsNormalizeToDepth",
                caseID: "tab-vs-space-depth",
                expected: "same depth and x-position within 1px",
                actual: "tabDepth=\(tabCase?.depth ?? -1), spaceDepth=\(spaceCase?.depth ?? -1)",
                tolerance: 1,
                passed: tabsNormalizeToDepth
            ),
            checkResult(
                failureID: "nestedListClusterBreakRespected",
                caseID: "cluster-break",
                expected: "depth 0 after paragraph break",
                actual: "depth \(context(containing: "indented new cluster root")?.depth ?? -1)",
                passed: clusterBreakRespected
            ),
            checkResult(
                failureID: "nestedListContextIncompleteHandled",
                caseID: "visible-context",
                expected: "bounded ancestor context resolves child depth",
                actual: "resolved=\(clippedDepthResolved)",
                passed: clippedContextHandled
            ),
            checkResult(
                failureID: "nestedListVisibleRangeDepthsResolved",
                caseID: "visible-range-depth",
                expected: "child depth 1",
                actual: "resolved=\(clippedDepthResolved)",
                passed: clippedDepthResolved
            ),
            checkResult(
                failureID: "nestedListMarkerXIncreasesByDepth",
                caseID: "marker-x-depth",
                expected: "marker x strictly increases by depth",
                actual: geometrySummary(geometryCases, keyPath: \.markerX),
                tolerance: 1,
                passed: markerXIncreasesByDepth
            ),
            checkResult(
                failureID: "nestedListTextXIncreasesByDepth",
                caseID: "text-x-depth",
                expected: "text x strictly increases by depth",
                actual: geometrySummary(geometryCases, keyPath: \.textX),
                tolerance: 1,
                passed: textXIncreasesByDepth
            ),
            checkResult(
                failureID: "nestedListOrderedWidthTextStartNormalized",
                caseID: "ordered-width-normalized",
                expected: "same-depth ordered text starts within 1px",
                actual: "one=\(widthOne?.textX ?? -1), ten=\(widthTen?.textX ?? -1)",
                tolerance: 1,
                passed: orderedWidthTextStartNormalized
            ),
            checkResult(
                failureID: "nestedListGuideSegmentsReported",
                caseID: "guide-segments",
                expected: "at least one guide segment",
                actual: "\(guideSegments.count)",
                passed: !guideSegments.isEmpty
            ),
            checkResult(
                failureID: "nestedListGuideStartsBelowParent",
                caseID: "guide-start",
                expected: "guide starts on first child line",
                actual: "start=\(depthOneGuide?.startY ?? -1), child=\(childLine?.minY ?? -1)",
                tolerance: 1,
                passed: guideStartsBelowParent
            ),
            checkResult(
                failureID: "nestedListGuideEndsAtDescendant",
                caseID: "guide-end",
                expected: "guide ends on final descendant line",
                actual: "end=\(depthOneGuide?.endY ?? -1), descendant=\(grandchildLine?.maxY ?? -1)",
                tolerance: 1,
                passed: guideEndsAtDescendant
            ),
            checkResult(
                failureID: "nestedListGuidePositivePixelsPresent",
                caseID: "guide-positive-pixels",
                expected: "positive guide samples painted",
                actual: pixelChecksSummary(pixelChecks, expectedPainted: true),
                passed: guidePositivePixelsPresent
            ),
            checkResult(
                failureID: "nestedListGuideNegativePixelsClear",
                caseID: "guide-negative-pixels",
                expected: "negative guide samples clear",
                actual: pixelChecksSummary(pixelChecks, expectedPainted: false),
                passed: guideNegativePixelsClear
            ),
            checkResult(
                failureID: "nestedListGuideDirtyRectClipped",
                caseID: "guide-dirty-rect",
                expected: "guide paint clipped to dirty rect",
                actual: "clipped=\(guideDirtyRectClipped)",
                passed: guideDirtyRectClipped
            ),
            checkResult(
                failureID: "nestedListWrappedContinuationAligned",
                caseID: "wrapped-list",
                expected: "wrapped continuation aligns and marker uses first visual line",
                actual: "aligned=\(wrappedContinuationAligned)",
                tolerance: 1,
                passed: wrappedContinuationAligned
            ),
            checkResult(
                failureID: "nestedListEOFGeometryMeasured",
                caseID: "eof-list",
                expected: "final list item without newline has depth and geometry",
                actual: "measured=\(eofGeometryMeasured)",
                passed: eofGeometryMeasured
            ),
            checkResult(
                failureID: "nestedListRenderPreservesSource",
                caseID: "source-preservation",
                expected: "render keeps backing source identical",
                actual: "preserved=\(textView.string == source)",
                passed: textView.string == source
            )
        ]

        return (
            1,
            fixtureID,
            checkResults.filter { !$0.passed }.map(\.failureID).sorted(),
            checkResults,
            geometryCases,
            guideReports,
            pixelChecks,
            resolution.scannedLineCount,
            resolution.scannedUTF16Length,
            unorderedDepthsResolved,
            orderedDepthsResolved,
            taskDepthsResolved,
            mixedDepthsResolved,
            tabsNormalizeToDepth,
            clusterBreakRespected,
            clippedContextHandled,
            clippedDepthResolved,
            markerXIncreasesByDepth,
            textXIncreasesByDepth,
            orderedWidthTextStartNormalized,
            !guideSegments.isEmpty,
            guideStartsBelowParent,
            guideEndsAtDescendant,
            guidePositivePixelsPresent,
            guideNegativePixelsClear,
            guideDirtyRectClipped,
            wrappedContinuationAligned,
            eofGeometryMeasured,
            textView.string == source
        )
    }

    private static func nestedListGuidePixelChecks(
        textView: NSTextView,
        source: String,
        depthOneGuide: LivePreviewOverlayRenderer.ListGuideSegment?
    ) -> [NestedListPixelCheckProbeReport] {
        guard let interactionTextView = textView as? MarkdownInteractionTextView,
              let depthOneGuide,
              let bitmap = renderedOverlayBitmap(for: interactionTextView, source: source)
        else {
            return [
                NestedListPixelCheckProbeReport(
                    checkID: "guide-render-setup",
                    x: 0,
                    y: 0,
                    expectedPainted: true,
                    actualPainted: false,
                    passed: false
                )
            ]
        }

        let positiveSamples: [(String, NSPoint)] = [
            ("guide-positive-first-child", NSPoint(x: depthOneGuide.x, y: depthOneGuide.startY + 2)),
            ("guide-positive-descendant", NSPoint(x: depthOneGuide.x, y: max(depthOneGuide.startY + 2, depthOneGuide.endY - 2)))
        ]
        let negativeSamples: [(String, NSPoint)] = [
            ("guide-negative-parent-line", lineRect(in: textView, source: source, marker: "bullet parent").map {
                NSPoint(x: depthOneGuide.x, y: $0.midY)
            } ?? .zero),
            ("guide-negative-blank-gap", lineRect(in: textView, source: source, marker: "paragraph break").map {
                NSPoint(x: depthOneGuide.x, y: $0.midY)
            } ?? .zero),
            ("guide-negative-code-fence", lineRect(in: textView, source: source, marker: "code bullet").map {
                NSPoint(x: depthOneGuide.x, y: $0.midY)
            } ?? .zero)
        ]

        let positives = positiveSamples.map {
            pixelCheck(id: $0.0, point: $0.1, expectedPainted: true, bitmap: bitmap)
        }
        let negatives = negativeSamples.map {
            pixelCheck(id: $0.0, point: $0.1, expectedPainted: false, bitmap: bitmap)
        }
        return positives + negatives
    }

    private static func nestedListGuideDirtyRectClipped(
        textView: NSTextView,
        source: String,
        depthOneGuide: LivePreviewOverlayRenderer.ListGuideSegment?
    ) -> Bool {
        guard let interactionTextView = textView as? MarkdownInteractionTextView,
              let depthOneGuide
        else {
            return false
        }
        let clipRect = NSRect(
            x: CGFloat(depthOneGuide.x) - 2,
            y: CGFloat(depthOneGuide.startY),
            width: 4,
            height: max(2, CGFloat(depthOneGuide.endY - depthOneGuide.startY) / 2)
        )
        guard let bitmap = renderedOverlayBitmap(
            for: interactionTextView,
            source: source,
            dirtyRect: clipRect
        ) else {
            return false
        }

        let insidePoint = NSPoint(x: depthOneGuide.x, y: depthOneGuide.startY + 2)
        let outsidePoint = NSPoint(x: depthOneGuide.x, y: min(depthOneGuide.endY - 2, Double(clipRect.maxY) + 4))
        return pixelIsPainted(near: insidePoint, in: bitmap)
            && !pixelIsPainted(near: outsidePoint, in: bitmap)
    }

    private static func probeWrappedNestedListGeometry() -> Bool {
        let source = """
        - parent
          - child wraps with enough words to force a second visual fragment when the text container is narrow and the continuation line must align with the first rendered text column instead of falling back to raw source whitespace
        """
        let textView = configuredTextView(source: source, markerStyle: .obsidian)
        textView.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
        textView.textContainer?.containerSize = NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        guard let childOffset = utf16Offset(of: "child wraps", in: source),
              let context = LivePreviewListMarkerResolver.resolve(
                source: source,
                blocks: LivePreviewParser.parse(source).blocks
              ).contextsByBlockRange.values.first(where: { NSLocationInRange(childOffset, $0.blockRange) }),
              let markerGeometry = LivePreviewOverlayRenderer.markerGeometries(in: textView)
                .first(where: { $0.sourceRange.location == context.markerRange.location }),
              let childLineRect = lineRect(in: textView, source: source, marker: "child wraps")
        else {
            return false
        }

        let fragments = lineFragmentRects(in: textView, range: context.blockRange)
        guard fragments.count >= 2 else {
            return false
        }
        return abs(fragments[0].minX - fragments[1].minX) <= 1
            && abs(markerGeometry.lineRect.minY - childLineRect.minY) <= 1
            && markerGeometry.lineRect.height <= childLineRect.height + 1
    }

    private static func probeEOFNestedListGeometry() -> Bool {
        let source = "- parent\n  - child without trailing newline"
        let textView = configuredTextView(source: source, markerStyle: .obsidian)
        let parsed = LivePreviewParser.parse(source)
        let resolution = LivePreviewListMarkerResolver.resolve(source: source, blocks: parsed.blocks)
        guard let childOffset = utf16Offset(of: "child without", in: source),
              let childContext = resolution.contextsByBlockRange.values.first(where: {
                NSLocationInRange(childOffset, $0.blockRange)
              }),
              childContext.depth == 1,
              LivePreviewOverlayRenderer.markerGeometries(in: textView).contains(where: {
                $0.sourceRange.location == childContext.markerRange.location
            })
        else {
            return false
        }
        return textView.string == source
    }

    private static func checkResult(
        failureID: String,
        caseID: String,
        expected: String,
        actual: String,
        tolerance: Double? = nil,
        passed: Bool
    ) -> NestedListCheckProbeReport {
        NestedListCheckProbeReport(
            failureID: failureID,
            caseID: caseID,
            expected: expected,
            actual: actual,
            tolerance: tolerance,
            passed: passed
        )
    }

    private static func geometrySummary(
        _ cases: [NestedListGeometryProbeCase],
        keyPath: KeyPath<NestedListGeometryProbeCase, Double>
    ) -> String {
        cases
            .map { "\($0.caseID)=\($0[keyPath: keyPath].rounded(toPlaces: 2))" }
            .joined(separator: ", ")
    }

    private static func pixelChecksSummary(
        _ checks: [NestedListPixelCheckProbeReport],
        expectedPainted: Bool
    ) -> String {
        checks
            .filter { $0.expectedPainted == expectedPainted }
            .map { "\($0.checkID)=\($0.actualPainted)" }
            .joined(separator: ", ")
    }

    private static func renderedOverlayBitmap(
        for textView: MarkdownInteractionTextView,
        source: String,
        dirtyRect: NSRect? = nil
    ) -> NSBitmapImageRep? {
        let bounds = textView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(bounds.width)),
                pixelsHigh: Int(ceil(bounds.height)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        bounds.fill()
        LivePreviewOverlayRenderer.drawForegrounds(
            in: textView,
            dirtyRect: dirtyRect ?? bounds,
            state: LivePreviewOverlayState(
                markerStyle: .obsidian,
                revealRange: NSRange(location: (source as NSString).length, length: 0)
            )
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private static func pixelCheck(
        id: String,
        point: NSPoint,
        expectedPainted: Bool,
        bitmap: NSBitmapImageRep
    ) -> NestedListPixelCheckProbeReport {
        let actualPainted = pixelIsPainted(near: point, in: bitmap)
        return NestedListPixelCheckProbeReport(
            checkID: id,
            x: Double(point.x),
            y: Double(point.y),
            expectedPainted: expectedPainted,
            actualPainted: actualPainted,
            passed: actualPainted == expectedPainted
        )
    }

    private static func pixelIsPainted(near point: NSPoint, in bitmap: NSBitmapImageRep) -> Bool {
        let centerX = Int(point.x.rounded())
        let centerY = bitmap.pixelsHigh - 1 - Int(point.y.rounded())
        for y in (centerY - 1)...(centerY + 1) {
            for x in (centerX - 1)...(centerX + 1) {
                guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: x, y: y)
                else {
                    continue
                }
                if color.alphaComponent > 0.05 {
                    return true
                }
            }
        }
        return false
    }

    private static func probeTableActiveCellControls() -> (
        editStateVisible: Bool,
        rowControlVisible: Bool,
        columnControlVisible: Bool
    ) {
        let source = """
        | Name | Status |
        | --- | --- |
        | Alpha | Draft |
        """
        let textView = MarkdownEditorTextViewFactory.makeTextView() as! MarkdownInteractionTextView
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
        guard let table = LivePreviewTableParser.parse(source).first,
              let layout = LivePreviewTableLayout.make(for: table, in: textView),
              let cell = layout.cells.first(where: { !$0.isHeader && $0.tableCell.text == "Draft" })
        else {
            return (false, false, false)
        }

        let activated = textView.setActiveTableCell(at: NSPoint(x: cell.textRect.midX, y: cell.textRect.midY))
        let editStateVisible = activated
            && textView.activeTableCellEditorFrame?.intersects(cell.textRect) == true
            && !LivePreviewOverlayRenderer.shouldDrawTableCellText(cell.tableCell, state: textView.livePreviewOverlayState)
        return (
            editStateVisible,
            LivePreviewOverlayRenderer.shouldDrawTableControls(state: textView.livePreviewOverlayState)
                && layout.rowAddControlRect(for: cell.tableCell) != nil,
            LivePreviewOverlayRenderer.shouldDrawTableControls(state: textView.livePreviewOverlayState)
                && layout.columnAddControlRect(for: cell.tableCell) != nil
        )
    }

    private static func probeTableGeometry() -> (
        compactWidthApplied: Bool,
        alignmentApplied: Bool
    ) {
        let source = """
        | Name | Status |
        | --- | --- |
        | Alpha | Draft |

        | Left | Center | Right |
        | :--- | :---: | ---: |
        | Alpha | Beta | Gamma |
        """
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.string = source
        guard LivePreviewTableParser.parse(source).count == 2,
              let simpleTable = LivePreviewTableParser.parse(source).first,
              let alignedTable = LivePreviewTableParser.parse(source).dropFirst().first,
              let simpleLayout = LivePreviewTableLayout.make(for: simpleTable, in: textView),
              let alignedLayout = LivePreviewTableLayout.make(for: alignedTable, in: textView)
        else {
            return (false, false)
        }

        let compactWidthApplied = simpleLayout.outerRect.width < 420
            && simpleLayout.outerRect.width >= 120
        let centerColumnApplied = alignedLayout.cells.contains {
            $0.columnIndex == 1 && $0.alignment == .center
        }
        let rightColumnApplied = alignedLayout.cells.contains {
            $0.columnIndex == 2 && $0.alignment == .right
        }
        return (compactWidthApplied, centerColumnApplied && rightColumnApplied)
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

    private static func configuredTextView(
        source: String,
        markerStyle: LivePreviewMarkerStyle
    ) -> NSTextView {
        let textView = MarkdownEditorTextViewFactory.makeTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 900, height: 1400)
        textView.textContainer?.containerSize = NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.string = source
        textView.setSelectedRange(NSRange(location: (source as NSString).length, length: 0))
        MarkdownVisibleRangeDecorator.decorateVisibleRange(
            in: textView,
            livePreviewMode: .livePreview,
            revealRange: textView.selectedRange(),
            markerStyle: markerStyle
        )
        return textView
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

    private static func lineFragmentRects(in textView: NSTextView, range: NSRange) -> [NSRect] {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return []
        }

        let stringLength = (textView.string as NSString).length
        let textRange = NSIntersectionRange(range, NSRange(location: 0, length: stringLength))
        guard textRange.length > 0 else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: textRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            return []
        }

        let origin = textView.textContainerOrigin
        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            guard NSIntersectionRange(lineGlyphRange, glyphRange).length > 0 else {
                return
            }
            rects.append(usedRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
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

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
