import XCTest
@testable import InkpegCore

// Chinese resource failure must make these tests fail; raw keys are not a fallback.
final class LocalizationTests: XCTestCase {
    func testChineseCopyLabel() {
        XCTAssertEqual(Localizer(localeIdentifier: "zh-Hans").string(.copy), "复制")
    }
    func testUnknownLocaleFallsBackToEnglish() {
        XCTAssertEqual(Localizer(localeIdentifier: "unknown-locale").string(.copy), "Copy")
    }
    func testTraditionalChineseUsesChineseResources() {
        XCTAssertEqual(Localizer(localeIdentifier: "zh-Hant-TW").string(.copy), "复制")
    }
    func testSpanishCopyLabelIsPreserved() {
        XCTAssertEqual(Localizer(localeIdentifier: "es-ES").string(.copy), "Copiar")
    }
    func testEveryKeyHasNonRawResourceInEverySupportedLocale() {
        for locale in ["zh-Hans", "en", "es"] {
            let localizer = Localizer(localeIdentifier: locale)
            for key in MessageKey.allCases {
                let value = localizer.string(key)
                XCTAssertFalse(value.isEmpty, "Missing translated message")
                XCTAssertNotEqual(value, key.rawValue, "Raw message key escaped to the UI")
            }
        }
    }
}
