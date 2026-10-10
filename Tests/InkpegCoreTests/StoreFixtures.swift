import Foundation
import XCTest
import CryptoKit
@testable import InkpegCore

struct StoreFixture {
    let root: URL
    let source: URL
    let bytes = Data("合成摘录，保护原件。".utf8)
    init() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkpeg-tests-" + UUID().uuidString)
        root = parent.appendingPathComponent("owned")
        source = parent.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try bytes.write(to: source)
    }
    var budget: StorageBudget { StorageBudget(maxFileBytes: 1024, maxMaterialBytes: 4096, minimumFreeBytes: 0) }
    func makeStore(files: any FileOperations = FaultFiles()) -> MaterialStore {
        MaterialStore(root: root, files: files, budget: budget)
    }
}
struct FaultFiles: FileOperations {
    enum Fault: Sendable { case none, snapshotWrite, noSpace, copy, mutateSource }
    let fault: Fault
    let base = SystemFileOperations()
    init(_ fault: Fault = .none) { self.fault = fault }
    func inspect(_ url: URL) throws -> FileInfo { try base.inspect(url) }
    func read(_ url: URL) throws -> Data { try base.read(url) }
    func createDirectory(_ url: URL) throws { try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws {
        if fault == .copy { throw StoreError.unavailableSpace }
        try base.copy(source, to: destination)
        if fault == .mutateSource { try Data("source changed during copy".utf8).write(to: source) }
    }
    func move(_ ownedSource: URL, to ownedDestination: URL) throws { try base.move(ownedSource, to: ownedDestination) }
    func writeAtomic(_ data: Data, to ownedDestination: URL) throws {
        if fault == .snapshotWrite && ownedDestination.lastPathComponent == "state.json" { throw StoreError.unavailableSpace }
        try base.writeAtomic(data, to: ownedDestination)
    }
    func availableBytes(at root: URL) throws -> Int64 { fault == .noSpace ? 0 : 1_000_000 }
    func trash(_ ownedPackage: URL) throws -> URL { throw StoreError.invalidSource }
    func list(_ ownedDirectory: URL) throws -> [URL] { try base.list(ownedDirectory) }
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
