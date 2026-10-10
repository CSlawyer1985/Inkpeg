import XCTest
import AppKit
import InkpegCore
import UniformTypeIdentifiers
@testable import Inkpeg

final class NativePromiseTests: XCTestCase {
    @MainActor
    func testPromiseKeepsDelegateAndExactPNGVersionAfterMarkup() async throws {
        let folder = URL(fileURLWithPath: "/tmp/inkpeg-native-promise-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        let source = folder.appendingPathComponent("source.png")
        try png.write(to: source)
        let store = MaterialStore(root: folder.appendingPathComponent("owned"))
        let imported = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(imported.snapshot.materials.first)
        weak var retainedDelegate: CopyOutProvider?
        let provider = autoreleasepool {
            let adapter = CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "png", canExport: { true })
            retainedDelegate = adapter
            return adapter.provider()
        }
        XCTAssertNotNil(retainedDelegate, "The promise must retain its otherwise weak delegate until delivery")
        XCTAssertEqual(provider.fileType, UTType.png.identifier)
        let delegate = try XCTUnwrap(provider.delegate)
        let name = delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
        XCTAssertTrue(name.hasSuffix(".png"))
        let session = try await store.createDerivedVersion(of: record.id, kind: .markup)
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        try await store.writeEditingResult(session, data: gif)
        let edited = try await store.finishEditing(session, result: .save(session.workingURL))
        XCTAssertTrue(edited.materials.first?.activeVersion?.relativePath.hasSuffix(".gif") == true)
        let destination = folder.appendingPathComponent(name)
        let failure = await deliver(provider, to: destination)
        XCTAssertNil(failure)
        XCTAssertEqual(try Data(contentsOf: destination), png)
        XCTAssertEqual(try Data(contentsOf: source), png)
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, edited, "Delivering a promise must leave the hanging card and versions unchanged")
    }

    @MainActor
    func testPromiseFailureDoesNotOverwriteDestinationOrReportSuccess() async throws {
        let folder = URL(fileURLWithPath: "/tmp/inkpeg-native-promise-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = MaterialStore(root: folder.appendingPathComponent("owned"))
        let result = try await store.importMaterial(.text("synthetic text", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(result.snapshot.materials.first)
        let provider = CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "txt", canExport: { true }).provider()
        let destination = folder.appendingPathComponent("existing.txt"), original = Data("keep existing".utf8)
        try original.write(to: destination)
        let failure = await deliver(provider, to: destination)
        XCTAssertNotNil(failure)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, result.snapshot)
    }

    @MainActor
    func testPrivacyChangeBeforePromiseDeliveryRejectsExport() async throws {
        let folder = URL(fileURLWithPath: "/tmp/inkpeg-native-promise-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = MaterialStore(root: folder.appendingPathComponent("owned"))
        let result = try await store.importMaterial(.text("synthetic text", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 3)
        let record = try XCTUnwrap(result.snapshot.materials.first)
        var visible = true
        let provider = CopyOutProvider(store: store, id: record.id, versionID: record.activeVersionID, suffix: "txt", canExport: { visible }).provider()
        visible = false
        let destination = folder.appendingPathComponent("hidden.txt")
        let failure = await deliver(provider, to: destination)
        XCTAssertEqual(failure as? StoreError, .invalidSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    private func deliver(_ provider: NSFilePromiseProvider, to destination: URL) async -> Error? {
        guard let delegate = provider.delegate else { return StoreError.invalidSource }
        return await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { continuation.resume(returning: $0) }
        }
    }
}
