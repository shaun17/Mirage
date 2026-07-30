import Foundation

/// 搜索范围。无前缀时同时搜索真实图片和少量生成头像。
public enum SearchScope: Equatable, Sendable {
    case automatic
    case avatar
    case photo
}

/// 已移除控制前缀、可直接发送给服务端的查询。
public struct ParsedSearchQuery: Equatable, Sendable {
    public let text: String
    public let scope: SearchScope

    public init(text: String, scope: SearchScope) {
        self.text = text
        self.scope = scope
    }
}

public enum SearchQueryParser {
    private static let prefixes: [(String, SearchScope)] = [
        ("头像:", .avatar), ("avatar:", .avatar),
        ("图片:", .photo), ("photo:", .photo)
    ]

    /// 只识别字符串开头的中英文前缀，英文匹配不区分大小写。
    public static func parse(_ input: String) -> ParsedSearchQuery {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for (prefix, scope) in prefixes where trimmed.lowercased().hasPrefix(prefix) {
            let index = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let text = trimmed[index...].trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedSearchQuery(text: text, scope: scope)
        }
        return ParsedSearchQuery(text: trimmed, scope: .automatic)
    }
}
