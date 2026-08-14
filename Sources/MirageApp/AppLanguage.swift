import MirageCore
import SwiftUI

/// App 展示层复用 Core 与 File Provider 共用的稳定语言类型。
typealias AppLanguage = MirageAppLanguage

extension MirageAppLanguage {
    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}
