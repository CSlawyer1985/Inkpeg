import XCTest
@testable import InkpegCore
final class ResourceBoundaryTests: XCTestCase {
 func app(_ ext: String) throws -> URL {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-audit-fixture-" + UUID().uuidString)
  let app = root.appendingPathComponent("Inkpeg." + ext)
  try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
  let plist: [String:Any] = ["CFBundleIdentifier":"local.inkpeg.audit", "CFBundlePackageType":"APPL", "CFBundleExecutable":"Inkpeg", "CFBundleName":"Inkpeg"]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
  return app
 }
 func testUppercaseAppCannotFallbackToBuildResources() throws {
  let path = try app("APP")
  let bundle = try XCTUnwrap(Bundle(url: path))
  XCTAssertThrowsError(try ResourceBundleLocator.resolve(appBundle: bundle))
 }
 func testAppResourceDirectoryCannotEscapeCurrentApp() throws {
  let path = try app("app")
  let external = path.deletingLastPathComponent().appendingPathComponent("external-resources")
  try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
  try FileManager.default.copyItem(at: ResourceBundleLocator.bundledResources.bundleURL, to: external.appendingPathComponent("Inkpeg_InkpegCore.bundle"))
  try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("Contents/Resources"), withDestinationURL: external)
  XCTAssertThrowsError(try ResourceBundleLocator.resolve(appBundle: XCTUnwrap(Bundle(url:path))))
 }
 func isolatedResourceBundle() throws -> Bundle {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-resource-boundary-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let copy = root.appendingPathComponent("Resources.bundle")
  try FileManager.default.copyItem(at: ResourceBundleLocator.bundledResources.bundleURL, to: copy)
  return try XCTUnwrap(Bundle(url: copy))
 }
 func testLocaleDirectoryCannotEscapeResourceBundle() throws {
  let bundle = try isolatedResourceBundle()
  let locale = try XCTUnwrap(bundle.url(forResource: "zh-Hans", withExtension: "lproj"))
  let external = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("external-locale")
  try FileManager.default.moveItem(at: locale, to: external)
  try FileManager.default.createSymbolicLink(at: locale, withDestinationURL: external)
  XCTAssertThrowsError(try ResourceBundleLocator.validate(bundle))
 }
 func testStringsFileCannotEscapeResourceBundle() throws {
  let bundle = try isolatedResourceBundle()
  let locale = try XCTUnwrap(bundle.url(forResource: "zh-Hans", withExtension: "lproj"))
  let strings = locale.appendingPathComponent("Localizable.strings")
  let external = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("external.strings")
  try FileManager.default.moveItem(at: strings, to: external)
  try FileManager.default.createSymbolicLink(at: strings, withDestinationURL: external)
  XCTAssertThrowsError(try ResourceBundleLocator.validate(bundle))
 }

}
