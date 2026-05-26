import Foundation
import NativeMarkdownCore

enum SummaryGeneratorFactory {
    static func make() -> any DocumentSummaryGenerating {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsSummaryGenerator()
        }
        return UnavailableSummaryGenerator(reason: .osUnsupported)
        #else
        return UnavailableSummaryGenerator(reason: .frameworkMissing)
        #endif
    }
}
