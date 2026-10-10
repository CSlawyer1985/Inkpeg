import Foundation

public struct ClipboardPreference: Codable, Equatable, Sendable {
    public var version = 2
    public var enabled: Bool
    public var images: Bool
    public var text: Bool
    public var files: Bool
    public var includeExisting: Bool
    public init(enabled: Bool = false, images: Bool = true, text: Bool = true, files: Bool = true, includeExisting: Bool = true) {
        self.enabled = enabled; self.images = images; self.text = text
        self.files = files; self.includeExisting = includeExisting
    }
    private enum CodingKeys: String, CodingKey { case version, enabled, images, text, files, includeExisting }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decode(Int.self, forKey: .version)
        guard [1, 2].contains(storedVersion) else { throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Unsupported preference version") }
        enabled = try c.decode(Bool.self, forKey: .enabled)
        if storedVersion == 1 { images = true; text = true; files = true; includeExisting = true }
        else {
            images = try c.decode(Bool.self, forKey: .images); text = try c.decode(Bool.self, forKey: .text)
            files = try c.decode(Bool.self, forKey: .files); includeExisting = try c.decode(Bool.self, forKey: .includeExisting)
        }
    }
    public func accepts(_ request: ImportRequest) -> Bool {
        switch request { case .file: return files; case .imageData: return images; case .text: return text }
    }
}

public struct ClipboardFileFingerprint: Equatable, Sendable {
    public let info: FileInfo
    public let sha256: String
}
