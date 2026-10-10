import Foundation

public enum SourceFormatter {
    public static func describe(_ source: SourceRecord, localizer: Localizer) -> String? {
        var parts = [String]()
        if source.origin == .note { parts.append(localizer.string(.noteOrigin)) }
        if let title = source.manualTitle, !title.isEmpty { parts.append(title) }
        if let path = source.filePath { parts.append(path) }
        if let url = source.webURL { parts.append(url.absoluteString) }
        switch source.locator {
        case .pdfIndex(let index) where index >= 0:
            parts.append(localizer.string(.sourcePDFPage).replacingOccurrences(of: "%d", with: String(index + 1)))
        case .printedPage(let label):
            parts.append(localizer.string(.sourcePrintedPage).replacingOccurrences(of: "%@", with: label))
        default: break
        }
        guard !parts.isEmpty else { return nil }
        if source.isManuallyRegistered || { if case .printedPage = source.locator { return true }; return false }() {
            parts.append(localizer.string(.sourceManual))
        }
        return parts.joined(separator: " · ")
    }
    public static func validate(_ source: SourceRecord) throws {
        if let path = source.filePath, !path.hasPrefix("/") { throw StoreError.invalidSource }
        if let url = source.webURL, !["https", "http"].contains(url.scheme?.lowercased() ?? "") || url.host == nil { throw StoreError.invalidSource }
        if let title = source.manualTitle, title.count > 1024 { throw StoreError.invalidSource }
        switch source.locator {
        case .pdfIndex(let index): guard index >= 0, index < Int.max else { throw StoreError.invalidSource }
        case .printedPage(let label): guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 128 else { throw StoreError.invalidSource }
        default: break
        }
    }
}
