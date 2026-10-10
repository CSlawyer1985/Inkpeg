import XCTest
@testable import InkpegCore
final class EditResultBufferTests: XCTestCase {
    @MainActor
    func testFailedWriteKeepsReturnedResultAndOldAcknowledgementCannotClearNewResult() async throws {
        let buffer = EditResultBuffer(maximumBytes: 128)
        let firstData = Data("first result".utf8), nextData = Data("next result".utf8)
        try buffer.enqueue(firstData)
        do { try await buffer.persist { _ in throw StoreError.unavailableSpace }; XCTFail("Write must fail") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        XCTAssertEqual(buffer.pending?.data, firstData)
        try await buffer.persist { data in
            XCTAssertEqual(data, firstData)
            try buffer.enqueue(nextData) // A newer callback arrives while an older write completes.
        }
        XCTAssertEqual(buffer.pending?.data, nextData)
        try await buffer.persist { XCTAssertEqual($0, nextData) }
        XCTAssertNil(buffer.pending)
    }
}
