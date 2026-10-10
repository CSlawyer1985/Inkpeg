import Foundation
public struct PendingEditResult: Equatable, Sendable {
    public let id: UUID
    public let data: Data
}
@MainActor
public final class EditResultBuffer {
    public private(set) var pending: PendingEditResult?
    private let maximumBytes: Int
    public init(maximumBytes: Int = 256 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    public func enqueue(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumBytes else { throw StoreError.budgetExceeded }
        pending = PendingEditResult(id: UUID(), data: data)
    }
    public func persist(using write: (Data) async throws -> Void) async throws {
        guard let result = pending else { throw StoreError.invalidEdit }
        try await write(result.data)
        acknowledge(result.id)
    }
    public func acknowledge(_ id: UUID) { if pending?.id == id { pending = nil } }
}
