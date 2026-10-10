import AppKit
import XCTest
import InkpegCore
@testable import Inkpeg

final class IntakeReservationAuditTests: XCTestCase {
    @MainActor
    func testAcceptedDropReservationBlocksImmediateQuitUntilSaved() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-intake-reserved-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let service = ClipboardImportService(gateway: ReservationAuditBoard(), store: store)
        await service.start()
        let saved = expectation(description: "The acknowledged drop is later saved")
        service.onSnapshot = { _ in saved.fulfill() }
        XCTAssertTrue(service.enqueueManual([.text("accepted synthetic drop", SourceRecord(origin: .drop))]))
        XCTAssertEqual(service.pendingCount, 0, "The accepted asynchronous reservation has not prepared yet")
        let delegate = AppDelegate(environment: AppEnvironment(checkResources: false, dataRoot: root))
        let reply = delegate.requestTermination(markup: Markup(launchEditor: { _ in }), clipboard: service, respond: { _ in .alertFirstButtonReturn })
        XCTAssertEqual(reply, .terminateCancel, "An acknowledged but unsaved reservation must prevent immediate termination")
        await fulfillment(of: [saved], timeout: 2)
    }
}

@MainActor private final class ReservationAuditBoard: ClipboardGateway {
    var changeCount = 1
    func readSnapshot() throws -> ClipboardContents { ClipboardContents(revision: 1, requests: []) }
}
