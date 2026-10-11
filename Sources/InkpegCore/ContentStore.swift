import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct OwnedPaths: Sendable {
    let root: URL
    let anchor: URL
    init(_ root: URL) {
        self.root = root.standardizedFileURL
        anchor = root.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent, isDirectory: true).standardizedFileURL
    }
    func url(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), !relative.hasPrefix("/") else { throw StoreError.invalidPath }
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == anchor.path else { throw StoreError.invalidPath }
        let target = root.appendingPathComponent(relative).standardizedFileURL
        let expected = anchor.appendingPathComponent(relative).standardizedFileURL
        guard target.resolvingSymlinksInPath().standardizedFileURL.path == expected.path else { throw StoreError.invalidPath }
        return target
    }
    func verifyRoot() throws {
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == anchor.path else { throw StoreError.invalidPath }
    }
}
public struct StagedContent: Sendable {
    public let stagingURL: URL
    public let source: SourceRecord
    public let kind: MaterialKind
    public let byteCount: Int64
    public let sha256: String
    let fileExtension: String
    let title: String
}
public struct ContentStore: Sendable {
    let paths: OwnedPaths
    let files: any FileOperations
    public init(root: URL, files: any FileOperations) { paths = OwnedPaths(root); self.files = files }
    public func stage(_ request: ImportRequest) async throws -> StagedContent {
        try Task.checkCancellation()
        let stagingURL = try paths.url("Transactions/" + UUID().uuidString + ".stage")
        let source: SourceRecord
        let kind: MaterialKind
        let title: String
        let ext: String
        switch request {
        case let .file(url, origin):
            let before = try files.inspect(url)
            guard url.isFileURL, before.isRegularFile, !before.isSymbolicLink else { throw StoreError.invalidSource }
            let originalDigest = Self.digest(try files.read(url))
            try files.copy(url, to: stagingURL)
            let after = try files.inspect(url)
            guard before == after, after.isRegularFile, !after.isSymbolicLink,
                  Self.digest(try files.read(url)) == originalDigest,
                  Self.digest(try files.read(stagingURL)) == originalDigest
            else { throw StoreError.sourceChanged }
            source = SourceRecord(origin: origin, filePath: url.standardizedFileURL.path)
            title = url.lastPathComponent
            let payload = try files.read(stagingURL)
            (kind, ext) = try Self.classify(payload, extension: url.pathExtension)
        case let .imageData(data, origin):
            try ImageAdmission.validate(data)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil,
                  let type = CGImageSourceGetType(image), let detected = UTType(type as String),
                  let suffix = detected.preferredFilenameExtension else { throw StoreError.invalidSource }
            try files.writeAtomic(data, to: stagingURL)
            source = origin; kind = .image; ext = suffix; title = "剪贴板图片"
        case let .text(text, origin):
            guard !text.isEmpty else { throw StoreError.invalidSource }
            try files.writeAtomic(Data(text.utf8), to: stagingURL)
            source = origin; kind = .text; ext = "txt"; title = String(text.prefix(80))
        }
        let info = try files.inspect(stagingURL)
        guard info.isRegularFile, !info.isSymbolicLink else { throw StoreError.invalidPath }
        return StagedContent(stagingURL: stagingURL, source: source, kind: kind, byteCount: info.byteCount, sha256: Self.digest(try files.read(stagingURL)), fileExtension: ext, title: title)
    }
    static func isStagingFilename(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        guard url.pathExtension == "stage", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return false }
        return name == id.uuidString + ".stage"
    }
    public func commit(_ staged: StagedContent, materialID: UUID, versionID: UUID) throws -> MaterialVersion {
        let folder = "Materials/" + materialID.uuidString
        let relative = folder + "/" + versionID.uuidString + "." + staged.fileExtension
        let expectedStagingPrefix = try paths.url("Transactions").path + "/"
        guard staged.stagingURL.standardizedFileURL.path.hasPrefix(expectedStagingPrefix),
              staged.stagingURL.resolvingSymlinksInPath().path == staged.stagingURL.standardizedFileURL.path,
              staged.sha256 == Self.digest(try files.read(staged.stagingURL))
        else { throw StoreError.invalidPath }
        try files.createDirectory(paths.url(folder))
        try files.move(staged.stagingURL, to: paths.url(relative))
        return MaterialVersion(id: versionID, relativePath: relative, sha256: staged.sha256, byteCount: staged.byteCount, kind: .original)
    }
    static func classify(_ data: Data, extension suffix: String) throws -> (MaterialKind, String) {
        if let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(image), let detected = UTType(type as String), detected.conforms(to: .image),
           let ext = detected.preferredFilenameExtension {
            try ImageAdmission.validate(data)
            guard CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw ImageAdmissionError.invalidImage }
            return (.image, ext)
        }
        if UTType(filenameExtension: suffix)?.conforms(to: .image) == true { throw ImageAdmissionError.invalidImage }
        if data.starts(with: Data("%PDF-".utf8)) { return (.pdf, "pdf") }
        let textExtensions: Set<String> = ["txt", "md", "csv", "json", "log"]
        if textExtensions.contains(suffix.lowercased()), String(data: data, encoding: .utf8) != nil { return (.text, suffix) }
        let safe = suffix.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return (.file, safe.isEmpty ? "bin" : String(safe.prefix(12)))
    }
    /// Keep a source basename, but derive the suffix from the selected payload.
    /// Titles can contain entire clipboard text and must never become paths.
    public static func suggestedExportFilename(for record: MaterialRecord, fileExtension suffix: String) -> String {
        let safeSuffix = String(suffix.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12))
        let ext = safeSuffix.isEmpty ? "bin" : safeSuffix
        let fallback = "Inkpeg-" + record.id.uuidString.prefix(8)
        guard let source = record.source.filePath, !source.isEmpty else { return fallback + "." + ext }
        let basename = URL(fileURLWithPath: source).lastPathComponent
        guard !basename.isEmpty, basename != ".", basename != ".." else { return fallback + "." + ext }
        let stem = (basename as NSString).deletingPathExtension
        let safeStem = stem.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) ? "_" : String(scalar)
        }.joined()
        guard !safeStem.isEmpty, safeStem != ".", safeStem != ".." else { return fallback + "." + ext }
        return safeStem + "." + ext
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
