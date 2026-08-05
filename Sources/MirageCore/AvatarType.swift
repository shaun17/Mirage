import Foundation

/// 与服务商无关的头像内容分类；筛选界面只展示这些用户可理解的类型。
public enum AvatarType: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case cartoonCharacter = "cartoon_character"
    case anime
    case aiRealistic = "ai_realistic"
    case robot
    case monster
    case animal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cartoonCharacter: return "卡通人物"
        case .anime: return "二次元动漫"
        case .aiRealistic: return "AI 真人"
        case .robot: return "机器人"
        case .monster: return "怪兽"
        case .animal: return "动物"
        }
    }
}

public extension RemoteImageRecord {
    /// 未带分类的旧记录仅在“全部类型”状态下保留，避免升级后默认视图丢失历史头像。
    func matchesAvatarTypes(_ allowedTypes: Set<AvatarType>) -> Bool {
        guard source.isAvatarSource else { return false }
        guard let avatarType else {
            return allowedTypes == Set(AvatarType.allCases)
        }
        return allowedTypes.contains(avatarType)
    }
}
