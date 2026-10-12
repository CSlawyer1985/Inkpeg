import AppKit
import InkpegCore

// Validate arguments and packaged resources before creating AppKit or user data.
do {
    let environment = try AppEnvironment.parse(Array(CommandLine.arguments.dropFirst()))
    let resources = try ResourceBundleLocator.resolve(appBundle: .main)
    try ResourceBundleLocator.validate(resources)
    appLocalizer = Localizer(bundle: resources)
    let template = Bundle.main.resourceURL?.appendingPathComponent("StarterWorkspace")
    if environment.checkResources {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let template else { throw StoreError.invalidSource }
            _ = try StarterWorkspaceBootstrap.validate(template)
        }
        print("Inkpeg resources OK: en, es, zh-Hans")
    } else {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let template else { throw StoreError.invalidSource }
            _ = try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: environment.dataRoot)
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate(environment: environment)
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { app.run() }
        }
    }
} catch {
    // Do not print arguments or paths, which may contain sensitive material.
    FileHandle.standardError.write(Data("Inkpeg: invalid arguments or missing resources\n".utf8))
    exit(2)
}
