import AppKit
import Foundation
import NativeMarkdownCore

struct FontSettingsProbeReport: Codable, Equatable {
    var summary: FontSettingsProbeSummary
    var scenarios: [FontSettingsProbeScenario]
}

struct FontSettingsProbeSummary: Codable, Equatable {
    var passed: Bool
    var failedScenarioNames: [String]
    var skippedScenarioNames: [String]
}

struct FontSettingsProbeScenario: Codable, Equatable {
    var name: String
    var passed: Bool
    var skipped: Bool
    var reason: String?
    var details: [String: String]
}

@MainActor
enum FontSettingsProbe {
    static func encodedReport(_ report: FontSettingsProbeReport = run()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    static func run() -> FontSettingsProbeReport {
        let candidates = installedCandidates()
        let scenarios = [
            defaultFamilyScenario(),
            defaultPointSizeScenario(),
            proportionalDiscoveryScenario(candidates.proportional),
            fixedWidthDiscoveryScenario(candidates.fixedWidth),
            customTextFamilyScenario(candidates.proportional),
            customMonospaceFamilyScenario(candidates.fixedWidth),
            invalidMonospaceFallbackScenario(candidates.proportional)
        ]
        return FontSettingsProbeReport(
            summary: summary(for: scenarios),
            scenarios: scenarios
        )
    }

    private static func defaultFamilyScenario() -> FontSettingsProbeScenario {
        let fontSet = LivePreviewFontResolver.fontSet(for: EditorFontPreferences())
        return pass(
            "default-font-families",
            details: [
                "base": fontSet.baseFont.familyName ?? fontSet.baseFont.fontName,
                "source": fontSet.sourceFont.familyName ?? fontSet.sourceFont.fontName,
                "code": fontSet.codeFont.familyName ?? fontSet.codeFont.fontName
            ]
        )
    }

    private static func defaultPointSizeScenario() -> FontSettingsProbeScenario {
        let defaults = LivePreviewTheme.defaultFontSet
        let resolved = LivePreviewFontResolver.fontSet(for: EditorFontPreferences())
        let checks = [
            fontsMatch(defaults.baseFont, resolved.baseFont),
            fontsMatch(defaults.sourceFont, resolved.sourceFont),
            fontsMatch(defaults.codeFont, resolved.codeFont),
            fontsMatch(defaults.strongFont, resolved.strongFont),
            fontsMatch(defaults.h1Font, resolved.h1Font),
            fontsMatch(defaults.h2Font, resolved.h2Font),
            fontsMatch(defaults.h3Font, resolved.h3Font),
            fontsMatch(defaults.h4Font, resolved.h4Font),
            fontsMatch(defaults.h5Font, resolved.h5Font),
            fontsMatch(defaults.h6Font, resolved.h6Font)
        ]
        return scenario(
            "default-point-sizes",
            passed: checks.allSatisfy { $0 },
            details: [
                "base": sizePair(defaults.baseFont, resolved.baseFont),
                "source": sizePair(defaults.sourceFont, resolved.sourceFont),
                "code": sizePair(defaults.codeFont, resolved.codeFont),
                "h1": sizePair(defaults.h1Font, resolved.h1Font),
                "h6": sizePair(defaults.h6Font, resolved.h6Font)
            ]
        )
    }

    private static func proportionalDiscoveryScenario(_ candidate: FontCandidate?) -> FontSettingsProbeScenario {
        guard let candidate else {
            return skip("installed-proportional-family", reason: "No alternate proportional family found.")
        }
        return pass("installed-proportional-family", details: ["family": candidate.familyName])
    }

    private static func fixedWidthDiscoveryScenario(_ candidate: FontCandidate?) -> FontSettingsProbeScenario {
        guard let candidate else {
            return skip("installed-fixed-width-family", reason: "No alternate fixed-width family found.")
        }
        return pass("installed-fixed-width-family", details: ["family": candidate.familyName])
    }

    private static func customTextFamilyScenario(_ candidate: FontCandidate?) -> FontSettingsProbeScenario {
        guard let candidate else {
            return skip("custom-text-family-resolution", reason: "No proportional family available.")
        }
        let resolved = LivePreviewFontResolver.fontSet(for: EditorFontPreferences(textFamilyName: candidate.familyName))
        let textFonts = [
            resolved.baseFont,
            resolved.strongFont,
            resolved.h1Font,
            resolved.h2Font,
            resolved.h3Font,
            resolved.h4Font,
            resolved.h5Font,
            resolved.h6Font
        ]
        return scenario(
            "custom-text-family-resolution",
            passed: textFonts.allSatisfy { normalizedFamilyName($0.familyName) == candidate.normalizedFamilyName },
            details: [
                "requested": candidate.familyName,
                "base": resolved.baseFont.familyName ?? resolved.baseFont.fontName,
                "strong": resolved.strongFont.familyName ?? resolved.strongFont.fontName,
                "h1": resolved.h1Font.familyName ?? resolved.h1Font.fontName
            ]
        )
    }

    private static func customMonospaceFamilyScenario(_ candidate: FontCandidate?) -> FontSettingsProbeScenario {
        guard let candidate else {
            return skip("custom-monospace-family-resolution", reason: "No fixed-width family available.")
        }
        let resolved = LivePreviewFontResolver.fontSet(for: EditorFontPreferences(monospaceFamilyName: candidate.familyName))
        return scenario(
            "custom-monospace-family-resolution",
            passed: LivePreviewFontResolver.isFixedPitch(resolved.sourceFont)
                && LivePreviewFontResolver.isFixedPitch(resolved.codeFont),
            details: [
                "requested": candidate.familyName,
                "source": resolved.sourceFont.familyName ?? resolved.sourceFont.fontName,
                "code": resolved.codeFont.familyName ?? resolved.codeFont.fontName
            ]
        )
    }

    private static func invalidMonospaceFallbackScenario(_ candidate: FontCandidate?) -> FontSettingsProbeScenario {
        guard let candidate else {
            return skip("invalid-monospace-fallback", reason: "No proportional family available.")
        }
        let defaults = LivePreviewTheme.defaultFontSet
        let resolved = LivePreviewFontResolver.fontSet(for: EditorFontPreferences(monospaceFamilyName: candidate.familyName))
        return scenario(
            "invalid-monospace-fallback",
            passed: fontsMatch(defaults.sourceFont, resolved.sourceFont)
                && fontsMatch(defaults.codeFont, resolved.codeFont),
            details: [
                "requested": candidate.familyName,
                "source": resolved.sourceFont.familyName ?? resolved.sourceFont.fontName,
                "code": resolved.codeFont.familyName ?? resolved.codeFont.fontName
            ]
        )
    }

    private static func installedCandidates() -> (proportional: FontCandidate?, fixedWidth: FontCandidate?) {
        let manager = NSFontManager.shared
        let defaultTextFamily = normalizedFamilyName(LivePreviewTheme.defaultFontSet.baseFont.familyName)
        let defaultMonospaceFamily = normalizedFamilyName(LivePreviewTheme.defaultFontSet.codeFont.familyName)
        var proportional: FontCandidate?
        var fixedWidth: FontCandidate?

        for family in manager.availableFontFamilies.sorted() {
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 16),
                  let familyName = normalizedFamilyName(font.familyName ?? family)
            else {
                continue
            }
            let candidate = FontCandidate(familyName: font.familyName ?? family)
            if proportional == nil,
               familyName != defaultTextFamily,
               !LivePreviewFontResolver.isFixedPitch(font) {
                proportional = candidate
            }
            if fixedWidth == nil,
               familyName != defaultMonospaceFamily,
               LivePreviewFontResolver.isFixedPitch(font) {
                fixedWidth = candidate
            }
            if proportional != nil && fixedWidth != nil {
                break
            }
        }

        return (proportional, fixedWidth)
    }

