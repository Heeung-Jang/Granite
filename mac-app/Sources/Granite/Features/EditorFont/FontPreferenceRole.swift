enum FontPreferenceRole {
    case text
    case monospace

    var displayLabel: String {
        switch self {
        case .text:
            return "Text font"
        case .monospace:
            return "Monospace font"
        }
    }

    var chooseAccessibilityLabel: String {
        switch self {
        case .text:
            return "Choose text font"
        case .monospace:
            return "Choose monospace font"
        }
    }

    var resetAccessibilityLabel: String {
        switch self {
        case .text:
            return "Reset text font"
        case .monospace:
            return "Reset monospace font"
        }
    }

    var warningAccessibilityLabel: String {
        switch self {
        case .text:
            return "Text font warning"
        case .monospace:
            return "Monospace font warning"
        }
    }
}
