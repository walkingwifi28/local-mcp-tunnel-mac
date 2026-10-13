import Foundation

enum ShellPathResolver {
    static func expandHomeVariables(_ value: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result = value.replacingOccurrences(of: "$HOME", with: home)
        if result == "~" {
            result = home
        } else if result.hasPrefix("~/") {
            result = home + String(result.dropFirst())
        }
        return result
    }

    static func expanded(_ value: String) -> String {
        (expandHomeVariables(value) as NSString).standardizingPath
    }

    static func resolveExecutable(_ value: String, environment: [String: String]) throws -> URL {
        let expandedValue = expanded(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !expandedValue.isEmpty else {
            throw ResolverError.emptyExecutable
        }

        if expandedValue.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: expandedValue) else {
                throw ResolverError.notExecutable(expandedValue)
            }
            return URL(fileURLWithPath: expandedValue)
        }

        // Prefer the official Homebrew installation for automatic tunnel-client lookup.
        // Explicit paths above continue to select the user's chosen executable.
        let homebrewPaths = expandedValue == "tunnel-client" ? [
            "/opt/homebrew/opt/tunnel-client/bin", "/opt/homebrew/bin",
            "/usr/local/opt/tunnel-client/bin", "/usr/local/bin"
        ] : []
        let pathEntries = homebrewPaths + augmentedPath(environment["PATH"]).split(separator: ":").map(String.init)
        for directory in pathEntries {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(expandedValue).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw ResolverError.commandNotFound(expandedValue)
    }

    static func augmentedEnvironment(apiKey: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = augmentedPath(environment["PATH"])
        if let apiKey, !apiKey.isEmpty {
            environment["CONTROL_PLANE_API_KEY"] = apiKey
        }
        return environment
    }

    private static func augmentedPath(_ currentPath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let common = [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = (currentPath ?? "").split(separator: ":").map(String.init)
        return Array(NSOrderedSet(array: common + existing)).compactMap { $0 as? String }.joined(separator: ":")
    }

    enum ResolverError: LocalizedError {
        case emptyExecutable
        case commandNotFound(String)
        case notExecutable(String)

        var errorDescription: String? {
            switch self {
            case .emptyExecutable:
                return "The executable file has not been set."
            case let .commandNotFound(command):
                if command == "tunnel-client" {
                    return "tunnel-client was not found. Install it with: brew install openai/tools/tunnel-client"
                }
                return "Command not found: \(command)"
            case let .notExecutable(path):
                return "Not an executable file: \(path)"
            }
        }
    }
}
