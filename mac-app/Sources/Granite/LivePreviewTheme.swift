import AppKit
import NativeMarkdownCore

@MainActor
enum LivePreviewTheme {
    static let baseFont = NSFont.systemFont(ofSize: 16, weight: .regular)
    static let sourceFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let strongFont = NSFont.systemFont(ofSize: 16, weight: .bold)
    static let h1Font = NSFont.systemFont(ofSize: 28, weight: .bold)
    static let h2Font = NSFont.systemFont(ofSize: 23, weight: .bold)
    static let h3Font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    static let h4Font = NSFont.systemFont(ofSize: 18, weight: .semibold)
    static let h5Font = NSFont.systemFont(ofSize: 17, weight: .semibold)
    static let h6Font = NSFont.systemFont(ofSize: 16, weight: .semibold)

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
    static let codeColor = NSColor.systemBrown
    static let inlineCodeBackgroundColor = NSColor.controlBackgroundColor
    static let codeBlockBackgroundColor = NSColor.controlBackgroundColor
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

    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1:
            return h1Font
        case 2:
            return h2Font
        case 3:
            return h3Font
        case 4:
            return h4Font
        case 5:
            return h5Font
        default:
            return h6Font
        }
    }

    static var baseParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.28
        style.paragraphSpacing = 6
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
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.paragraphSpacingBefore = level <= 2 ? 18 : 12
        style.paragraphSpacing = level <= 2 ? 8 : 6
        return style.copy() as! NSParagraphStyle
    }

    static var codeBlockParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 6
        return style.copy() as! NSParagraphStyle
    }

    static var listParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.firstLineHeadIndent = 0
        style.headIndent = 18
        style.paragraphSpacing = 2
        return style.copy() as! NSParagraphStyle
    }

    static var quoteParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.firstLineHeadIndent = 0
        style.headIndent = 18
        style.paragraphSpacing = 4
        return style.copy() as! NSParagraphStyle
    }

    static var calloutParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.12
        style.firstLineHeadIndent = 0
        style.headIndent = 20
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 6
        return style.copy() as! NSParagraphStyle
    }

    static var propertyParagraphStyle: NSParagraphStyle {
        propertyRowParagraphStyle
    }

    static var propertyTitleParagraphStyle: NSParagraphStyle {
        fixedLineParagraphStyle(
            lineHeight: propertyTitleLineHeight,
            paragraphSpacing: propertyTitleParagraphSpacing
        )
    }

    static var propertySectionParagraphStyle: NSParagraphStyle {
        fixedLineParagraphStyle(
            lineHeight: propertySectionLineHeight,
            paragraphSpacing: propertySectionParagraphSpacing
        )
    }

    static var propertyRowParagraphStyle: NSParagraphStyle {
        fixedLineParagraphStyle(
            lineHeight: propertyRowLineHeight,
            paragraphSpacing: propertyRowParagraphSpacing
        )
    }

    private static func fixedLineParagraphStyle(lineHeight: CGFloat, paragraphSpacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.firstLineHeadIndent = 0
        style.headIndent = 18
        style.paragraphSpacingBefore = 0
        style.paragraphSpacing = paragraphSpacing
        return style.copy() as! NSParagraphStyle
    }

    static var embedParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.1
        style.firstLineHeadIndent = 0
        style.headIndent = 18
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 4
        return style.copy() as! NSParagraphStyle
    }

    static var tableParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.08
        style.firstLineHeadIndent = 0
        style.headIndent = 12
        style.paragraphSpacingBefore = 3
        style.paragraphSpacing = 3
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
