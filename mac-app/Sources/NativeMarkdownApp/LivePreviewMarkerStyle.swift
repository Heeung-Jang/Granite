import Foundation

enum LivePreviewMarkerStyle: String, CaseIterable, Identifiable {
    case accent
    case muted
    case hidden

    static let storageKey = "LivePreviewMarkerStyle"
    static let defaultValue: LivePreviewMarkerStyle = .accent

    var id: String {
        rawValue
    }

    var menuTitle: String {
        switch self {
        case .accent:
            return "Accent #/-"
        case .muted:
            return "Muted #/-"
        case .hidden:
            return "Hidden"
        }
    }

    var showsBlockMarkersOutsideReveal: Bool {
        self != .hidden
    }
}
