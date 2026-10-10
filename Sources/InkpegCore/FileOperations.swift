import Foundation

public struct FileInfo: Equatable, Sendable {
    public let isRegularFile: Bool
    public let isSymbolicLink: Bool
    public let byteCount: Int64
    public let modificationDate: Date
}
public protocol FileOperations: Sendable {
    func inspect(_ url: URL) throws -> FileInfo
    func read(_ url: URL) throws -> Data
    func createDirectory(_ url: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func move(_ ownedSource: URL, to ownedDestination: URL) throws
    func writeAtomic(_ data: Data, to ownedDestination: URL) throws
    func availableBytes(at root: URL) throws -> Int64
    func trash(_ ownedPackage: URL) throws -> URL
    // Needed for journal reconciliation and accounting retained orphan versions.
    func list(_ ownedDirectory: URL) throws -> [URL]
}
public struct SystemFileOperations: FileOperations {
    public init() {}
    public func inspect(_ url: URL) throws -> FileInfo {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileInfo(isRegularFile: values[.type] as? FileAttributeType == .typeRegular,
                        isSymbolicLink: values[.type] as? FileAttributeType == .typeSymbolicLink,
                        byteCount: (values[.size] as? NSNumber)?.int64Value ?? 0,
                        modificationDate: values[.modificationDate] as? Date ?? .distantPast)
    }
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func createDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    public func copy(_ source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    public func move(_ ownedSource: URL, to ownedDestination: URL) throws { try FileManager.default.moveItem(at: ownedSource, to: ownedDestination) }
    public func writeAtomic(_ data: Data, to ownedDestination: URL) throws { try data.write(to: ownedDestination, options: .atomic) }
    public func availableBytes(at root: URL) throws -> Int64 {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw StoreError.unavailableSpace }
        return bytes
    }
    public func trash(_ ownedPackage: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: ownedPackage, resultingItemURL: &result)
        guard let result else { throw StoreError.recoveryRequired }
        return result as URL
    }
    public func list(_ ownedDirectory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: ownedDirectory, includingPropertiesForKeys: nil)
    }
}
