import Foundation

public enum ResourceBundleLocator {
    public static var bundledResources: Bundle { Bundle.module }
    public enum ResourceError: Error { case missing, incomplete }
    public static func resolve(appBundle: Bundle) throws -> Bundle {
        let isApp = appBundle.bundleURL.pathExtension.lowercased() == "app"
            || appBundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
        if !isApp { return bundledResources }
        let expectedResources = appBundle.bundleURL.resolvingSymlinksInPath()
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let directory = appBundle.resourceURL,
              directory.resolvingSymlinksInPath().path == expectedResources.path,
              let bundle = Bundle(url: directory.appendingPathComponent("Inkpeg_InkpegCore.bundle")),
              bundle.bundleURL.resolvingSymlinksInPath().path == expectedResources.appendingPathComponent("Inkpeg_InkpegCore.bundle").path
        else { throw ResourceError.missing }
        try validate(bundle)
        return bundle
    }
    public static func validate(_ bundle: Bundle) throws {
        guard let resources = bundle.resourceURL,
              isUnredirectedChild(resources, of: bundle.bundleURL)
        else { throw ResourceError.incomplete }
        for code in ["en", "es", "zh-Hans"] {
            guard let folder = bundle.url(forResource: code, withExtension: "lproj"),
                  folder.standardizedFileURL.path == resources.appendingPathComponent(code + ".lproj").standardizedFileURL.path,
                  isUnredirectedChild(folder, of: bundle.bundleURL)
            else { throw ResourceError.incomplete }
            let strings = folder.appendingPathComponent("Localizable.strings")
            guard isUnredirectedChild(strings, of: bundle.bundleURL),
                  let data = try? Data(contentsOf: strings),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                  MessageKey.allCases.allSatisfy({ !(values[$0.rawValue] ?? "").isEmpty })
            else { throw ResourceError.incomplete }
        }
    }
    private static func isUnredirectedChild(_ child: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        if childPath == rootPath { return child.resolvingSymlinksInPath().path == canonicalRoot.path }
        guard childPath.hasPrefix(rootPath + "/") else { return false }
        let relative = String(childPath.dropFirst(rootPath.count + 1))
        return child.resolvingSymlinksInPath().standardizedFileURL.path == canonicalRoot.appendingPathComponent(relative).path
    }
}
