import Foundation

public struct CleanupTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case material, temporaryExport, completedEdit, unownedStaging }
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

public struct StagingRecoveryItem: Equatable, Sendable {
    public enum Disposition: Sendable { case unowned, referenced, needsInspection }
    public let relativePath: String
    public let byteCount: Int64?
    public let disposition: Disposition
}

public struct StorageCleanupPlan: Equatable, Sendable {
    public let id: UUID
    public let targets: [CleanupTarget]
    public var byteCount: Int64 { targets.reduce(0) { $0 + $1.byteCount } }
    public var materialCount: Int { targets.filter { $0.kind == .material }.count }
    public var completedEditCount: Int { targets.filter { $0.kind == .completedEdit }.count }
    public var stagingCount: Int { targets.filter { $0.kind == .unownedStaging }.count }
    public let stagingInventory: [StagingRecoveryItem]
    public var exportCount: Int { targets.filter { $0.kind == .temporaryExport }.count }
    let root: URL
    let generation: UInt64
    let exportCutoff: Date

    /// Retain the preview's fingerprints and generation when choosing a subset.
    public func selecting(_ relativePaths: Set<String>) -> StorageCleanupPlan {
        StorageCleanupPlan(id: id, targets: targets.filter { relativePaths.contains($0.relativePath) },
            stagingInventory: stagingInventory, root: root, generation: generation, exportCutoff: exportCutoff)
    }
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
