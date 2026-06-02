import Foundation

public struct VaultNameSuggestion {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func suggestedNoteName(in parentURL: URL) -> String {
        suggestedName(base: "Untitled", extension: "md", in: parentURL, isDirectory: false)
    }

    public func suggestedFolderName(in parentURL: URL) -> String {
        suggestedName(base: "Untitled folder", extension: nil, in: parentURL, isDirectory: true)
    }

    private func suggestedName(
        base: String,
        extension pathExtension: String?,
        in parentURL: URL,
        isDirectory: Bool
    ) -> String {
        for index in 0... {
            let stem = index == 0 ? base : "\(base) \(index)"
            let name = pathExtension.map { "\(stem).\($0)" } ?? stem
            let url = parentURL.appendingPathComponent(name, isDirectory: isDirectory)
            if !fileManager.fileExists(atPath: url.path) {
                return name
            }
        }
        return pathExtension.map { "\(base).\($0)" } ?? base
    }
}
