import XCTest
import Darwin
@testable import InkpegCore

final class StoreBenchmarkTests: XCTestCase {
    func testTwentyHundredAndTwoHundredSyntheticImages() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKklEQVR4nGOQL11KU8QwasGoBaMWjFowasGoBaMWjFowasGoBaMWDBULAPDL5D2WoNdOAAAAAElFTkSuQmCC"))
        var rows = [[String: Any]]()
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-benchmark-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for count in [20, 100, 200] {
            let base = output.appendingPathComponent(String(count), isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let root = base.appendingPathComponent("owned", isDirectory: true)
            let store = MaterialStore(root: root)
            let started = Date()
            var state = WorkspaceSnapshot()
            for index in 0..<count {
                let source = base.appendingPathComponent("synthetic-" + String(index) + ".png")
                try png.write(to: source)
                state = try await store.importMaterial(.file(source, .screenshot), into: MatterGroup.ungroupedID, visibleCapacity: 12).snapshot
                XCTAssertEqual(try Data(contentsOf: source), png)
            }
            XCTAssertEqual(state.materials.count, count)
            XCTAssertTrue(state.materials.allSatisfy { $0.kind == .image })
            let seconds = Date().timeIntervalSince(started)
            let written = try retainedSize(root)
            var info = mach_task_basic_info()
            var length = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(length)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &length)
                }
            }
            XCTAssertEqual(result, KERN_SUCCESS)
            rows.append(["images": count, "source_bytes_each": png.count, "seconds": seconds, "retained_bytes": written, "test_process_peak_resident_bytes": info.resident_size_max])
        }
        let report = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: output.appendingPathComponent("metrics.json"))
        print("INKPEG_BENCHMARK_REPORT " + output.appendingPathComponent("metrics.json").path)
    }
    private func retainedSize(_ root: URL) throws -> Int {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

}
