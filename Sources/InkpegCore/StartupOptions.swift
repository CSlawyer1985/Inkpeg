import Foundation

public struct StartupOptions: Equatable {
    public let checkResources: Bool
    public let developmentRoot: URL?
    public enum ArgumentError: Error { case invalid }
    public static func parse(_ arguments: [String]) throws -> StartupOptions {
        var check = false
        var root: URL?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--check-resources":
                guard !check else { throw ArgumentError.invalid }
                check = true
            case "--data-root":
                guard root == nil, index + 1 < arguments.count else { throw ArgumentError.invalid }
                index += 1
                root = try validateDevelopmentRoot(arguments[index], resolve: { $0.resolvingSymlinksInPath() })
            default: throw ArgumentError.invalid
            }
            index += 1
        }
        return StartupOptions(checkResources: check, developmentRoot: root)
    }
    // A resolver injection permits isolated symlink regression tests without
    // changing the real development root or any user's filesystem.
    static func validateDevelopmentRoot(_ value: String, resolve: (URL) -> URL) throws -> URL {
        let url = URL(fileURLWithPath: value, isDirectory: true)
        let temporaryRoot = resolve(URL(fileURLWithPath: "/tmp", isDirectory: true)).standardizedFileURL
        let prefix = temporaryRoot.appendingPathComponent("inkpeg-dev", isDirectory: true)
        let actualPrefix = resolve(URL(fileURLWithPath: "/tmp/inkpeg-dev", isDirectory: true)).standardizedFileURL
        let expected = prefix.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        let resolved = resolve(url).standardizedFileURL
        guard value.hasPrefix("/tmp/inkpeg-dev/"), !value.contains("/../"),
              actualPrefix.path == prefix.path,
              resolved.path == expected.path,
              resolved.deletingLastPathComponent().path == prefix.path,
              !resolved.lastPathComponent.isEmpty,
              resolved.lastPathComponent != ".", resolved.lastPathComponent != ".."
        else { throw ArgumentError.invalid }
        return resolved
    }

}
