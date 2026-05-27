import AppKit
import NativeMarkdownCore

@MainActor
enum LivePreviewFontResolver {
    static func fontSet(for preferences: EditorFontPreferences) -> LivePreviewFontSet {
        let defaults = LivePreviewTheme.defaultFontSet
        let baseFont = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.baseFont,
            traits: [],
            weight: 5
        )
        let strongFont = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.strongFont,
            traits: .boldFontMask,
            weight: 9
        )
        let h1Font = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.h1Font,
            traits: .boldFontMask,
            weight: 9
        )
        let h2Font = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.h2Font,
            traits: .boldFontMask,
            weight: 9
        )
        let h3Font = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.h3Font,
            traits: .boldFontMask,
            weight: 8
        )
        let h4Font = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.h4Font,
            traits: .boldFontMask,
            weight: 8
        )
        let h5Font = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.h5Font,
            traits: .boldFontMask,
            weight: 8
        )
        let h6Font = resolvedFont(
            familyName: preferences.textFamilyName,
            defaultFont: defaults.h6Font,
            traits: .boldFontMask,
            weight: 8
        )

        let resolvedSourceFont = resolvedFont(
            familyName: preferences.monospaceFamilyName,
            defaultFont: defaults.sourceFont,
            traits: .fixedPitchFontMask,
            weight: 5
        )
        let resolvedCodeFont = resolvedFont(
            familyName: preferences.monospaceFamilyName,
            defaultFont: defaults.codeFont,
            traits: .fixedPitchFontMask,
            weight: 5
        )
        let monospaceFontsAreValid = preferences.monospaceFamilyName == nil
            || (isFixedPitch(resolvedSourceFont) && isFixedPitch(resolvedCodeFont))

        return LivePreviewFontSet(
            baseFont: baseFont,
            sourceFont: monospaceFontsAreValid ? resolvedSourceFont : defaults.sourceFont,
            codeFont: monospaceFontsAreValid ? resolvedCodeFont : defaults.codeFont,
            strongFont: strongFont,
            h1Font: h1Font,
            h2Font: h2Font,
            h3Font: h3Font,
            h4Font: h4Font,
            h5Font: h5Font,
            h6Font: h6Font
        )
    }

    static func isFixedPitch(_ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
    }

    private static func resolvedFont(
        familyName: String?,
        defaultFont: NSFont,
        traits: NSFontTraitMask,
        weight: Int
    ) -> NSFont {
        guard let familyName = normalizedFamilyName(familyName) else {
            return defaultFont
        }
        let manager = NSFontManager.shared
        if let resolved = manager.font(
            withFamily: familyName,
            traits: traits,
            weight: weight,
            size: defaultFont.pointSize
        ) {
            return resolved
        }
        if let fallbackFace = manager.font(
            withFamily: familyName,
            traits: [],
            weight: 5,
            size: defaultFont.pointSize
        ) {
            return fallbackFace
        }
        let converted = manager.convert(defaultFont, toFamily: familyName)
        if converted.familyName == familyName {
            return manager.convert(converted, toSize: defaultFont.pointSize)
        }
        return defaultFont
    }

    private static func normalizedFamilyName(_ familyName: String?) -> String? {
        guard let familyName else {
            return nil
        }
        let trimmed = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
