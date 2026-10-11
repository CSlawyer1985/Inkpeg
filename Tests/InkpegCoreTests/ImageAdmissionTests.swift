import XCTest
import ImageIO
@testable import InkpegCore

final class ImageAdmissionTests: XCTestCase {
    static func fixture(_ height: Int = 4097) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/image-budget-8192x\(height).png"))
    }

    func testTinyEncodedOversizeIsRejectedByImageDataAndAllFileOriginsWithoutChangingOriginal() async throws {
        let data = try Self.fixture()
        XCTAssertEqual(data.count, 4149)
        let root = URL(fileURLWithPath: "/tmp/inkpeg-image-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("encoded.bin")
        try data.write(to: original)
        for request in [ImportRequest.imageData(data, SourceRecord(origin: .clipboard)),
                        .file(original, .drop), .file(original, .fileSelection), .file(original, .screenshot), .file(original, .clipboard)] {
            let store = MaterialStore(root: root.appendingPathComponent(UUID().uuidString))
            do {
                _ = try await store.importMaterial(request, into: MatterGroup.ungroupedID, visibleCapacity: 8)
                XCTFail("8192 × 4097 must be rejected before full decoding, including detected images in .bin files")
            } catch { XCTAssertEqual(error as? ImageAdmissionError, .pixelBudgetExceeded) }
            let saved = try await store.load()
            XCTAssertTrue(saved.materials.isEmpty)
            XCTAssertEqual(try Data(contentsOf: original), data)
        }
    }

    func testMetadataDataAndURLAdmissionAtExactPixelBoundary() async throws {
        let data = try Self.fixture(4096)
        try ImageAdmission.validate(data)
        try ImageAdmission.validate(width: 8192, height: 4096)
        let root = URL(fileURLWithPath: "/tmp/inkpeg-image-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("boundary.png"); try data.write(to: source)
        try ImageAdmission.validate(contentsOf: source)
        let store = MaterialStore(root: root.appendingPathComponent("owned"))
        let saved = try await store.importMaterial(.file(source, .drop), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        XCTAssertEqual(saved.snapshot.materials.first?.kind, .image)
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testOverflowZeroNegativeAndUnknownDimensionsFailClosed() throws {
        for (width, height) in [(Int.max, 2), (2, Int.max), (Int.max, Int.max), (8192, 4097)] {
            XCTAssertThrowsError(try ImageAdmission.validate(width: width, height: height)) {
                XCTAssertEqual($0 as? ImageAdmissionError, .pixelBudgetExceeded)
            }
        }
        for (width, height) in [(0, 1), (1, 0), (-1, 1), (1, -1)] {
            XCTAssertThrowsError(try ImageAdmission.validate(width: width, height: height)) {
                XCTAssertEqual($0 as? ImageAdmissionError, .invalidImage)
            }
        }
        XCTAssertThrowsError(try ImageAdmission.validate(Data("not an image".utf8)))
    }

    func testTruncatedPayloadAndMalformedMetadataAreRejectedWithoutDecodeFallback() throws {
        let complete = try Self.fixture(4096)
        for length in [8, 24, 33, complete.count / 2, complete.count - 12] {
            XCTAssertThrowsError(try ImageAdmission.validate(Data(complete.prefix(length))), "Truncation at \(length)")
        }
        var zeroWidth = complete
        zeroWidth.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try ImageAdmission.validate(zeroWidth))
        XCTAssertThrowsError(try ContentStore.classify(Data("broken image".utf8), extension: "png"))
        XCTAssertEqual(try ContentStore.classify(Data([0, 1, 2]), extension: "bin").0, .file)
        let truncated = URL(fileURLWithPath: "/tmp/inkpeg-truncated-" + UUID().uuidString + ".png")
        try Data(complete.dropLast(12)).write(to: truncated)
        XCTAssertThrowsError(try ImageAdmission.validate(contentsOf: truncated))
        XCTAssertThrowsError(try ImageAdmission.validate(contentsOf: URL(string: "file://remote-host/image.png")!))
    }

    func testMultiFrameAdmissionRetainsCompleteOriginalAndOnlyInspectsFirstFrame() async throws {
        let gif = Self.twoFrameGIF
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        try ImageAdmission.validate(gif)
        let root = URL(fileURLWithPath: "/tmp/inkpeg-image-frames-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let result = try await store.importMaterial(.imageData(gif, SourceRecord(origin: .clipboard)), into: MatterGroup.ungroupedID, visibleCapacity: 8)
        let record = try XCTUnwrap(result.snapshot.materials.first)
        let payload = try await store.payloadURL(of: record.id)
        XCTAssertEqual(try Data(contentsOf: payload), gif)
        let export = try await store.exportCopy(of: record.id, to: root.deletingLastPathComponent().appendingPathComponent("inkpeg-gif-copy-" + UUID().uuidString + ".gif"))
        XCTAssertEqual(try Data(contentsOf: export), gif)
    }

    static var twoFrameGIF: Data {
        let header: [UInt8] = [71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, 255, 255, 255]
        let black: [UInt8] = [44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x44, 0x01, 0]
        let white: [UInt8] = [44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 2, 0x4c, 0x01, 0]
        return Data(header + black + white + [0x3b])
    }
}
