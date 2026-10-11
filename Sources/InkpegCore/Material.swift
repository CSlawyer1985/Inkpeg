import Foundation

public enum MaterialKind: String, Codable, Sendable { case image, text, pdf, file }
public enum MaterialStatus: String, Codable, Sendable { case hanging, takenDown, archived, trashed, needsReview }
public enum VersionKind: String, Codable, Sendable { case original, textEdit, markup }
public enum ImportOrigin: String, Codable, Sendable { case screenshot, fileSelection, drop, clipboard, note }
public enum PageLocator: Codable, Equatable, Sendable { case pdfIndex(Int), printedPage(String) }

public struct SourceRecord: Codable, Equatable, Sendable {
    public var origin: ImportOrigin
    public var filePath: String?
    public var fileBookmark: Data?
    public var webURL: URL?
    public var manualTitle: String?
    public var locator: PageLocator?
    public var isManuallyRegistered: Bool
    public init(origin: ImportOrigin, filePath: String? = nil, fileBookmark: Data? = nil, webURL: URL? = nil, manualTitle: String? = nil, locator: PageLocator? = nil, isManuallyRegistered: Bool = false) {
        self.origin = origin; self.filePath = filePath; self.fileBookmark = fileBookmark
        self.webURL = webURL; self.manualTitle = manualTitle; self.locator = locator
        self.isManuallyRegistered = isManuallyRegistered
    }
}
public struct MaterialVersion: Codable, Equatable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64
    public let kind: VersionKind
    public let createdAt: Date
    public init(id: UUID = UUID(), relativePath: String, sha256: String, byteCount: Int64, kind: VersionKind, createdAt: Date = Date()) {
        self.id = id; self.relativePath = relativePath; self.sha256 = sha256
        self.byteCount = byteCount; self.kind = kind; self.createdAt = createdAt
    }
}
public struct MaterialRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: MaterialKind
    public var matterID: UUID
    public var status: MaterialStatus
    public var pinned: Bool
    public var order: Int
    public var title: String
    public let createdAt: Date
    public var source: SourceRecord
    public var versions: [MaterialVersion]
    public let originalVersionID: UUID
    public var activeVersionID: UUID
    public init(id: UUID = UUID(), kind: MaterialKind, matterID: UUID = MatterGroup.ungroupedID, status: MaterialStatus = .hanging, pinned: Bool = false, order: Int = 0, title: String, createdAt: Date = Date(), source: SourceRecord, versions: [MaterialVersion], originalVersionID: UUID, activeVersionID: UUID) {
        self.id = id; self.kind = kind; self.matterID = matterID; self.status = status
        self.pinned = pinned; self.order = order; self.title = title; self.createdAt = createdAt
        self.source = source; self.versions = versions; self.originalVersionID = originalVersionID; self.activeVersionID = activeVersionID
    }
    public var activeVersion: MaterialVersion? { versions.first { $0.id == activeVersionID } }
}
public struct MatterGroup: Codable, Equatable, Sendable, Identifiable {
    public static let ungroupedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public let id: UUID
    public var name: String
    public var order: Int
    public init(id: UUID = UUID(), name: String, order: Int = 0) { self.id = id; self.name = name; self.order = order }
}
public struct CaptureFolderSetting: Codable, Equatable, Sendable {
    public var bookmark: Data
    public var lastKnownPath: String
    public var enabled: Bool
    public init(bookmark: Data, lastKnownPath: String, enabled: Bool) { self.bookmark = bookmark; self.lastKnownPath = lastKnownPath; self.enabled = enabled }
}
public enum ImportRequest: Sendable { case file(URL, ImportOrigin), imageData(Data, SourceRecord), text(String, SourceRecord) }
public enum ImportDisposition: Equatable, Sendable { case hanging(UUID), duplicate(UUID), shelfFull }
public enum DuplicateImportPolicy: Sendable { case keepExisting, rehangTakenDown }
public struct ImportResult: Equatable, Sendable {
    public let disposition: ImportDisposition
    public let snapshot: WorkspaceSnapshot
    public init(disposition: ImportDisposition, snapshot: WorkspaceSnapshot) { self.disposition = disposition; self.snapshot = snapshot }
}
public enum MaterialCommand: Sendable {
    case takeDown(UUID), hang(UUID), archive(UUID), pin(UUID, Bool), takeDownUnpinned(UUID)
    case createMatter(String), renameMatter(UUID, String), selectMatter(UUID), moveToMatter(UUID, UUID)
    case renameMaterial(UUID, String), setSource(UUID, SourceRecord), setPrivacyHidden(Bool)
    case setCaptureFolder(CaptureFolderSetting?), trash(UUID)
}
public struct StorageBudget: Sendable {
    public var maxFileBytes: Int64
    public var maxMaterialBytes: Int64
    public var minimumFreeBytes: Int64
    public init(maxFileBytes: Int64 = 256 * 1024 * 1024, maxMaterialBytes: Int64 = 2 * 1024 * 1024 * 1024, minimumFreeBytes: Int64 = 512 * 1024 * 1024) {
        self.maxFileBytes = maxFileBytes; self.maxMaterialBytes = maxMaterialBytes; self.minimumFreeBytes = minimumFreeBytes
    }
}
public struct EditSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let materialID: UUID
    public let baseVersionID: UUID
    public let workingURL: URL
    public let kind: VersionKind
}
public enum EditResult: Sendable { case save(URL), cancel }
