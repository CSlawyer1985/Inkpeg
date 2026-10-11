import XCTest
@testable import InkpegCore

final class TextFileFidelityTests: XCTestCase {
    func testImportedTextFormatsRetainBytesExtensionAndSourceAcrossEdits() async throws {
        let samples = [
            ("md", "# 原文\r\n\r\n- 条目\r\n", "# 编辑\n正文\n"),
            ("csv", "name,value\r\n\"甲,乙\",001\r\n", "name,value\n甲,002\n"),
            ("json", "{ \"value\": 1, \"label\": \"甲\" }\n", "{\"value\":2, \"label\":\"乙\"}\n"),
            ("log", "2026-10-10 INFO  first\n  continuation\n", "2026-10-10 WARN  changed\n"),
            ("MD", "# Uppercase extension\n", "# Edited uppercase\n")
        ]
        for (suffix, originalText, editedText) in samples {
            let root = URL(fileURLWithPath: "/tmp/inkpeg-text-fidelity-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("原始资料." + suffix), originalBytes = Data(originalText.utf8)
            try originalBytes.write(to: source)
            let store = MaterialStore(root: root.appendingPathComponent("owned"))
            let imported = try await store.importMaterial(.file(source, .fileSelection), into: MatterGroup.ungroupedID, visibleCapacity: 8)
            let record = try XCTUnwrap(imported.snapshot.materials.first)
            XCTAssertEqual(record.kind, .text)
            let original = try await store.payloadURL(of: record.id, versionID: record.originalVersionID)
            XCTAssertEqual(original.pathExtension, suffix)
            XCTAssertEqual(try Data(contentsOf: original), originalBytes)
            let session = try await store.createDerivedVersion(of: record.id, kind: .textEdit)
            XCTAssertEqual(session.baseVersionID, record.originalVersionID)
            XCTAssertEqual(session.workingURL.pathExtension, suffix)
            let editedBytes = Data(editedText.utf8)
            try await store.writeEditingResult(session, data: editedBytes)
            let edited = try await store.finishEditing(session, result: .save(session.workingURL))
            let updated = try XCTUnwrap(edited.materials.first)
            XCTAssertEqual(updated.versions.count, 2)
            XCTAssertEqual(updated.originalVersionID, record.originalVersionID)
            XCTAssertEqual(updated.activeVersion?.kind, .textEdit)
            XCTAssertEqual(updated.source, record.source)
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            XCTAssertEqual(try Data(contentsOf: original), originalBytes)
            let payload = try await store.payloadURL(of: record.id)
            XCTAssertEqual(payload.pathExtension, suffix)
            XCTAssertEqual(try Data(contentsOf: payload), editedBytes)
            let name = ContentStore.suggestedExportFilename(for: updated, fileExtension: payload.pathExtension)
            XCTAssertEqual(name, source.lastPathComponent)
            let destination = root.appendingPathComponent("export").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await store.exportCopy(of: record.id, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), editedBytes)
            let originalExport = root.appendingPathComponent("original-export").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: originalExport.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await store.exportCopy(of: record.id, versionID: record.originalVersionID, to: originalExport)
            XCTAssertEqual(try Data(contentsOf: originalExport), originalBytes)
        }
    }

    func testDirectClipboardAndNotesRemainTXTWithoutUsingMultilineTitleAsFilename() async throws {
        for origin in [ImportOrigin.clipboard, .note] {
            let root = URL(fileURLWithPath: "/tmp/inkpeg-text-fidelity-" + UUID().uuidString), store = MaterialStore(root: root)
            let text = "../../outside.md\n完整文字\n第三行"
            let imported = try await store.importMaterial(.text(text, SourceRecord(origin: origin)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
            let record = try XCTUnwrap(imported.snapshot.materials.first)
            let payload = try await store.payloadURL(of: record.id)
            XCTAssertEqual(payload.pathExtension, "txt")
            XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), text)
            XCTAssertEqual(ContentStore.suggestedExportFilename(for: record, fileExtension: payload.pathExtension), "Inkpeg-" + record.id.uuidString.prefix(8) + ".txt")
        }
    }

    func testSuggestedNameUsesOnlySafeSourceBasenameAndVerifiedPayloadExtension() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-text-fidelity-" + UUID().uuidString), store = MaterialStore(root: root)
        let imported = try await store.importMaterial(.text("synthetic", SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        var record = try XCTUnwrap(imported.snapshot.materials.first)
        record.title = "../../title\nnever use this"
        record.source.filePath = "/external/../../folder/report:bad\\name\n.md"
        let name = ContentStore.suggestedExportFilename(for: record, fileExtension: "md")
        XCTAssertEqual(name, "report_bad_name_.md")
        XCTAssertFalse(name.contains("/")); XCTAssertFalse(name.contains("\\")); XCTAssertFalse(name.contains(":")); XCTAssertFalse(name.contains("\n"))
        let folder = root.appendingPathComponent("Exports/run")
        XCTAssertEqual(folder.appendingPathComponent(name).deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        record.source.filePath = "/external/.."
        XCTAssertEqual(ContentStore.suggestedExportFilename(for: record, fileExtension: "txt"), "Inkpeg-" + record.id.uuidString.prefix(8) + ".txt")
        record.source.filePath = ""
        XCTAssertEqual(ContentStore.suggestedExportFilename(for: record, fileExtension: "txt"), "Inkpeg-" + record.id.uuidString.prefix(8) + ".txt")
        record.source.filePath = "/external/actual.png"
        XCTAssertEqual(ContentStore.suggestedExportFilename(for: record, fileExtension: "gif"), "actual.gif")
    }
}
