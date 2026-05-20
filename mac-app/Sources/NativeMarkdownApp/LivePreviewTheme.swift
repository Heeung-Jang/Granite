import AppKit

@MainActor
enum LivePreviewTheme {
    static let baseFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    static let sourceFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let strongFont = NSFont.systemFont(ofSize: 14, weight: .bold)
    static let h1Font = NSFont.systemFont(ofSize: 24, weight: .bold)
    static let h2Font = NSFont.systemFont(ofSize: 20, weight: .bold)
    static let h3Font = NSFont.systemFont(ofSize: 18, weight: .semibold)
    static let h4Font = NSFont.systemFont(ofSize: 16, weight: .semibold)
    static let h5Font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let h6Font = NSFont.systemFont(ofSize: 14, weight: .semibold)

    static let textColor = NSColor.labelColor
    static let secondaryTextColor = NSColor.secondaryLabelColor
    static let linkColor = NSColor.linkColor
    static let tagColor = NSColor.systemPurple
    static let codeColor = NSColor.systemBrown
    static let inlineCodeBackgroundColor = NSColor.controlBackgroundColor
    static let codeBlockBackgroundColor = NSColor.controlBackgroundColor
    static let quoteColor = NSColor.secondaryLabelColor
    static let quoteBarColor = NSColor.systemGray
    static let calloutAccentColor = NSColor.systemBlue
    static let calloutBackgroundColor = NSColor.controlBackgroundColor
    static let listMarkerColor = NSColor.systemOrange
    static let concealedColor = NSColor.clear

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
        style.lineHeightMultiple = 1.16
        style.paragraphSpacing = 4
        return style.copy() as! NSParagraphStyle
    }

    static func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.04
        style.paragraphSpacingBefore = level <= 2 ? 10 : 8
        style.paragraphSpacing = level <= 2 ? 7 : 5
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
}
