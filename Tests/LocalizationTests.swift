import XCTest
@testable import Smail

final class LocalizationTests: XCTestCase {
    func testSystemLanguageMatchingAndOverrides() {
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["en-US", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["zh-Hant-TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr-FR", "zh-Hans"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolvedIdentifier(preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.chinese.resolvedIdentifier(preferredLanguages: ["en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.english.resolvedIdentifier(preferredLanguages: ["zh-Hans"]), "en")
    }

    func testLocalizationResourcesHaveMatchingKeysAndFormatArguments() throws {
        func table(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        }
        let english = try table("en"), chinese = try table("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let regex = try NSRegularExpression(pattern: "%(@|lld|ld)")
        func placeholders(_ value: String) -> [String] {
            regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }
        }
        for key in chinese.keys {
            XCTAssertFalse(english[key]!.isEmpty, key)
            XCTAssertEqual(placeholders(english[key]!), placeholders(chinese[key]!), key)
        }
    }

    func testErrorsTranslateAtDisplayTimeAndPreserveDetails() {
        let english = Locale(identifier: "en"), chinese = Locale(identifier: "zh-Hans")
        let error = "Gmail 请求失败（418），请重试。"
        XCTAssertEqual(AppLanguage.errorText(error, locale: english), "Gmail request failed (418). Please try again.")
        XCTAssertEqual(AppLanguage.errorText(error, locale: chinese), error)
        XCTAssertEqual(AppLanguage.errorText("本地批次无法读取：本地批次账号不匹配。", locale: english),
                       "Could not load the local batch: The local batch belongs to a different account.")
        XCTAssertEqual(AppLanguage.errorText("An external error", locale: english), "An external error")
    }
}
