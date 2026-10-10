import XCTest
@testable import InkpegCore

final class StartupTests: XCTestCase {
    func testResourceCheckHasNoDataRoot() throws {
        XCTAssertEqual(try StartupOptions.parse(["--check-resources"]), StartupOptions(checkResources: true, developmentRoot: nil))
    }
    func testRejectsUnknownMissingRepeatedOrUnsafeArguments() {
        for args in [["--oops"], ["--data-root"], ["--data-root", "/Users/synthetic"], ["--data-root", "/tmp/inkpeg-dev/../other"], ["--check-resources", "--check-resources"]] {
            XCTAssertThrowsError(try StartupOptions.parse(args))
        }
    }
    func testExplicitDevelopmentRootIsIsolated() throws {
        let root = try StartupOptions.parse(["--data-root", "/tmp/inkpeg-dev/test-run"]).developmentRoot
        XCTAssertEqual(root?.lastPathComponent, "test-run")
    }
    func testAllLocaleFilesContainEveryKey() throws {
        try ResourceBundleLocator.validate(ResourceBundleLocator.bundledResources)
    }
    func testDevelopmentParentSymlinkCannotRedirectToUserDirectory() {
        XCTAssertThrowsError(try StartupOptions.validateDevelopmentRoot("/tmp/inkpeg-dev/run", resolve: { url in
            if url.path == "/tmp" { return URL(fileURLWithPath: "/private/tmp", isDirectory: true) }
            return URL(fileURLWithPath: url.path.replacingOccurrences(of: "/tmp/inkpeg-dev", with: "/Users/synthetic/Documents"), isDirectory: true)
        }))
    }
    func testDevelopmentRunSymlinkCannotRedirectToAnotherRun() {
        XCTAssertThrowsError(try StartupOptions.validateDevelopmentRoot("/tmp/inkpeg-dev/run", resolve: { url in
            URL(fileURLWithPath: url.path.replacingOccurrences(of: "/tmp", with: "/private/tmp").replacingOccurrences(of: "/run", with: "/other-run"), isDirectory: true)
        }))
    }

}
