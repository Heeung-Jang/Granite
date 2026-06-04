import Foundation

public enum FrontmatterPropertySerializer {
    public static func propertyText(
        key: String,
        value: FilePropertyValue,
        newline: String = "\n"
    ) -> String {
        switch value {
        case .text(let text):
            return scalarPropertyText(key: key, value: text, newline: newline)
        case .number(let number):
            return rawScalarPropertyText(key: key, value: number, newline: newline)
        case .checkbox(let checked):
            return rawScalarPropertyText(key: key, value: checked ? "true" : "false", newline: newline)
        case .date(let date):
            return rawScalarPropertyText(key: key, value: date, newline: newline)
        case .dateTime(let dateTime):
            return rawScalarPropertyText(key: key, value: dateTime, newline: newline)
        case .list(let values):
            return listPropertyText(key: key, values: values, newline: newline)
        case .tags(let values):
            return listPropertyText(key: key, values: values.map(normalizedTag), newline: newline)
        }
    }

    static func scalarPropertyText(key: String, value: String, newline: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return "\(trimmedKey):\(newline)"
        }
        return "\(trimmedKey): \(escapedScalar(value))\(newline)"
    }

    static func rawScalarPropertyText(key: String, value: String, newline: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return "\(trimmedKey):\(newline)"
        }
        return "\(trimmedKey): \(value.trimmingCharacters(in: .whitespacesAndNewlines))\(newline)"
    }

    static func listPropertyText(key: String, values: [String], newline: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !values.isEmpty else {
            return "\(trimmedKey):\(newline)"
        }
        let rows = values
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "  - \(escapedScalar($0))" }
            .joined(separator: newline)
        guard !rows.isEmpty else {
            return "\(trimmedKey):\(newline)"
        }
        return "\(trimmedKey):\(newline)\(rows)\(newline)"
    }

    static func escapedScalar(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return #""""#
        }
        let needsQuoting = value.contains(":")
            || value.contains("\"")
            || value.contains("'")
            || value.hasPrefix("#")
            || value.hasPrefix("-")
            || value.hasPrefix("[")
            || value.hasPrefix("{")
            || value == "true"
            || value == "false"
        guard needsQuoting else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    static func normalizedTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }
}
