import AppKit
import NativeMarkdownCore

@MainActor
enum LivePreviewTheme {
    static let defaultFontSet = LivePreviewFontSet(
        baseFont: NSFont.systemFont(ofSize: 16, weight: .regular),
        sourceFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
        codeFont: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
        strongFont: NSFont.systemFont(ofSize: 16, weight: .bold),
        h1Font: NSFont.systemFont(ofSize: 28, weight: .bold),
        h2Font: NSFont.systemFont(ofSize: 23, weight: .bold),
        h3Font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        h4Font: NSFont.systemFont(ofSize: 18, weight: .semibold),
        h5Font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        h6Font: NSFont.systemFont(ofSize: 16, weight: .semibold)
    )
    static var baseFont: NSFont { defaultFontSet.baseFont }
    static var sourceFont: NSFont { defaultFontSet.sourceFont }
    static var codeFont: NSFont { defaultFontSet.codeFont }
    static var strongFont: NSFont { defaultFontSet.strongFont }
    static var h1Font: NSFont { defaultFontSet.h1Font }
    static var h2Font: NSFont { defaultFontSet.h2Font }
    static var h3Font: NSFont { defaultFontSet.h3Font }
    static var h4Font: NSFont { defaultFontSet.h4Font }
    static var h5Font: NSFont { defaultFontSet.h5Font }
    static var h6Font: NSFont { defaultFontSet.h6Font }

