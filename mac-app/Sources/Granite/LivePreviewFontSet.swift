import AppKit
import NativeMarkdownCore

@MainActor
struct LivePreviewFontSet {
    let baseFont: NSFont
    let sourceFont: NSFont
    let codeFont: NSFont
    let strongFont: NSFont
    let h1Font: NSFont
    let h2Font: NSFont
    let h3Font: NSFont
    let h4Font: NSFont
    let h5Font: NSFont
    let h6Font: NSFont

    func headingFont(level: Int) -> NSFont {
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

    func scaled(by scale: Double) -> LivePreviewFontSet {
        let normalizedScale = AppContentZoom(rawScale: scale).scale
        guard normalizedScale != AppContentZoom.defaultScale else {
            return self
        }
        return LivePreviewFontSet(
            baseFont: scaled(baseFont, by: normalizedScale),
            sourceFont: scaled(sourceFont, by: normalizedScale),
            codeFont: scaled(codeFont, by: normalizedScale),
            strongFont: scaled(strongFont, by: normalizedScale),
            h1Font: scaled(h1Font, by: normalizedScale),
            h2Font: scaled(h2Font, by: normalizedScale),
            h3Font: scaled(h3Font, by: normalizedScale),
            h4Font: scaled(h4Font, by: normalizedScale),
            h5Font: scaled(h5Font, by: normalizedScale),
            h6Font: scaled(h6Font, by: normalizedScale)
        )
    }

    private func scaled(_ font: NSFont, by scale: Double) -> NSFont {
        NSFontManager.shared.convert(font, toSize: font.pointSize * CGFloat(scale))
    }
}
