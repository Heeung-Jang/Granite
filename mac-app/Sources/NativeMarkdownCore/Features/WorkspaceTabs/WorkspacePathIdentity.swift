import Foundation

public enum WorkspacePathIdentity {
    public static func canonicalRelativePath(_ relativePath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\0")
        else {
            return nil
        }

        var components: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                return nil
            default:
                components.append(String(component))
            }
        }

        guard !components.isEmpty else {
            return nil
        }
        return components.joined(separator: "/")
    }

    public static func key(for item: FileTreeItem) -> String? {
        canonicalRelativePath(item.relativePath)
    }
}
