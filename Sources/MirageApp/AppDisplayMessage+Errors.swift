import MirageCore

extension PhotoSourceIssue {
    /// Core 只提供来源、故障类别和最终字符串；展示层用结构化字段恢复可本地化的稳定说明。
    var appDisplayMessage: AppDisplayMessage {
        let sourceName = PhotoSourceRegistry.descriptor(for: sourceID)?.displayName
            ?? sourceID.rawValue
        switch kind {
        case .missingCredential:
            return .localized("请先在设置中配置 %@ API Key。", .text(sourceName))
        case .invalidCredential:
            return .localized("%@ API Key 无效或未配置。", .text(sourceName))
        case .rateLimited:
            return .localized("%@ 请求过于频繁，请稍后重试。", .text(sourceName))
        case .network:
            return .localized("%@ 网络不可用，请检查连接后重试。", .text(sourceName))
        case .invalidResponse:
            return .localized("%@ 返回了无效响应，请稍后重试。", .text(sourceName))
        case .decoding:
            return .localized("%@ 返回的数据无法读取，请稍后重试。", .text(sourceName))
        case .unavailable:
            return .localized("%@ 暂时不可用。", .text(sourceName))
        }
    }
}

extension OpenverseError: AppDisplayMessageConvertible {
    var appDisplayMessage: AppDisplayMessage {
        switch self {
        case let .rateLimited(retryAfter):
            if let retryAfter {
                return .localized(
                    "Openverse 请求过于频繁，请在 %lld 秒后重试",
                    .integer(Int(retryAfter))
                )
            }
            return "Openverse 请求过于频繁"
        case let .network(message):
            return .localized("Openverse 网络错误：%@", .text(message))
        case let .invalidResponse(statusCode):
            return .localized("Openverse 返回异常状态：%lld", .integer(statusCode))
        case let .decoding(message):
            return .localized("Openverse 数据解析失败：%@", .text(message))
        }
    }
}

extension PhotoSearchError: AppDisplayMessageConvertible {
    var appDisplayMessage: AppDisplayMessage {
        switch self {
        case .noEnabledSources:
            return "没有启用可用的图片数据源。"
        case .invalidCursor:
            return "图片分页位置无效，请重新搜索。"
        case .configurationChanged:
            return "图片数据源设置已变化，请重新搜索。"
        case let .allSourcesFailed(issues):
            let issue = issues.first { $0.kind == .rateLimited }
                ?? issues.first { $0.kind == .network }
                ?? issues.first
            return issue?.appDisplayMessage ?? "图片数据源暂时不可用。"
        }
    }
}

extension PhotoSourcePreferencesError: AppDisplayMessageConvertible {
    var appDisplayMessage: AppDisplayMessage {
        switch self {
        case .unavailableAppGroup:
            return "无法访问图片数据源共享设置。"
        case .sourceUnavailable:
            return "该图片数据源正在适配。"
        case .unsupportedSurface:
            return "该图片数据源不支持当前使用范围。"
        case .noEnabledSources:
            return "至少需要保留一个图片数据源。"
        case .encoding:
            return "无法保存图片数据源设置。"
        }
    }
}

extension PhotoSourceCredentialError: AppDisplayMessageConvertible {
    var appDisplayMessage: AppDisplayMessage {
        switch self {
        case .emptyCredential:
            return "API Key 不能为空。"
        case .invalidEncoding:
            return "无法读取已保存的 API Key。"
        case .unavailableStorage:
            return "无法访问图片数据源持久数据。"
        case .corruptStorage:
            return "图片数据源持久数据已损坏。"
        case .persistence:
            return "无法保存图片数据源设置。"
        case .missingAppGroupEntitlement:
            return "当前构建缺少 Mirage App Group 权限，请使用正常开发签名重新运行。"
        }
    }
}

extension AppGroupStorageError: AppDisplayMessageConvertible {
    var appDisplayMessage: AppDisplayMessage {
        switch self {
        case let .unavailableAppGroup(identifier):
            return .localized("无法访问 App Group：%@", .text(identifier))
        }
    }
}

extension FavoriteStorageError: AppDisplayMessageConvertible {
    var appDisplayMessage: AppDisplayMessage {
        switch self {
        case .missingGiphyIdentifier:
            return "该 GIPHY 内容缺少可安全保存的对象标识，请刷新后重试。"
        }
    }
}