    static let textColor = NSColor.labelColor
    static let secondaryTextColor = NSColor.secondaryLabelColor
    static let linkColor = NSColor.linkColor
    static let missingLinkColor = NSColor.systemRed
    static let duplicateLinkColor = NSColor.systemOrange
    static let missingHeadingLinkColor = NSColor.systemPink
    static let tagColor = NSColor.systemPurple
    static let tagBackgroundColor = NSColor.systemPurple.withAlphaComponent(0.12)
    static let propertyBackgroundColor = NSColor.controlBackgroundColor
    static let propertyKeyColor = NSColor.secondaryLabelColor
    static let propertyValueColor = NSColor.labelColor
    static let propertyIconColor = NSColor.secondaryLabelColor.withAlphaComponent(0.82)
    static let embedBackgroundColor = NSColor.controlBackgroundColor
    static let embedImageColor = NSColor.systemGreen
    static let embedBlockedColor = NSColor.systemRed
    static let embedFallbackColor = NSColor.secondaryLabelColor
    static let tableHeaderBackgroundColor = NSColor.controlBackgroundColor
    static let tableCellBackgroundColor = NSColor.textBackgroundColor
    static let tableBorderColor = NSColor.separatorColor
    static let horizontalRuleColor = NSColor.separatorColor.withAlphaComponent(0.8)
    static let listGuideLineColor = NSColor.separatorColor.withAlphaComponent(0.72)
    static let codeColor = NSColor.systemBrown
    static let inlineCodeBackgroundColor = NSColor.controlBackgroundColor
    static let codeBlockBackgroundColor = NSColor.controlBackgroundColor
    static let codeCardBackgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.32)
    static let codeBadgeTextColor = NSColor.secondaryLabelColor
    static let codeSyntaxKeywordColor = NSColor.systemBlue
    static let codeSyntaxStringColor = NSColor.systemGreen
    static let codeSyntaxNumberColor = NSColor.systemOrange
    static let codeSyntaxCommentColor = NSColor.secondaryLabelColor
    static let codeSyntaxPropertyColor = NSColor.systemPurple
    static let codeSyntaxOperatorColor = NSColor.tertiaryLabelColor
    static let quoteColor = NSColor.secondaryLabelColor
    static let quoteBarColor = NSColor.systemGray
    static let calloutAccentColor = NSColor.systemBlue
    static let calloutBackgroundColor = NSColor.controlBackgroundColor
    static let listMarkerColor = NSColor.systemOrange
    static let concealedColor = NSColor.clear
    static let collapsedSyntaxFont = NSFont.systemFont(ofSize: 1, weight: .regular)
    static let propertyTitleLineHeight: CGFloat = 42
    static let propertyTitleParagraphSpacing: CGFloat = 18
    static let propertySectionLineHeight: CGFloat = 24
    static let propertySectionParagraphSpacing: CGFloat = 8
    static let propertyRowLineHeight: CGFloat = 28
    static let propertyRowParagraphSpacing: CGFloat = 4
    static let codeCardCornerRadius: CGFloat = 6
    static let codeCardHorizontalInset: CGFloat = 10
    static let codeCardVerticalInset: CGFloat = 7
    static let codeCardBorderWidth: CGFloat = 0
    static let codeBadgeInset: CGFloat = 8
    static let codeBadgeMaxWidth: CGFloat = 96

    static func headingFont(level: Int) -> NSFont {
        defaultFontSet.headingFont(level: level)
    }

    static func baseFont(scale: Double) -> NSFont {
        NSFont.systemFont(ofSize: scaled(16, scale: scale), weight: .regular)
    }

    static func sourceFont(scale: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: scaled(14, scale: scale), weight: .regular)
    }

    static func codeFont(scale: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: scaled(15, scale: scale), weight: .regular)
    }

    static func strongFont(scale: Double) -> NSFont {
        NSFont.systemFont(ofSize: scaled(16, scale: scale), weight: .bold)
    }

    static func headingFont(level: Int, scale: Double) -> NSFont {
        switch level {
        case 1:
            return NSFont.systemFont(ofSize: scaled(28, scale: scale), weight: .bold)
        case 2:
            return NSFont.systemFont(ofSize: scaled(23, scale: scale), weight: .bold)
        case 3:
            return NSFont.systemFont(ofSize: scaled(20, scale: scale), weight: .semibold)
        case 4:
            return NSFont.systemFont(ofSize: scaled(18, scale: scale), weight: .semibold)
        case 5:
            return NSFont.systemFont(ofSize: scaled(17, scale: scale), weight: .semibold)
        default:
            return NSFont.systemFont(ofSize: scaled(16, scale: scale), weight: .semibold)
        }
    }

    private static func normalizedScale(_ scale: Double) -> CGFloat {
        CGFloat(AppContentZoom(rawScale: scale).scale)
    }

    private static func scaled(_ value: CGFloat, scale: Double) -> CGFloat {
        value * normalizedScale(scale)
    }

    static func scaledCodeCardCornerRadius(scale: Double) -> CGFloat {
        scaled(codeCardCornerRadius, scale: scale)
    }

    static func scaledCodeCardHorizontalInset(scale: Double) -> CGFloat {
        scaled(codeCardHorizontalInset, scale: scale)
    }

    static func scaledCodeCardVerticalInset(scale: Double) -> CGFloat {
        scaled(codeCardVerticalInset, scale: scale)
    }

    static func scaledCodeCardBorderWidth(scale: Double) -> CGFloat {
        scaled(codeCardBorderWidth, scale: scale)
    }

    static func scaledCodeBadgeInset(scale: Double) -> CGFloat {
        scaled(codeBadgeInset, scale: scale)
    }

    static func scaledCodeBadgeMaxWidth(scale: Double) -> CGFloat {
        scaled(codeBadgeMaxWidth, scale: scale)
    }

    static func codeSyntaxColor(for kind: LivePreviewCodeFenceToken.Kind) -> NSColor {
        switch kind {
        case .keyword:
            codeSyntaxKeywordColor
        case .string:
            codeSyntaxStringColor
        case .number:
            codeSyntaxNumberColor
        case .comment:
            codeSyntaxCommentColor
        case .propertyKey:
            codeSyntaxPropertyColor
        case .operatorToken:
            codeSyntaxOperatorColor
        }
    }

    static var baseParagraphStyle: NSParagraphStyle {
        baseParagraphStyle(scale: 1.0)
    }

    static func baseParagraphStyle(scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.28
        style.paragraphSpacing = scaled(6, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static var collapsedSyntaxParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style.copy() as! NSParagraphStyle
    }

    static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        headingParagraphStyle(level: level, scale: 1.0)
    }

    static func headingParagraphStyle(level: Int, scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.paragraphSpacingBefore = scaled(level <= 2 ? 18 : 12, scale: scale)
        style.paragraphSpacing = scaled(level <= 2 ? 8 : 6, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static var codeBlockParagraphStyle: NSParagraphStyle {
        codeBlockParagraphStyle(scale: 1.0)
    }

    static func codeBlockParagraphStyle(scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.paragraphSpacingBefore = scaled(6, scale: scale)
        style.paragraphSpacing = scaled(6, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static var listParagraphStyle: NSParagraphStyle {
        listParagraphStyle(depth: 0)
    }

    static let listDepthIndentStep: CGFloat = 24
    static let listMarkerSlotWidth: CGFloat = 18

    static func listParagraphStyle(depth: Int) -> NSParagraphStyle {
        listParagraphStyle(depth: depth, scale: 1.0)
    }

    static func listParagraphStyle(depth: Int, scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        let indent = scaled(listMarkerSlotWidth, scale: scale)
            + CGFloat(max(0, depth)) * scaled(listDepthIndentStep, scale: scale)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.defaultTabInterval = 1
        style.tabStops = []
        style.paragraphSpacing = scaled(2, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static func listMarkerSlotRect(depth: Int, lineRect: NSRect) -> NSRect {
        listMarkerSlotRect(depth: depth, lineRect: lineRect, scale: 1.0)
    }

    static func listMarkerSlotRect(depth: Int, lineRect: NSRect, scale: Double) -> NSRect {
        NSRect(
            x: lineRect.minX + CGFloat(max(0, depth)) * scaled(listDepthIndentStep, scale: scale),
            y: lineRect.minY,
            width: scaled(listMarkerSlotWidth, scale: scale),
            height: lineRect.height
        )
    }

    static func listGuideX(depth: Int, lineRect: NSRect) -> CGFloat {
        listGuideX(depth: depth, lineRect: lineRect, scale: 1.0)
    }

    static func listGuideX(depth: Int, lineRect: NSRect, scale: Double) -> CGFloat {
        lineRect.minX
            + CGFloat(max(0, depth)) * scaled(listDepthIndentStep, scale: scale)
            - scaled(10, scale: scale)
    }

    static var quoteParagraphStyle: NSParagraphStyle {
        quoteParagraphStyle(scale: 1.0)
    }

    static func quoteParagraphStyle(scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.firstLineHeadIndent = 0
        style.headIndent = scaled(18, scale: scale)
        style.paragraphSpacing = scaled(4, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static var calloutParagraphStyle: NSParagraphStyle {
        calloutParagraphStyle(scale: 1.0)
    }

    static func calloutParagraphStyle(scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.firstLineHeadIndent = 0
        style.headIndent = scaled(20, scale: scale)
        style.paragraphSpacingBefore = scaled(4, scale: scale)
        style.paragraphSpacing = scaled(6, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static var propertyParagraphStyle: NSParagraphStyle {
        propertyRowParagraphStyle
    }

    static var propertyTitleParagraphStyle: NSParagraphStyle {
        propertyTitleParagraphStyle(scale: 1.0)
    }

    static func propertyTitleParagraphStyle(scale: Double) -> NSParagraphStyle {
        fixedLineParagraphStyle(
            lineHeight: scaled(propertyTitleLineHeight, scale: scale),
            paragraphSpacing: scaled(propertyTitleParagraphSpacing, scale: scale),
            scale: scale
        )
    }

    static var propertySectionParagraphStyle: NSParagraphStyle {
        propertySectionParagraphStyle(scale: 1.0)
    }

    static func propertySectionParagraphStyle(scale: Double) -> NSParagraphStyle {
        fixedLineParagraphStyle(
            lineHeight: scaled(propertySectionLineHeight, scale: scale),
            paragraphSpacing: scaled(propertySectionParagraphSpacing, scale: scale),
            scale: scale
        )
    }

    static var propertyRowParagraphStyle: NSParagraphStyle {
        propertyRowParagraphStyle(scale: 1.0)
    }

    static func propertyRowParagraphStyle(scale: Double) -> NSParagraphStyle {
        fixedLineParagraphStyle(
            lineHeight: scaled(propertyRowLineHeight, scale: scale),
            paragraphSpacing: scaled(propertyRowParagraphSpacing, scale: scale),
            scale: scale
        )
    }

    private static func fixedLineParagraphStyle(
        lineHeight: CGFloat,
        paragraphSpacing: CGFloat,
        scale: Double = 1.0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.firstLineHeadIndent = 0
        style.headIndent = scaled(18, scale: scale)
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = paragraphSpacing
        return style.copy() as! NSParagraphStyle
    }

    static var embedParagraphStyle: NSParagraphStyle {
        embedParagraphStyle(scale: 1.0)
    }

    static func embedParagraphStyle(scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.1
        style.firstLineHeadIndent = 0
        style.headIndent = scaled(18, scale: scale)
        style.paragraphSpacingBefore = scaled(4, scale: scale)
        style.paragraphSpacing = scaled(4, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static var tableParagraphStyle: NSParagraphStyle {
        tableParagraphStyle(scale: 1.0)
    }

    static func tableParagraphStyle(scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.08
        style.firstLineHeadIndent = 0
        style.headIndent = scaled(12, scale: scale)
        style.paragraphSpacingBefore = scaled(3, scale: scale)
        style.paragraphSpacing = scaled(3, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static var horizontalRuleParagraphStyle: NSParagraphStyle {
        horizontalRuleParagraphStyle(scale: 1.0)
    }

    static func horizontalRuleParagraphStyle(scale: Double) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = scaled(24, scale: scale)
        style.maximumLineHeight = scaled(24, scale: scale)
        style.firstLineHeadIndent = 0
        style.headIndent = 0
        style.paragraphSpacingBefore = scaled(6, scale: scale)
        style.paragraphSpacing = scaled(8, scale: scale)
        return style.copy() as! NSParagraphStyle
    }

    static func calloutAccentColor(for kind: LivePreviewBlockKind) -> NSColor {
        guard case .callout(let rawKind) = kind else {
            return calloutAccentColor
        }
        switch rawKind?.lowercased() {
        case "summary", "tldr", "abstract":
            return NSColor.systemTeal
        case "info", "todo":
            return NSColor.systemBlue
        case "success", "check", "done":
            return NSColor.systemGreen
        case "warning", "caution", "attention":
            return NSColor.systemOrange
        case "bug", "failure", "fail", "danger", "error":
            return NSColor.systemRed
        case "quote", "cite":
            return NSColor.systemGray
        default:
            return calloutAccentColor
        }
    }

    static func calloutBackgroundColor(for kind: LivePreviewBlockKind) -> NSColor {
        calloutAccentColor(for: kind).withAlphaComponent(0.12)
    }
}
