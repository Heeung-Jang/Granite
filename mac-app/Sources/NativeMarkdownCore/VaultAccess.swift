import Foundation

public enum VaultAccessIssue: Equatable {
    case denied(URL)
    case staleBookmark(URL)
    case missing(URL)
    case unmounted(URL)
    case readOnly(URL)

    public var url: URL {
        switch self {
        case .denied(let url),
             .staleBookmark(let url),
             .missing(let url),
             .unmounted(let url),
             .readOnly(let url):
            return url
        }
    }

    public var displayTitle: String {
        switch self {
        case .denied:
            return "Access Denied"
        case .staleBookmark:
            return "Reconnect Required"
        case .missing:
            return "Vault Missing"
        case .unmounted:
            return "Volume Unmounted"
        case .readOnly:
            return "Vault Read-Only"
        }
    }
}

public protocol VaultAccessValidating {
    func validateVault(at url: URL) -> VaultAccessIssue?
}

public struct FileSystemVaultAccessValidator: VaultAccessValidating {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validateVault(at url: URL) -> VaultAccessIssue? {
        if isUnmountedVolumePath(url) {
            return .unmounted(url)
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing(url)
        }

        guard fileManager.isReadableFile(atPath: url.path) else {
            return .denied(url)
        }

        guard fileManager.isWritableFile(atPath: url.path) else {
            return .readOnly(url)
        }

        return nil
    }

    private func isUnmountedVolumePath(_ url: URL) -> Bool {
        let pathComponents = url.standardizedFileURL.pathComponents
        guard pathComponents.count >= 3,
              pathComponents[0] == "/",
              pathComponents[1] == "Volumes"
        else {
            return false
        }

        let volumeRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(pathComponents[2], isDirectory: true)
        return !fileManager.fileExists(atPath: volumeRoot.path)
    }
}

