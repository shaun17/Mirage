import Foundation

/// App 与 File Provider 共用的界面语言偏好；未保存偏好时始终跟随系统语言。
public enum MirageAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let storageKey = "app-language"

    public var id: Self { self }

    public var locale: Locale {
        switch self {
        case .system:
            return Self.systemLanguage().locale
        case .simplifiedChinese:
            return Locale(identifier: rawValue)
        case .english:
            return Locale(identifier: rawValue)
        }
    }

    /// 在系统语言偏好中选择 Mirage 支持的首个语言；没有匹配项时沿用原有简体中文界面。
    public static func systemLanguage(
        for preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Self {
        for identifier in preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            if language.languageCode?.identifier == "en" {
                return .english
            }
            if language.languageCode?.identifier == "zh",
               language.script?.identifier == "Hans" {
                return .simplifiedChinese
            }
        }
        return .simplifiedChinese
    }

    /// 旧值、损坏值及首次启动的空值都回到“跟随系统”。
    public static func resolve(_ storedValue: String?) -> Self {
        storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }
}
