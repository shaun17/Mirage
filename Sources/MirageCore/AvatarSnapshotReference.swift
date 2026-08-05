import Foundation

/// 指向 App Group 中已冻结头像内容的受限地址；URL 不暴露真实文件路径。
public struct AvatarSnapshotReference: Hashable, Sendable {
    public static let scheme = "mirage-avatar-snapshot"
    private static let host = "avatar"

    public let key: String

    public init?(key: String) {
        guard Self.isValidKey(key) else { return nil }
        self.key = key
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme,
              components.host == Self.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let key = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard components.path == "/\(key)", Self.isValidKey(key) else { return nil }
        self.key = key
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/\(key)"
        return components.url!
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy { character in
            ("0"..."9").contains(character) || ("a"..."f").contains(character)
        }
    }
}

public enum AvatarSnapshotStorageError: Error, Equatable, LocalizedError, Sendable {
    case invalidKey
    case dataTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidPNG

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "头像快照标识无效。"
        case let .dataTooLarge(actualBytes, maximumBytes):
            return "头像快照超过大小限制（\(actualBytes) / \(maximumBytes) 字节）。"
        case .invalidPNG:
            return "头像快照不是有效的 PNG 数据。"
        }
    }
}
