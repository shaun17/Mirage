import Foundation
import XCTest

final class AppLocalizationTests: XCTestCase {
    private var bundle: Bundle {
        Bundle(for: AppLocalizationTests.self)
    }

    func testEnglishCoverageForWindowChromeAndPresentedSurfaces() {
        let locale = Locale(identifier: "en")

        XCTAssertEqual(AppSection.discover.resolvedTitle(locale: locale, bundle: bundle), "Discover")
        XCTAssertEqual(AppSection.favorites.resolvedTitle(locale: locale, bundle: bundle), "Favorites")
        XCTAssertEqual(AppSection.recent.resolvedTitle(locale: locale, bundle: bundle), "Recents")
        XCTAssertEqual(localized("在上传框中使用 Mirage", locale: locale), "Use Mirage in Upload Dialogs")
        XCTAssertEqual(
            localized("打开目标 App 的上传框或文件面板", locale: locale),
            "Open the upload dialog or file panel in your target app"
        )
        XCTAssertEqual(
            localized("在左侧“位置”中选择 Mirage", locale: locale),
            "Select Mirage under “Locations” in the sidebar"
        )
        XCTAssertEqual(
            localized("打开“更多图片”继续浏览", locale: locale),
            "Open “More Images” to keep browsing"
        )
        XCTAssertEqual(
            localized("收藏和最近使用会同步到文件面板中的同名目录。", locale: locale),
            "Favorites and recent items sync to matching folders in the file panel."
        )
        XCTAssertEqual(localized("软件更新", locale: locale), "Software Update")
        XCTAssertEqual(localized("正在检查更新…", locale: locale), "Checking for updates…")
        XCTAssertEqual(localized("取消", locale: locale), "Cancel")
        XCTAssertEqual(localized("您使用的就是最新版本！", locale: locale), "You're up to date!")
        XCTAssertEqual(
            AppDisplayMessage.localized(
                "Mirage %@ 是当前的最新版本。",
                .text("0.5.4")
            ).resolved(locale: locale, bundle: bundle),
            "Mirage 0.5.4 is the latest version available."
        )
        XCTAssertEqual(
            AppDisplayMessage.localized(
                "当前运行的 Mirage %@ 比可用的最新版本 %@ 更新。",
                .text("0.6.0"),
                .text("0.5.4")
            ).resolved(locale: locale, bundle: bundle),
            "This version of Mirage (0.6.0) is newer than the latest available version (0.5.4)."
        )
        XCTAssertEqual(localized("版本历史记录", locale: locale), "Version History")
    }

    func testSimplifiedChineseCoverageForWindowChromeAndPresentedSurfaces() {
        let locale = Locale(identifier: "zh-Hans")

        XCTAssertEqual(AppSection.discover.resolvedTitle(locale: locale, bundle: bundle), "发现")
        XCTAssertEqual(AppSection.favorites.resolvedTitle(locale: locale, bundle: bundle), "收藏")
        XCTAssertEqual(AppSection.recent.resolvedTitle(locale: locale, bundle: bundle), "最近使用")
        XCTAssertEqual(localized("在上传框中使用 Mirage", locale: locale), "在上传框中使用 Mirage")
        XCTAssertEqual(localized("软件更新", locale: locale), "软件更新")
        XCTAssertEqual(localized("正在检查更新…", locale: locale), "正在检查更新…")
        XCTAssertEqual(localized("取消", locale: locale), "取消")
        XCTAssertEqual(localized("您使用的就是最新版本！", locale: locale), "您使用的就是最新版本！")
        XCTAssertEqual(
            AppDisplayMessage.localized(
                "Mirage %@ 是当前的最新版本。",
                .text("0.5.4")
            ).resolved(locale: locale, bundle: bundle),
            "Mirage 0.5.4 是当前的最新版本。"
        )
        XCTAssertEqual(localized("版本历史记录", locale: locale), "版本历史记录")
    }

    private func localized(_ key: StaticString, locale: Locale) -> String {
        AppDisplayMessage.localized(key).resolved(locale: locale, bundle: bundle)
    }
}
