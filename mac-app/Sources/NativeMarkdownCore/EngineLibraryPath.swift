import Foundation

enum EngineLibraryPath {
    static let environmentKey = "VAULT_ENGINE_DYLIB_PATH"
    static let libraryName = "libvault_engine.dylib"

    static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledFrameworkPath: String? = Bundle.main.privateFrameworksURL?
            .appendingPathComponent(libraryName)
            .path,
        executableSiblingPath: String? = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(libraryName)
            .path
    ) -> String? {
        if let environmentPath = environment[environmentKey], !environmentPath.isEmpty {
            return environmentPath
        }
        if let bundledFrameworkPath, !bundledFrameworkPath.isEmpty {
            return bundledFrameworkPath
        }
        if let executableSiblingPath, !executableSiblingPath.isEmpty {
            return executableSiblingPath
        }
        return nil
    }

    static var missingMessage: String {
        "\(environmentKey) is not set and bundled \(libraryName) was not found"
    }
}
