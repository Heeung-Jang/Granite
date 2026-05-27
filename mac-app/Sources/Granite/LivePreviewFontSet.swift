import AppKit

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
}
