import XCTest
import AppKit
import InkpegCore
@testable import Inkpeg

final class LineVersionTests: XCTestCase {
    @MainActor
    func testRenderingOlderSnapshotKeepsCardURLAndVersionTogether() async throws {
        let folder = URL(fileURLWithPath: "/tmp/inkpeg-line-version-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("source.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        try png.write(to: source)
        let store = MaterialStore(root: folder.appendingPathComponent("owned")), line = Line(store: store)
        let previous = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 3).snapshot
        let original = try XCTUnwrap(previous.materials.first)
        let draft = try await store.createDerivedVersion(of: original.id, kind: .markup)
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        try await store.writeEditingResult(draft, data: gif)
        let current = try await store.finishEditing(draft, result: .save(draft.workingURL))
        XCTAssertNotEqual(current.materials.first?.activeVersionID, original.activeVersionID)
        // A delayed UI render must describe the exact snapshot it was given.
        await line.render(previous)
        let card = try XCTUnwrap(line.items.first)
        XCTAssertEqual(card.versionID, original.activeVersionID)
        XCTAssertEqual(card.url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: card.url), png)
        let unchanged = try await store.load()
        XCTAssertEqual(unchanged, current)
        XCTAssertEqual(try Data(contentsOf: source), png)
    }
}
