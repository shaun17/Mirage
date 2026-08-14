import Foundation
import MirageCore

/// File Provider 不能继承 SwiftUI 的 locale 环境，因此直接读取共享语言偏好和扩展自身资源。
struct ProviderLocalization {
    static var current: ProviderLocalization { ProviderLocalization() }

    private let bundle: Bundle
    private let defaults: UserDefaults?
    private let preferredLanguages: @Sendable () -> [String]

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults? = UserDefaults(
            suiteName: AppGroupStorage.appGroupIdentifier
        ),
        preferredLanguages: @escaping @Sendable () -> [String] = {
            Locale.preferredLanguages
        }
    ) {
        self.bundle = bundle
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
    }

    /// 不缓存结果：App 改写 App Group 偏好后，下一次枚举或错误构造即可使用新语言。
    var resolvedLanguage: MirageAppLanguage {
        switch MirageAppLanguage.resolve(
            defaults?.string(forKey: MirageAppLanguage.storageKey)
        ) {
        case .system:
            return MirageAppLanguage.systemLanguage(for: preferredLanguages())
        case .simplifiedChinese:
            return .simplifiedChinese
        case .english:
            return .english
        }
    }

    func string(_ key: String) -> String {
        localizedFormat(for: key, language: resolvedLanguage)
    }

    func string(_ key: String, _ arguments: any CVarArg...) -> String {
        let language = resolvedLanguage
        return String(
            format: localizedFormat(for: key, language: language),
            locale: language.locale,
            arguments: arguments
        )
    }

    /// 测试 bundle 没有扩展资源时直接返回中文 key，避免依赖测试宿主的系统语言。
    private func localizedFormat(
        for key: String,
        language: MirageAppLanguage
    ) -> String {
        guard let resourceURL = bundle.url(
            forResource: language.rawValue,
            withExtension: "lproj"
        ), let languageBundle = Bundle(url: resourceURL) else {
            return key
        }
        return languageBundle.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }
}
