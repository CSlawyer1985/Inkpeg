import XCTest
@testable import InkpegCore

final class PrivacyStateTests: XCTestCase {
    func testPrivacyPersistsAcrossRestartUntilExplicitlyDisabled() async throws {
        let root = URL(fileURLWithPath: "/tmp/inkpeg-privacy-state-" + UUID().uuidString)
        let store = MaterialStore(root: root)
        let hidden = try await store.apply(.setPrivacyHidden(true))
        XCTAssertTrue(hidden.privacyHidden)
        let restarted = MaterialStore(root: root)
        let loaded = try await restarted.load()
        XCTAssertTrue(loaded.privacyHidden)
        let visible = try await restarted.apply(.setPrivacyHidden(false))
        XCTAssertFalse(visible.privacyHidden)
        let final = try await MaterialStore(root: root).load()
        XCTAssertFalse(final.privacyHidden)
    }
}

extension PrivacyStateTests {
    func testFailedPrivacyWriteDoesNotChangeCachedOrRestartedState() async throws {
        let fixture = try StoreFixture()
        let original = try await fixture.makeStore().load()
        let store = fixture.makeStore(files: FaultFiles(.snapshotWrite))
        do { _ = try await store.apply(.setPrivacyHidden(true)); XCTFail("Privacy disk failure must surface") }
        catch { XCTAssertEqual(error as? StoreError, .unavailableSpace) }
        let cached = try await store.load(), restarted = try await fixture.makeStore().load()
        XCTAssertEqual(cached, original); XCTAssertEqual(restarted, original)
    }
}
