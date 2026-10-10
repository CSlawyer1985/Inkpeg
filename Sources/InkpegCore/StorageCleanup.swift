import Foundation

public struct CleanupTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case material, temporaryExport }
    public let kind: Kind
    public let materialID: UUID?
    public let title: String
    public let relativePath: String
    public let byteCount: Int64
    public let fileCount: Int
    let fingerprints: [CleanupFingerprint]
}

struct CleanupFingerprint: Codable, Equatable, Sendable {
    let path: String
    let directory: Bool
    let bytes: Int64
    let modifiedAt: Date
    let sha256: String?
}

public struct StorageCleanupPlan: Equatable, Sendable {
    public let id: UUID
    public let targets: [CleanupTarget]
    public var byteCount: Int64 { targets.reduce(0) { $0 + $1.byteCount } }
    public var materialCount: Int { targets.filter { $0.kind == .material }.count }
    public var exportCount: Int { targets.filter { $0.kind == .temporaryExport }.count }
    let root: URL
    let generation: UInt64
    let exportCutoff: Date
}

public struct StorageCleanupResult: Sendable {
    public let snapshot: WorkspaceSnapshot
    public let movedCount: Int
    public let movedBytes: Int64
    public let failedCount: Int
    public let unverifiedCount: Int
    public let receiptURL: URL
}

struct CleanupReceipt: Codable {
    struct Outcome: Codable {
        let originalPath: String
        let trashURL: URL?
        let verified: Bool
        let error: String?
    }
    let id: UUID
    let createdAt: Date
    let authorization: String
    let snapshotBefore: WorkspaceSnapshot
    let targets: [CleanupTarget]
    var outcomes: [Outcome]
}
