import AppKit
import PDFKit
import XCTest
@testable import Inkpeg

final class PDFThumbnailTests: XCTestCase {
    private func pdf(size: CGSize = CGSize(width: 595, height: 842)) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkpeg-pdf-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = NSMutableData(); var page = CGRect(origin: .zero, size: size)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &page, nil))
        for color in [CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)] {
            context.beginPDFPage(nil); context.setFillColor(color); context.fill(page); context.endPDFPage()
        }
        context.closePDF()
        let url = root.appendingPathComponent("synthetic.pdf"); try (data as Data).write(to: url); return url
    }
    func testFirstPageIsRenderedWithinPixelBudgetWithoutChangingOriginal() throws {
        let url = try pdf(), original = try Data(contentsOf: url)
        let image = try XCTUnwrap(makeThumbnail(url, maxPixels: 1600))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 480)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.blueComponent, center.redComponent, "The first blue page must render, not the red second page or a generic icon")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testMalformedEncryptedAndOversizedPagesFallBackWithoutRendering() throws {
        let url = try pdf()
        let encrypted = try XCTUnwrap(PDFDocument(url: url)?.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "synthetic-user", PDFDocumentWriteOption.ownerPasswordOption: "synthetic-owner"]))
        let locked = url.deletingLastPathComponent().appendingPathComponent("locked.pdf"); try encrypted.write(to: locked)
        XCTAssertNil(makeThumbnail(locked))
        let invalid = url.deletingLastPathComponent().appendingPathComponent("invalid.pdf"); try Data("not a PDF".utf8).write(to: invalid)
        XCTAssertNil(makeThumbnail(invalid))
        XCTAssertNil(makeThumbnail(try pdf(size: CGSize(width: 100_000, height: 100_000))))
        XCTAssertNil(makeThumbnail(url, maxPixels: 0))
    }
}
