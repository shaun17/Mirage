import MirageCore
import Foundation

/// 主窗口的三个固定内容区；不会映射成额外的 File Provider 文件夹。
enum AppSection: String, CaseIterable, Identifiable {
    case discover
    case favorites
    case recent

    var id: Self { self }
    var title: String {
        switch self {
        case .discover: return "发现"
        case .favorites: return "收藏"
        case .recent: return "最近使用"
        }
    }
    var symbol: String {
        switch self {
        case .discover: return "square.grid.2x2"
        case .favorites: return "heart"
        case .recent: return "clock"
        }
    }
}

/// 搜索来源筛选；显式前缀和分段选择最终都交给 Core 的同一解析规则。
enum SearchFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case avatars

    var id: Self { self }
    var title: String {
        switch self {
        case .all: return "全部"
        case .photos: return "图片"
        case .avatars: return "头像"
        }
    }

    /// 分段筛选覆盖输入中的旧前缀，避免产生“图片:头像:”一类无效查询。
    func serviceQuery(for rawQuery: String) -> String {
        guard self != .all else { return rawQuery }
        let text = SearchQueryParser.parse(rawQuery).text
        return self == .photos ? "图片:\(text)" : "头像:\(text)"
    }
}

/// 搜索状态完整区分等待、进行中、空结果、网络失败和限流。
enum SearchState: Equatable {
    case idle
    case searching
    case results
    case empty
    case network(String)
    case rateLimited(String)
    case failed(String)

    /// 将 Core 的结构化错误转换成面向用户的精确状态。
    init(openverseError: OpenverseError) {
        switch openverseError {
        case .rateLimited:
            self = .rateLimited(openverseError.localizedDescription)
        case .network:
            self = .network(openverseError.localizedDescription)
        case .invalidResponse, .decoding:
            self = .failed(openverseError.localizedDescription)
        }
    }
}

/// File Provider 从注册到真实可用的完整状态。
enum ProviderState: Equatable {
    case checking
    case ready
    case needsActivation
    case failed(String)

    /// 只在状态进入明确终态时播报，避免检查中的短暂状态打断 VoiceOver。
    var accessibilityAnnouncement: String? {
        switch self {
        case .checking:
            return nil
        case .ready:
            return "Mirage 文件扩展已可用"
        case .needsActivation:
            return "Mirage 文件扩展需要在系统设置中启用"
        case .failed:
            return "Mirage 文件扩展检查失败"
        }
    }
}
