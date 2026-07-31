import FileProvider
import Foundation
import XCTest

final class ProviderPagePlannerTests: XCTestCase {
    /// Finder 的名称与日期两种系统初始页都允许开始固定推荐窗口枚举。
    func testSystemInitialPagesAreAccepted() throws {
        let namePage = NSFileProviderPage(
            rawValue: NSFileProviderPage.initialPageSortedByName as Data
        )
        let datePage = NSFileProviderPage(
            rawValue: NSFileProviderPage.initialPageSortedByDate as Data
        )
        XCTAssertNoThrow(try ProviderPagePlanner.validateInitialPage(namePage))
        XCTAssertNoThrow(try ProviderPagePlanner.validateInitialPage(datePage))
    }

    /// 任意自定义或旧版续页令牌都必须过期，防止 Finder 再次主动耗尽远端推荐流。
    func testContinuationAndCorruptPagesExpire() throws {
        XCTAssertThrowsError(
            try ProviderPagePlanner.validateInitialPage(
                NSFileProviderPage(rawValue: Data("broken".utf8))
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(nsError.code, NSFileProviderError.Code.pageExpired.rawValue)
        }
    }
}
