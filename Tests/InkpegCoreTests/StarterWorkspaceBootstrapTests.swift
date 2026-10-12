import XCTest
@testable import InkpegCore

final class StarterWorkspaceBootstrapTests: XCTestCase {
    func fixture() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("inkpeg-starter-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let template = base.appendingPathComponent("template")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: repository.appendingPathComponent("packaging/starter-workspace"), to: template)
        return (base, template, base.appendingPathComponent("library"))
    }
    func testFreshRootGetsExactlyNoteImageAndPDF() async throws {
        let (_, template, root) = try fixture()
        XCTAssertTrue(try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root))
        let snapshot = try await MaterialStore(root: root).load()
        XCTAssertEqual(snapshot.materials.count, 3)
        XCTAssertEqual(Set(snapshot.materials.map(\.kind)), [.text, .image, .pdf])
        XCTAssertEqual(snapshot.materials.filter { $0.kind == .text }.first?.source.origin, .note)
        XCTAssertTrue(snapshot.materials.allSatisfy { $0.status == .hanging && $0.source.filePath == nil && $0.source.fileBookmark == nil })
    }
    func testExistingDirectoryNeverOverwrittenEvenWithoutState() throws {
        let (_, template, root) = try fixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sentinel = root.appendingPathComponent("user-content.txt")
        try Data("existing private content".utf8).write(to: sentinel)
        XCTAssertFalse(try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing private content".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
    func testTakingDownSamplesAndRestartingDoesNotRehang() async throws {
        let (_, template, root) = try fixture()
        _ = try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root)
        let store = MaterialStore(root: root), snapshot = try await store.load()
        for record in snapshot.materials { _ = try await store.apply(.takeDown(record.id)) }
        XCTAssertFalse(try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root))
        let restarted = try await MaterialStore(root: root).load()
        XCTAssertEqual(restarted.materials.filter { $0.status == .hanging }.count, 0)
    }
    func testFreshSamplesKeepClipboardIntakeDisabledAfterRestart() async throws {
        let (_, template, root) = try fixture()
        _ = try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root)
        let store = MaterialStore(root: root)
        let first = try await store.clipboardPreferences()
        XCTAssertFalse(first.enabled)
        XCTAssertFalse(first.includeExisting)
        let restarted = try await MaterialStore(root: root).clipboardPreferences()
        XCTAssertEqual(restarted, first)
    }
    func testCorruptPayloadRejectedBeforeRootCreated() throws {
        let (_, template, root) = try fixture()
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: template.appendingPathComponent("state.json")))
        try Data("corrupt".utf8).write(to: template.appendingPathComponent(snapshot.materials[0].versions[0].relativePath))
        XCTAssertThrowsError(try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testPayloadSymlinkRejected() throws {
        let (base, template, root) = try fixture()
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: template.appendingPathComponent("state.json")))
        let payload = template.appendingPathComponent(snapshot.materials[0].versions[0].relativePath)
        let kept = base.appendingPathComponent("kept-original")
        try FileManager.default.moveItem(at: payload, to: kept)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: kept)
        XCTAssertThrowsError(try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testPrivateSourcePathRejected() throws {
        let (_, template, root) = try fixture(), state = template.appendingPathComponent("state.json")
        var snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: state))
        snapshot.materials[0].source.filePath = "/private/synthetic/history.txt"
        try JSONEncoder().encode(snapshot).write(to: state)
        XCTAssertThrowsError(try StarterWorkspaceBootstrap.installIfAbsent(from: template, at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testTemplateSymlinkRejected() throws {
        let (base, template, root) = try fixture(), link = base.appendingPathComponent("template-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: template)
        XCTAssertThrowsError(try StarterWorkspaceBootstrap.installIfAbsent(from: link, at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testExistingWorkspaceDoesNotDependOnTemplateAvailability() throws {
        let (base, _, root) = try fixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertFalse(try StarterWorkspaceBootstrap.installIfAbsent(from: base.appendingPathComponent("missing"), at: root))
    }
}
