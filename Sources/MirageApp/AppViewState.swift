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
    case avatars
    case photos
    case all

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

/// 共享资料库状态明确区分启动准备与永久失败，避免展示实际上无法执行的收藏操作。
enum LibraryAvailability: Equatable {
    case preparing
    case ready
    case failed(String)

    /// 只有 App Group 已成功打开时才允许修改收藏。
    var allowsFavoriteChanges: Bool {
        self == .ready
    }

    /// 永久失败时提供可持续读取的界面说明，启动准备阶段不制造错误提示。
    var unavailableDescription: String? {
        guard case let .failed(message) = self else { return nil }
        return "收藏不可用：\(message)"
    }
}

/// 分页状态把自动加载、显式继续、失败和真正结束分开，避免把正常空页当成错误。
enum SearchPaginationState: Equatable {
    case unavailable
    case ready
    case loading
    case needsContinuation(String)
    case failed(String)
    case exhausted

    /// 只有准备态允许几何触底自动发起请求，其他状态都需要等待或用户操作。
    var allowsAutomaticLoading: Bool {
        self == .ready
    }
}

/// 每次搜索提交只产生一个独立播报事件，避免结果数量和结束状态互相打断。
struct SearchAccessibilityEvent: Equatable {
    let id = UUID()
    let message: String
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
            return "Mirage 文件提供程序已可用"
        case .needsActivation:
            return "Mirage 文件提供程序需要在系统设置中启用"
        case .failed:
            return "Mirage 文件提供程序检查失败"
        }
    }
}
