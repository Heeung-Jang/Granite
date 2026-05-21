import Foundation

enum LivePreviewMarkerStyle: String, CaseIterable, Identifiable {
    case obsidian
    case accent
    case muted
    case hidden

    static let storageKey = "LivePreviewMarkerStyle"
    static let defaultValue: LivePreviewMarkerStyle = .obsidian

    var id: String {
        rawValue
    }

    var menuTitle: String {
        switch self {
        case .obsidian:
            return "Obsidian"
        case .accent:
            return "Accent Markers"
        case .muted:
            return "Muted Markers"
        case .hidden:
            return "Hidden Markers"
        }
    }

    var showsBlockMarkersOutsideReveal: Bool {
        self != .hidden
    }
}
