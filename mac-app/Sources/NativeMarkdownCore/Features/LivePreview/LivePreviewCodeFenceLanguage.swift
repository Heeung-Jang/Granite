import Foundation

public struct LivePreviewCodeFenceLanguage: Equatable, Sendable {
    public enum HighlightMode: String, Equatable, Sendable {
        case yaml
        case java
        case swift
        case rust
        case json
        case bash
        case sql
        case javascript
        case typescript
        case python
        case html
        case css
        case markdown
        case text
        case unsupported
    }

    public static let maxDisplayLabelLength = 24

    public var rawInfo: String?
    public var displayName: String?
    public var highlightMode: HighlightMode

    public init(info: String?) {
        self.rawInfo = info
        let token = Self.primaryToken(from: info)
        guard let token else {
            self.displayName = nil
            self.highlightMode = .text
            return
        }

        self.highlightMode = Self.mode(for: token)
        self.displayName = Self.displayName(for: token, mode: highlightMode)
    }

    private static func primaryToken(from info: String?) -> String? {
        guard let trimmed = info?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
    }

    private static func mode(for token: String) -> HighlightMode {
        switch token.lowercased() {
        case "yaml", "yml":
            .yaml
        case "java":
            .java
        case "swift":
            .swift
        case "rust", "rs":
            .rust
        case "json":
            .json
        case "bash", "sh", "shell":
            .bash
        case "sql":
            .sql
        case "javascript", "js":
            .javascript
        case "typescript", "ts":
            .typescript
        case "python", "py":
            .python
        case "html":
            .html
        case "css":
            .css
        case "markdown", "md":
            .markdown
        case "text", "txt", "plain":
            .text
        default:
            .unsupported
        }
    }

    private static func displayName(for token: String, mode: HighlightMode) -> String? {
        switch mode {
        case .yaml:
            return "YAML"
        case .java:
            return "Java"
        case .swift:
            return "Swift"
        case .rust:
            return "Rust"
        case .json:
            return "JSON"
        case .bash:
            return "Bash"
        case .sql:
            return "SQL"
        case .javascript:
            return "JavaScript"
        case .typescript:
            return "TypeScript"
        case .python:
            return "Python"
        case .html:
            return "HTML"
        case .css:
            return "CSS"
        case .markdown:
            return "Markdown"
        case .text:
            return nil
        case .unsupported:
            return capped(token)
        }
    }

    private static func capped(_ token: String) -> String {
        guard token.count > maxDisplayLabelLength else {
            return token
        }
        let endIndex = token.index(token.startIndex, offsetBy: maxDisplayLabelLength - 1)
        return String(token[..<endIndex]) + "…"
    }
}
