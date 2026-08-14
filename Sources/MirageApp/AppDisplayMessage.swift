import Foundation
import MirageCore

/// 面向用户的状态消息明确区分本地固定文案与外部原文，避免把运行时字符串误当成本地化键。
struct AppDisplayMessage: Equatable, Sendable, ExpressibleByStringLiteral {
    enum Argument: Equatable, Sendable {
        case text(String)
        case integer(Int)
        case message(AppDisplayMessage)

        fileprivate func value(locale: Locale, bundle: Bundle) -> any CVarArg {
            switch self {
            case let .text(value):
                return value
            case let .integer(value):
                return value
            case let .message(value):
                return value.resolved(locale: locale, bundle: bundle)
            }
        }
    }

    private enum Storage: Equatable, Sendable {
        case localized(key: String, arguments: [Argument])
        case verbatim(String)
    }

    private let storage: Storage

    /// 字面量只能表示编译期固定文案；运行时字符串必须显式选择 `localized` 或 `verbatim`。
    init(stringLiteral value: String) {
        storage = .localized(key: value, arguments: [])
    }

    static func localized(_ key: StaticString, _ arguments: Argument...) -> Self {
        Self(storage: .localized(key: key.description, arguments: arguments))
    }

    static func verbatim(_ value: String) -> Self {
        Self(storage: .verbatim(value))
    }

    static func joined(_ messages: [Self]) -> Self? {
        guard let first = messages.first else { return nil }
        return messages.dropFirst().reduce(first) { partial, message in
            .localized("%@；%@", .message(partial), .message(message))
        }
    }

    /// SwiftUI 界面与 VoiceOver 共用同一解析入口；调用方传入 Scene 的 locale 即可即时跟随切换。
    func resolved(locale: Locale, bundle: Bundle = .main) -> String {
        switch storage {
        case let .verbatim(value):
            return value
        case let .localized(key, arguments):
            let localizedBundle = Self.localizedBundle(for: locale, in: bundle)
            let format = localizedBundle.localizedString(forKey: key, value: key, table: nil)
            guard !arguments.isEmpty else { return format }
            return String(
                format: format,
                locale: locale,
                arguments: arguments.map { $0.value(locale: locale, bundle: bundle) }
            )
        }
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    private static func localizedBundle(for locale: Locale, in bundle: Bundle) -> Bundle {
        let localizations = bundle.localizations.filter { $0 != "Base" }
        guard let localization = Bundle.preferredLocalizations(
            from: localizations,
            forPreferences: [locale.identifier]
        ).first,
        let path = bundle.path(forResource: localization, ofType: "lproj"),
        let localizedBundle = Bundle(path: path) else {
            return bundle
        }
        return localizedBundle
    }
}

/// 已知业务错误提供结构化本地化；系统及远端返回的未知错误保持原文。
protocol AppDisplayMessageConvertible: Error {
    var appDisplayMessage: AppDisplayMessage { get }
}

extension AppDisplayMessage {
    static func error(_ error: any Error) -> Self {
        if let localizedError = error as? any AppDisplayMessageConvertible {
            return localizedError.appDisplayMessage
        }
        if let photoSourceFailure = error as? any PhotoSourceFailure {
            return PhotoSourceIssue(
                sourceID: photoSourceFailure.sourceID,
                kind: photoSourceFailure.issueKind,
                message: error.localizedDescription,
                retryAt: photoSourceFailure.retryAt
            ).appDisplayMessage
        }
        return .verbatim(error.localizedDescription)
    }
}
