import Foundation
import MirageCore
import XCTest

final class ProviderLocalizationTests: XCTestCase {
    func testSharedLanguageContractResolvesStoredValuesAndLocales() {
        XCTAssertEqual(MirageAppLanguage.storageKey, "app-language")
        XCTAssertEqual(
            MirageAppLanguage.allCases,
            [.system, .simplifiedChinese, .english]
        )
        XCTAssertEqual(MirageAppLanguage.resolve(nil), .system)
        XCTAssertEqual(MirageAppLanguage.resolve(""), .system)
        XCTAssertEqual(MirageAppLanguage.resolve("invalid"), .system)
        XCTAssertEqual(MirageAppLanguage.resolve("zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(MirageAppLanguage.resolve("en"), .english)
        XCTAssertEqual(MirageAppLanguage.simplifiedChinese.locale.identifier, "zh-Hans")
        XCTAssertEqual(MirageAppLanguage.english.locale.identifier, "en")
        XCTAssertEqual(
            MirageAppLanguage.systemLanguage(for: ["fr-FR", "en-GB", "zh-Hans"]),
            .english
        )
        XCTAssertEqual(MirageAppLanguage.systemLanguage(for: ["zh-CN", "en"]), .simplifiedChinese)
        XCTAssertEqual(
            MirageAppLanguage.systemLanguage(for: ["zh-Hant", "ja-JP"]),
            .simplifiedChinese
        )
    }

    func testSystemLanguageUsesFirstSupportedPreferenceAndChineseFallback() {
        let defaults = makeDefaults()
        let english = ProviderLocalization(
            bundle: Bundle(for: Self.self),
            defaults: defaults,
            preferredLanguages: { ["fr-FR", "en-GB", "zh-Hans"] }
        )
        let englishFallback = ProviderLocalization(
            bundle: Bundle(for: Self.self),
            defaults: defaults,
            preferredLanguages: { ["es-ES"] }
        )
        let traditionalChineseThenEnglish = ProviderLocalization(
            bundle: Bundle(for: Self.self),
            defaults: defaults,
            preferredLanguages: { ["zh-Hant", "en"] }
        )

        XCTAssertEqual(english.resolvedLanguage, .english)
        XCTAssertEqual(englishFallback.resolvedLanguage, .simplifiedChinese)
        XCTAssertEqual(traditionalChineseThenEnglish.resolvedLanguage, .english)
    }

    func testExplicitPreferenceOverridesSystemAndIsReadEveryTime() {
        let defaults = makeDefaults()
        let localization = ProviderLocalization(
            bundle: Bundle(for: Self.self),
            defaults: defaults,
            preferredLanguages: { ["zh-Hans"] }
        )

        defaults.set(MirageAppLanguage.english.rawValue, forKey: MirageAppLanguage.storageKey)
        XCTAssertEqual(localization.resolvedLanguage, .english)

        defaults.set(
            MirageAppLanguage.simplifiedChinese.rawValue,
            forKey: MirageAppLanguage.storageKey
        )
        XCTAssertEqual(localization.resolvedLanguage, .simplifiedChinese)

        defaults.set("damaged-value", forKey: MirageAppLanguage.storageKey)
        XCTAssertEqual(localization.resolvedLanguage, .simplifiedChinese)
    }

    func testBundleWithoutProviderResourcesFallsBackToChineseKey() {
        let defaults = makeDefaults()
        defaults.set(MirageAppLanguage.english.rawValue, forKey: MirageAppLanguage.storageKey)
        let localization = ProviderLocalization(
            bundle: Bundle(for: NSObject.self),
            defaults: defaults,
            preferredLanguages: { ["en"] }
        )

        XCTAssertEqual(localization.string("头像"), "头像")
        XCTAssertEqual(
            localization.string("搜索服务返回 HTTP %lld。", Int64(503)),
            "搜索服务返回 HTTP 503。"
        )
        XCTAssertEqual(
            localization.string("请先在设置中配置 %@ API Key。", "Pexels"),
            "请先在设置中配置 Pexels API Key。"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ProviderLocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
