import Foundation

public enum FilePropertyType: String, CaseIterable, Codable, Equatable, Sendable {
    case text
    case list
    case number
    case checkbox
    case date
    case dateTime
    case tags

    public var label: String {
        switch self {
        case .text:
            "Text"
        case .list:
            "List"
        case .number:
            "Number"
        case .checkbox:
            "Checkbox"
        case .date:
            "Date"
        case .dateTime:
            "Date & time"
        case .tags:
            "Tags"
        }
    }

    public static func defaultType(for propertyName: String) -> FilePropertyType? {
        switch propertyName.lowercased() {
        case "tags":
            .tags
        case "aliases", "cssclasses":
            .list
        default:
            nil
        }
    }
}

public enum FilePropertyValue: Equatable, Sendable {
    case text(String)
    case list([String])
    case number(String)
    case checkbox(Bool)
    case date(String)
    case dateTime(String)
    case tags([String])

    public var type: FilePropertyType {
        switch self {
        case .text:
            .text
        case .list:
            .list
        case .number:
            .number
        case .checkbox:
            .checkbox
        case .date:
            .date
        case .dateTime:
            .dateTime
        case .tags:
            .tags
        }
    }
}

public enum FilePropertyFocusedField: Equatable, Sendable {
    case name
    case value
}

public struct SourceTextReplacement: Equatable {
    public var range: Range<String.Index>
    public var text: String

    public init(range: Range<String.Index>, text: String) {
        self.range = range
        self.text = text
    }
}

public struct SourceFocusTarget: Equatable, Sendable {
    public var range: LivePreviewSourceRange
    public var preferredField: FilePropertyFocusedField

    public init(range: LivePreviewSourceRange, preferredField: FilePropertyFocusedField) {
        self.range = range
        self.preferredField = preferredField
    }
}

public enum FrontmatterEditPlan: Equatable {
    case replaceText(replacement: SourceTextReplacement, focus: SourceFocusTarget?)
    case duplicateKey(existingKey: String, focus: SourceFocusTarget)
    case complexValueRequiresSourceMode(key: String, focus: SourceFocusTarget?)
    case noOp
}
