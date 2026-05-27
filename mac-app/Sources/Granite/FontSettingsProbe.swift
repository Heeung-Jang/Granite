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
            invalidMonospaceFallbackScenario(candidates.proportional),
            editorFontSettingsPersistenceScenario(candidates.proportional, candidates.fixedWidth),
            invalidMonospaceSelectionScenario(candidates.proportional, candidates.fixedWidth),
            fontPanelSelectionRoutingScenario(candidates.proportional, candidates.fixedWidth),
            fontPanelOwnershipScenario()
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

    private static func editorFontSettingsPersistenceScenario(
        _ textCandidate: FontCandidate?,
        _ monospaceCandidate: FontCandidate?
    ) -> FontSettingsProbeScenario {
        guard let textCandidate,
              let monospaceCandidate,
              let monospaceFont = regularFont(for: monospaceCandidate)
        else {
            return skip("editor-font-settings-persistence", reason: "No text or fixed-width family available.")
        }
        let suiteName = "FontSettingsProbe.persistence.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return skip("editor-font-settings-persistence", reason: "Could not create isolated defaults suite.")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsEditorFontPreferenceStore(defaults: defaults, keyPrefix: "probeFonts")
        let settings = EditorFontSettings(store: store)

        settings.setTextFontFamily("  \(textCandidate.familyName)  ")
        let textSaved = normalizedFamilyName(settings.preferences.textFamilyName) == textCandidate.normalizedFamilyName

        let monospaceAccepted = settings.selectMonospaceFont(monospaceFont)
        let monospaceSaved = normalizedFamilyName(settings.preferences.monospaceFamilyName)
            == normalizedFamilyName(monospaceFont.familyName)
        let reloaded = EditorFontSettings(store: store)
        let persisted = normalizedFamilyName(reloaded.preferences.textFamilyName) == textCandidate.normalizedFamilyName
            && normalizedFamilyName(reloaded.preferences.monospaceFamilyName)
                == normalizedFamilyName(monospaceFont.familyName)

        settings.resetTextFont()
        let resetTextOnly = settings.preferences.textFamilyName == nil
            && normalizedFamilyName(settings.preferences.monospaceFamilyName)
                == normalizedFamilyName(monospaceFont.familyName)
        settings.resetMonospaceFont()
        let resetBoth = settings.preferences == EditorFontPreferences()
        let resetPersisted = EditorFontSettings(store: store).preferences == EditorFontPreferences()

        return scenario(
            "editor-font-settings-persistence",
            passed: textSaved
                && monospaceAccepted
                && monospaceSaved
                && persisted
                && resetTextOnly
                && resetBoth
                && resetPersisted,
            details: [
                "textFamily": textCandidate.familyName,
                "monospaceFamily": monospaceFont.familyName ?? monospaceCandidate.familyName,
                "textSaved": String(textSaved),
                "monospaceAccepted": String(monospaceAccepted),
                "persisted": String(persisted),
                "resetTextOnly": String(resetTextOnly),
                "resetPersisted": String(resetPersisted)
            ]
        )
    }

    private static func invalidMonospaceSelectionScenario(
        _ proportionalCandidate: FontCandidate?,
        _ fixedWidthCandidate: FontCandidate?
    ) -> FontSettingsProbeScenario {
        guard let proportionalCandidate,
              let fixedWidthCandidate,
              let proportionalFont = regularFont(for: proportionalCandidate),
              let fixedWidthFont = regularFont(for: fixedWidthCandidate)
        else {
            return skip("invalid-monospace-selection", reason: "No proportional or fixed-width family available.")
        }
        let settings = EditorFontSettings(store: MemoryEditorFontPreferenceStore())

        let acceptedInitialFont = settings.selectMonospaceFont(fixedWidthFont)
        let previousMonospaceFamily = settings.preferences.monospaceFamilyName
        let rejectedProportionalFont = !settings.selectMonospaceFont(proportionalFont)
        let previousSelectionKept = normalizedFamilyName(settings.preferences.monospaceFamilyName)
            == normalizedFamilyName(previousMonospaceFamily)
        let warningShown = settings.monospaceWarningMessage == "Choose a fixed-width font for Monospace font."
        settings.clearMonospaceWarning()
        let warningCleared = settings.monospaceWarningMessage == nil

        return scenario(
            "invalid-monospace-selection",
            passed: acceptedInitialFont
                && rejectedProportionalFont
                && previousSelectionKept
                && warningShown
                && warningCleared,
            details: [
                "fixedWidthFamily": fixedWidthFont.familyName ?? fixedWidthCandidate.familyName,
                "rejectedFamily": proportionalFont.familyName ?? proportionalCandidate.familyName,
                "previousSelectionKept": String(previousSelectionKept),
                "warningShown": String(warningShown)
            ]
        )
    }

    private static func fontPanelSelectionRoutingScenario(
        _ textCandidate: FontCandidate?,
        _ monospaceCandidate: FontCandidate?
    ) -> FontSettingsProbeScenario {
        guard let textCandidate,
              let monospaceCandidate,
              let textFont = regularFont(for: textCandidate, size: 31),
              let monospaceFont = regularFont(for: monospaceCandidate, size: 29)
        else {
            return skip("font-panel-selection-routing", reason: "No text or fixed-width family available.")
        }

        let manager = NSFontManager.shared
        let previousTarget = manager.target
        let previousAction = manager.action
        let previousSelectedFont = manager.selectedFont
        let settings = EditorFontSettings(store: MemoryEditorFontPreferenceStore())
        let coordinator = FontPanelCoordinator()
        var activeRole = FontPreferenceRole.text
        defer {
            manager.target = previousTarget
            manager.action = previousAction
            if let previousSelectedFont {
                manager.setSelectedFont(previousSelectedFont, isMultiple: false)
            }
        }

        coordinator.editorFontSettings = settings
        coordinator.activeRole = { activeRole }
        coordinator.beginOwningFontPanel()

        manager.setSelectedFont(textFont, isMultiple: false)
        coordinator.changeFont(manager)
        let textRouted = normalizedFamilyName(settings.preferences.textFamilyName) == textCandidate.normalizedFamilyName
        let textSizeIgnored = settings.fontSet.baseFont.pointSize == LivePreviewTheme.defaultFontSet.baseFont.pointSize

        activeRole = .monospace
        manager.setSelectedFont(monospaceFont, isMultiple: false)
        coordinator.changeFont(manager)
        let monospaceRouted = normalizedFamilyName(settings.preferences.monospaceFamilyName)
            == normalizedFamilyName(monospaceFont.familyName)
        let monospaceSizeIgnored = settings.fontSet.codeFont.pointSize == LivePreviewTheme.defaultFontSet.codeFont.pointSize
            && settings.fontSet.sourceFont.pointSize == LivePreviewTheme.defaultFontSet.sourceFont.pointSize

        coordinator.clearFontPanelOwnershipIfCurrent()
        let ownershipRestored = target(manager.target, matches: previousTarget) && manager.action == previousAction

        return scenario(
            "font-panel-selection-routing",
            passed: textRouted
                && textSizeIgnored
                && monospaceRouted
                && monospaceSizeIgnored
                && ownershipRestored,
            details: [
                "textFamily": textFont.familyName ?? textCandidate.familyName,
                "monospaceFamily": monospaceFont.familyName ?? monospaceCandidate.familyName,
                "textRouted": String(textRouted),
                "textSizeIgnored": String(textSizeIgnored),
                "monospaceRouted": String(monospaceRouted),
                "monospaceSizeIgnored": String(monospaceSizeIgnored),
                "ownershipRestored": String(ownershipRestored)
            ]
        )
    }

    private static func fontPanelOwnershipScenario() -> FontSettingsProbeScenario {
        let manager = NSFontManager.shared
        let previousTarget = manager.target
        let previousAction = manager.action
        let owner = FontPanelCoordinator()
        let other = FontPanelCoordinator()
        let action = #selector(FontPanelCoordinator.changeFont(_:))
        defer {
            manager.target = previousTarget
            manager.action = previousAction
        }

        owner.beginOwningFontPanel()
        let ownershipStarted = manager.target === owner && manager.action == action

        other.clearFontPanelOwnershipIfCurrent()
        let nonOwnerDidNotClear = manager.target === owner && manager.action == action

        owner.clearFontPanelOwnershipIfCurrent()
        let ownerCleared = target(manager.target, matches: previousTarget) && manager.action == previousAction

        return scenario(
            "font-panel-target-action-lifecycle",
            passed: ownershipStarted && nonOwnerDidNotClear && ownerCleared,
            details: [
                "ownershipStarted": String(ownershipStarted),
                "nonOwnerDidNotClear": String(nonOwnerDidNotClear),
                "ownerCleared": String(ownerCleared)
            ]
        )
    }

    private static func target(_ lhs: AnyObject?, matches rhs: AnyObject?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs === rhs
        default:
            return false
        }
    }

    private static func regularFont(for candidate: FontCandidate, size: CGFloat = 16) -> NSFont? {
        NSFontManager.shared.font(
            withFamily: candidate.familyName,
            traits: [],
            weight: 5,
            size: size
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

private final class MemoryEditorFontPreferenceStore: EditorFontPreferenceStoring {
    private var preferences = EditorFontPreferences()

    func load() -> EditorFontPreferences {
        preferences
    }

    func saveTextFamilyName(_ familyName: String?) {
        preferences = EditorFontPreferences(
            textFamilyName: familyName,
            monospaceFamilyName: preferences.monospaceFamilyName
        )
    }

    func saveMonospaceFamilyName(_ familyName: String?) {
        preferences = EditorFontPreferences(
            textFamilyName: preferences.textFamilyName,
            monospaceFamilyName: familyName
        )
    }

    func resetTextFamilyName() {
        preferences = EditorFontPreferences(monospaceFamilyName: preferences.monospaceFamilyName)
    }

    func resetMonospaceFamilyName() {
        preferences = EditorFontPreferences(textFamilyName: preferences.textFamilyName)
    }
}
