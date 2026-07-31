@preconcurrency import FileProvider
import Foundation

/// 所有 Mirage 目录只接受系统首次枚举页；远端续页由真实虚拟目录承载。
enum ProviderPagePlanner {
    /// 名称和日期两种系统初始页都合法；任何 continuation 都要求系统重新开始当前目录。
    static func validateInitialPage(_ page: NSFileProviderPage) throws {
        let rawValue = page.rawValue
        guard rawValue == NSFileProviderPage.initialPageSortedByName as Data
                || rawValue == NSFileProviderPage.initialPageSortedByDate as Data else {
            throw ProviderError.invalidEnumerationPage()
        }
    }
}
