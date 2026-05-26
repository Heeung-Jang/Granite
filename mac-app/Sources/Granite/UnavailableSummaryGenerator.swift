import Foundation
import NativeMarkdownCore

struct UnavailableSummaryGenerator: DocumentSummaryGenerating {
    let reason: SummaryUnavailableReason

    init(reason: SummaryUnavailableReason = .frameworkMissing) {
        self.reason = reason
    }

    func availability() async -> SummaryModelAvailability {
        .unavailable(reason)
    }

    func contextSize() async -> Int? {
        nil
    }

    func tokenCount(_ text: String) async throws -> Int {
        max(1, text.count / 4)
    }

    func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw SummaryGenerationError.unavailable(reason)
    }
}
