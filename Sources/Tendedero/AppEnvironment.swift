import Foundation
import InkpegCore

struct AppEnvironment {
    let checkResources: Bool
    let dataRoot: URL
    static func parse(_ arguments: [String]) throws -> AppEnvironment {
        let options = try StartupOptions.parse(arguments)
        let root = options.developmentRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Inkpeg", isDirectory: true)
        return AppEnvironment(checkResources: options.checkResources, dataRoot: root)
    }
}
