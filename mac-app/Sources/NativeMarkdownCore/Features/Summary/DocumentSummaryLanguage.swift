import Foundation

public enum DocumentSummaryLanguageDetector {
    public static func detect(_ source: String) -> SummaryLanguage {
        var korean = 0
        var latin = 0
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7AF, 0x3130...0x318F:
                korean += 1
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            default:
                continue
            }
        }

        if korean > 0 && latin > 0 {
            return .mixedKoreanEnglish
        }
        if korean > 0 {
            return .korean
        }
        if latin > 0 {
            return .english
        }
        return .other
    }
}
