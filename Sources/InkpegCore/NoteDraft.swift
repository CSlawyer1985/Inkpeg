import Foundation

public struct NoteDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let materialID: UUID
    public let matterID: UUID
    public var baseVersionID: UUID?
    public var text: String
    public var revision: UInt64
    public var publishedRevision: UInt64?
    public var updatedAt: Date
    // A clearing edit remains recoverable even though blank text cannot be published.
    public var isPending: Bool { revision != publishedRevision }
    public init(id: UUID = UUID(), materialID: UUID = UUID(), matterID: UUID, baseVersionID: UUID? = nil, text: String = "", revision: UInt64 = 0, publishedRevision: UInt64? = nil, updatedAt: Date = Date()) {
        self.id = id; self.materialID = materialID; self.matterID = matterID; self.baseVersionID = baseVersionID
        self.text = text; self.revision = revision; self.publishedRevision = publishedRevision; self.updatedAt = updatedAt
    }
}
