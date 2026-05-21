import Foundation

struct ProbeCheckSummary: Codable, Equatable {
    var passed: Bool
    var unexpectedFailures: [String]
    var expectedFailures: [String]

    static let passed = ProbeCheckSummary(
        passed: true,
        unexpectedFailures: [],
        expectedFailures: []
    )

    static func evaluate(report: Any, expectedFailures: Set<String> = []) -> ProbeCheckSummary {
        let checks = Mirror(reflecting: report).children.compactMap { child -> (String, Bool)? in
            guard let label = child.label,
                  let value = child.value as? Bool
            else {
                return nil
            }
            return (label, value)
        }
        let failed = checks
            .filter { !$0.1 }
            .map(\.0)
            .sorted()
        let expected = failed
            .filter { expectedFailures.contains($0) }
            .sorted()
        let unexpected = failed
            .filter { !expectedFailures.contains($0) }
            .sorted()

        return ProbeCheckSummary(
            passed: unexpected.isEmpty,
            unexpectedFailures: unexpected,
            expectedFailures: expected
        )
    }
}
