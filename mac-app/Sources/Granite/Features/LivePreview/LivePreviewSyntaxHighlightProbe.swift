import Foundation
import NativeMarkdownCore

struct LivePreviewSyntaxHighlightProbeReport: Codable, Equatable {
    var summary: ProbeCheckSummary
    var cases: [LivePreviewSyntaxHighlightProbeCase]
}

struct LivePreviewSyntaxHighlightProbeCase: Codable, Equatable {
    var id: String
    var language: String
    var codeUTF16Length: Int
    var tokenKinds: [String]
    var tokensInsideVisibleRange: Bool
    var expectedKindsPresent: Bool
    var passed: Bool
    var error: String?
}

enum LivePreviewSyntaxHighlightProbe {
    static func run() async -> LivePreviewSyntaxHighlightProbeReport {
        let cases: [LivePreviewSyntaxHighlightProbeCase]
        do {
            let client = try EngineSyntaxHighlightClient.loadDefault()
            var measuredCases: [LivePreviewSyntaxHighlightProbeCase] = []
            for fixture in fixtures() {
                measuredCases.append(await run(fixture: fixture, client: client))
            }
            cases = measuredCases
        } catch {
            cases = [
                LivePreviewSyntaxHighlightProbeCase(
                    id: "engine-load",
                    language: "",
                    codeUTF16Length: 0,
                    tokenKinds: [],
                    tokensInsideVisibleRange: false,
                    expectedKindsPresent: false,
                    passed: false,
                    error: String(describing: error)
                )
            ]
        }
        let failures = cases.filter { !$0.passed }.map(\.id).sorted()
        return LivePreviewSyntaxHighlightProbeReport(
            summary: ProbeCheckSummary(
                passed: failures.isEmpty,
                unexpectedFailures: failures,
                expectedFailures: []
            ),
            cases: cases
        )
    }

    static func encodedReport(_ report: LivePreviewSyntaxHighlightProbeReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func run(
        fixture: Fixture,
        client: EngineSyntaxHighlighting
    ) async -> LivePreviewSyntaxHighlightProbeCase {
        do {
            let visibleLength = fixture.visibleLength ?? UInt32((fixture.code as NSString).length)
            let result = try await client.highlight(
                requestID: fixture.requestID,
                language: fixture.language,
                code: fixture.code,
                visibleStartUTF16: fixture.visibleStart,
                visibleLengthUTF16: visibleLength
            )
            let kinds = result.tokens.map(\.kind)
            let expectedKindsPresent = fixture.expectedKinds.allSatisfy { expectedKind in
                kinds.contains(expectedKind)
            }
            let visibleRange = LivePreviewSourceRange(
                location: Int(fixture.visibleStart),
                length: Int(visibleLength)
            )
            let tokensInsideVisibleRange = result.tokens.allSatisfy {
                visibleRange.intersects($0.sourceRange)
            }
            return LivePreviewSyntaxHighlightProbeCase(
                id: fixture.id,
                language: fixture.language,
                codeUTF16Length: (fixture.code as NSString).length,
                tokenKinds: Array(Set(kinds.map(kindName))).sorted(),
                tokensInsideVisibleRange: tokensInsideVisibleRange,
                expectedKindsPresent: expectedKindsPresent,
                passed: result.requestID == fixture.requestID
                    && expectedKindsPresent
                    && tokensInsideVisibleRange,
                error: nil
            )
        } catch {
            return LivePreviewSyntaxHighlightProbeCase(
                id: fixture.id,
                language: fixture.language,
                codeUTF16Length: (fixture.code as NSString).length,
                tokenKinds: [],
                tokensInsideVisibleRange: false,
                expectedKindsPresent: false,
                passed: false,
                error: String(describing: error)
            )
        }
    }

    private static func fixtures() -> [Fixture] {
        [
            Fixture(
                id: "rust",
                requestID: 1,
                language: "rust",
                code: "fn main() {\n    let value = \"Granite\";\n}\n",
                expectedKinds: [.keyword, .string]
            ),
            Fixture(
                id: "javascript",
                requestID: 2,
                language: "javascript",
                code: "const name = \"Granite\";\nfunction openVault() { return name; }\n",
                expectedKinds: [.keyword, .string]
            ),
            Fixture(
                id: "python",
                requestID: 3,
                language: "python",
                code: "def summarize(note):\n    return \"Granite\"\n",
                expectedKinds: [.keyword, .string]
            ),
            Fixture(
                id: "yaml",
                requestID: 4,
                language: "yaml",
                code: "title: Granite\ncount: 3\n# local\n",
                expectedKinds: [.propertyKey, .number, .comment]
            ),
            Fixture(
                id: "visible-window",
                requestID: 5,
                language: "json",
                code: "{\n  \"hidden\": 1,\n  \"visible\": \"Granite\"\n}\n",
                visibleStart: 17,
                visibleLength: 24,
                expectedKinds: [.propertyKey, .string]
            )
        ]
    }

    private static func kindName(_ kind: LivePreviewCodeFenceToken.Kind) -> String {
        switch kind {
        case .keyword:
            return "keyword"
        case .string:
            return "string"
        case .number:
            return "number"
        case .comment:
            return "comment"
        case .propertyKey:
            return "propertyKey"
        case .operatorToken:
            return "operator"
        }
    }
}

private struct Fixture {
    var id: String
    var requestID: UInt64
    var language: String
    var code: String
    var visibleStart: UInt32 = 0
    var visibleLength: UInt32?
    var expectedKinds: [LivePreviewCodeFenceToken.Kind]
}