    private static func summary(for scenarios: [FontSettingsProbeScenario]) -> FontSettingsProbeSummary {
        let failed = scenarios.filter { !$0.passed && !$0.skipped }.map(\.name)
        let skipped = scenarios.filter(\.skipped).map(\.name)
        return FontSettingsProbeSummary(
            passed: failed.isEmpty,
            failedScenarioNames: failed,
            skippedScenarioNames: skipped
        )
    }

    private static func pass(
        _ name: String,
        details: [String: String] = [:]
    ) -> FontSettingsProbeScenario {
        scenario(name, passed: true, details: details)
    }

    private static func skip(_ name: String, reason: String) -> FontSettingsProbeScenario {
        FontSettingsProbeScenario(
            name: name,
            passed: true,
            skipped: true,
            reason: reason,
            details: [:]
        )
    }

    private static func scenario(
        _ name: String,
        passed: Bool,
        details: [String: String] = [:]
    ) -> FontSettingsProbeScenario {
        FontSettingsProbeScenario(
            name: name,
            passed: passed,
            skipped: false,
            reason: passed ? nil : "Scenario assertion failed.",
            details: details
        )
    }

    private static func fontsMatch(_ lhs: NSFont, _ rhs: NSFont) -> Bool {
        lhs.fontName == rhs.fontName && lhs.pointSize == rhs.pointSize
    }

    private static func sizePair(_ lhs: NSFont, _ rhs: NSFont) -> String {
        "\(lhs.pointSize):\(rhs.pointSize)"
    }

    private static func normalizedFamilyName(_ familyName: String?) -> String? {
        guard let familyName else {
            return nil
        }
        let trimmed = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}

private struct FontCandidate {
    var familyName: String

    var normalizedFamilyName: String? {
        let trimmed = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}
