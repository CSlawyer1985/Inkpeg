import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageAdmissionError: Error, Equatable, LocalizedError, Sendable {
    case invalidImage, pixelBudgetExceeded
    public var errorDescription: String? {
        Localizer().string(self == .pixelBudgetExceeded ? .imagePixelLimit : .imageInvalid)
    }
}

/// Metadata admission is required before decoding. Animated sources keep their
/// original bytes; previews and converted representations decode frame zero only.
public enum ImageAdmission {
    private static let options = [kCGImageSourceShouldCache: false] as CFDictionary

    public static func validate(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { throw ImageAdmissionError.invalidImage }
        try validate(source)
        if CGImageSourceGetType(source) as String? == "public.png" {
            try validatePNG(byteCount: data.count) { offset, count in Data(data[offset..<offset + count]) }
        }
    }

    public static func validate(contentsOf url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              let source = CGImageSourceCreateWithURL(url as CFURL, options) else { throw ImageAdmissionError.invalidImage }
        try validate(source)
        if CGImageSourceGetType(source) as String? == "public.png" {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw ImageAdmissionError.invalidImage }
            try validatePNG(byteCount: byteCount) { offset, count in
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: count) ?? Data()
            }
        }
    }

    public static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ImageAdmissionError.invalidImage }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= ClipboardLimits.imagePixels else { throw ImageAdmissionError.pixelBudgetExceeded }
    }

    private static func validate(_ source: CGImageSource) throws {
        guard let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let actualWidth = Int(exactly: width.doubleValue), let actualHeight = Int(exactly: height.doubleValue)
        else { throw ImageAdmissionError.invalidImage }
        try validate(width: actualWidth, height: actualHeight)
    }

    // ImageIO accepts a PNG with complete IDAT but no IEND as "complete".
    // Check the encoded terminator without inflating pixels. Leave tolerant
    // chunk parsing to ImageIO, as used for previously supported images.
    private static func validatePNG(byteCount: Int, read: (Int, Int) throws -> Data) throws {
        guard byteCount >= 20 else { throw ImageAdmissionError.invalidImage }
        let terminator = try read(byteCount - 12, 12)
        guard terminator == Data([0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
        else { throw ImageAdmissionError.invalidImage }
    }
}
