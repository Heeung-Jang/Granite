import Foundation

public struct LivePreviewCodeFenceToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyword
        case string
        case number
        case comment
        case propertyKey
        case operatorToken
    }

    public var kind: Kind
    public var sourceRange: LivePreviewSourceRange

    public init(kind: Kind, sourceRange: LivePreviewSourceRange) {
        self.kind = kind
        self.sourceRange = sourceRange
    }
}

public struct LivePreviewCodeFenceHighlightResult: Equatable, Sendable {
    public var tokens: [LivePreviewCodeFenceToken]
    public var scannedUTF16Length: Int

    public init(tokens: [LivePreviewCodeFenceToken], scannedUTF16Length: Int) {
        self.tokens = tokens
        self.scannedUTF16Length = scannedUTF16Length
    }
}

public enum LivePreviewCodeFenceSyntaxHighlighter {
    public static func highlight(
        source: String,
        block: LivePreviewBlockSpan,
        visibleRange: LivePreviewSourceRange
    ) -> LivePreviewCodeFenceHighlightResult {
        guard case .fencedCode(_, let info, _) = block.kind,
              let contentRange = LivePreviewCodeFenceContentRange.contentRange(for: block, in: source)
        else {
            return LivePreviewCodeFenceHighlightResult(tokens: [], scannedUTF16Length: 0)
        }

        let scanRange = intersection(contentRange, visibleRange)
        guard scanRange.length > 0,
              let stringRange = LivePreviewRangeMapper.stringRange(for: scanRange, in: source)
        else {
            return LivePreviewCodeFenceHighlightResult(tokens: [], scannedUTF16Length: 0)
        }

        let language = LivePreviewCodeFenceLanguage(info: info)
        let segment = String(source[stringRange])
        let tokens = tokens(
            in: segment,
            baseLocation: scanRange.location,
            mode: language.highlightMode
        )
        return LivePreviewCodeFenceHighlightResult(tokens: tokens, scannedUTF16Length: scanRange.length)
    }

    private static func tokens(
        in segment: String,
        baseLocation: Int,
        mode: LivePreviewCodeFenceLanguage.HighlightMode
    ) -> [LivePreviewCodeFenceToken] {
        switch mode {
        case .yaml:
            yamlTokens(in: segment, baseLocation: baseLocation)
        case .json:
            jsonTokens(in: segment, baseLocation: baseLocation)
        case .java:
            cLikeTokens(in: segment, baseLocation: baseLocation, keywords: javaKeywords)
        case .swift:
            cLikeTokens(in: segment, baseLocation: baseLocation, keywords: swiftKeywords)
        case .rust:
            cLikeTokens(in: segment, baseLocation: baseLocation, keywords: rustKeywords)
        case .bash:
            bashTokens(in: segment, baseLocation: baseLocation)
        case .sql:
            sqlTokens(in: segment, baseLocation: baseLocation)
        case .javascript, .typescript, .python, .html, .css, .markdown, .text, .unsupported:
            []
        }
    }

    private static func yamlTokens(in segment: String, baseLocation: Int) -> [LivePreviewCodeFenceToken] {
        var tokens = regexTokens(in: segment, baseLocation: baseLocation, regex: yamlKeyRegex, kind: .propertyKey, captureGroup: 1)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: commentHashRegex, kind: .comment)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: stringRegex, kind: .string)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: numberRegex, kind: .number)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: yamlKeywordRegex, kind: .keyword)
        return sorted(tokens)
    }

    private static func jsonTokens(in segment: String, baseLocation: Int) -> [LivePreviewCodeFenceToken] {
        var tokens = regexTokens(in: segment, baseLocation: baseLocation, regex: stringRegex, kind: .string)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: numberRegex, kind: .number)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: jsonKeywordRegex, kind: .keyword)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: jsonPunctuationRegex, kind: .operatorToken)
        return sorted(tokens)
    }

    private static func cLikeTokens(
        in segment: String,
        baseLocation: Int,
        keywords: Set<String>
    ) -> [LivePreviewCodeFenceToken] {
        var tokens = regexTokens(in: segment, baseLocation: baseLocation, regex: slashCommentRegex, kind: .comment)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: blockCommentRegex, kind: .comment)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: stringRegex, kind: .string)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: numberRegex, kind: .number)
        tokens += wordTokens(in: segment, baseLocation: baseLocation, words: keywords, kind: .keyword)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: operatorRegex, kind: .operatorToken)
        return sorted(tokens)
    }

    private static func bashTokens(in segment: String, baseLocation: Int) -> [LivePreviewCodeFenceToken] {
        var tokens = regexTokens(in: segment, baseLocation: baseLocation, regex: commentHashRegex, kind: .comment)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: stringRegex, kind: .string)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: shellVariableRegex, kind: .propertyKey)
        tokens += wordTokens(in: segment, baseLocation: baseLocation, words: bashKeywords, kind: .keyword)
        return sorted(tokens)
    }

    private static func sqlTokens(in segment: String, baseLocation: Int) -> [LivePreviewCodeFenceToken] {
        var tokens = regexTokens(in: segment, baseLocation: baseLocation, regex: sqlCommentRegex, kind: .comment)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: sqlStringRegex, kind: .string)
        tokens += regexTokens(in: segment, baseLocation: baseLocation, regex: numberRegex, kind: .number)
        tokens += wordTokens(in: segment, baseLocation: baseLocation, words: sqlKeywords, kind: .keyword, caseInsensitive: true)
        return sorted(tokens)
    }

    private static func wordTokens(
        in segment: String,
        baseLocation: Int,
        words: Set<String>,
        kind: LivePreviewCodeFenceToken.Kind,
        caseInsensitive: Bool = false
    ) -> [LivePreviewCodeFenceToken] {
        let nsSegment = segment as NSString
        let matches = wordRegex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))
        return matches.compactMap { match in
            let value = nsSegment.substring(with: match.range)
            let key = caseInsensitive ? value.lowercased() : value
            guard words.contains(key) else {
                return nil
            }
            return token(kind: kind, localRange: match.range, baseLocation: baseLocation)
        }
    }

    private static func regexTokens(
        in segment: String,
        baseLocation: Int,
        regex: NSRegularExpression,
        kind: LivePreviewCodeFenceToken.Kind,
        captureGroup: Int = 0
    ) -> [LivePreviewCodeFenceToken] {
        let nsSegment = segment as NSString
        let matches = regex.matches(in: segment, range: NSRange(location: 0, length: nsSegment.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > captureGroup else {
                return nil
            }
            let range = match.range(at: captureGroup)
            guard range.location != NSNotFound, range.length > 0 else {
                return nil
            }
            return token(kind: kind, localRange: range, baseLocation: baseLocation)
        }
    }

    private static func token(
        kind: LivePreviewCodeFenceToken.Kind,
        localRange: NSRange,
        baseLocation: Int
    ) -> LivePreviewCodeFenceToken {
        LivePreviewCodeFenceToken(
            kind: kind,
            sourceRange: LivePreviewSourceRange(location: baseLocation + localRange.location, length: localRange.length)
        )
    }

    private static func sorted(_ tokens: [LivePreviewCodeFenceToken]) -> [LivePreviewCodeFenceToken] {
        tokens.sorted {
            if $0.sourceRange.location == $1.sourceRange.location {
                return $0.sourceRange.length < $1.sourceRange.length
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
    }

    private static func intersection(
        _ lhs: LivePreviewSourceRange,
        _ rhs: LivePreviewSourceRange
    ) -> LivePreviewSourceRange {
        let lower = max(lhs.location, rhs.location)
        let upper = min(lhs.endLocation, rhs.endLocation)
        return LivePreviewSourceRange(location: lower, length: max(0, upper - lower))
    }

    private static let javaKeywords: Set<String> = [
        "abstract", "class", "extends", "final", "if", "import", "int", "new", "private",
        "protected", "public", "return", "static", "String", "void"
    ]
    private static let swiftKeywords: Set<String> = [
        "actor", "class", "enum", "extension", "func", "if", "import", "let", "private",
        "public", "return", "static", "struct", "var"
    ]
    private static let rustKeywords: Set<String> = [
        "async", "enum", "fn", "if", "impl", "let", "match", "mod", "mut", "pub", "return",
        "struct", "trait", "use"
    ]
    private static let bashKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in",
        "then", "while"
    ]
    private static let sqlKeywords: Set<String> = [
        "and", "as", "by", "delete", "from", "group", "insert", "into", "join", "limit",
        "not", "null", "or", "order", "select", "set", "update", "values", "where"
    ]

    private static let yamlKeyRegex = regex(#"(?m)^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:"#)
    private static let yamlKeywordRegex = regex(#"\b(true|false|null)\b"#, options: [.caseInsensitive])
    private static let jsonKeywordRegex = regex(#"\b(true|false|null)\b"#)
    private static let jsonPunctuationRegex = regex(#"[{}\[\]:,]"#)
    private static let slashCommentRegex = regex(#"//[^\n\r]*"#)
    private static let blockCommentRegex = regex(#"/\*[\s\S]*?\*/"#)
    private static let commentHashRegex = regex(#"(?m)#.*$"#)
    private static let sqlCommentRegex = regex(#"(?m)--.*$"#)
    private static let stringRegex = regex(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    private static let sqlStringRegex = regex(#"'(?:''|[^'])*'"#)
    private static let numberRegex = regex(#"\b\d+(?:\.\d+)?\b"#)
    private static let shellVariableRegex = regex(#"\$[A-Za-z_][A-Za-z0-9_]*"#)
    private static let operatorRegex = regex(#"[=+\-*/<>!&|]+"#)
    private static let wordRegex = regex(#"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    private static func regex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
}
