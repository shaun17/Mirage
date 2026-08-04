import Foundation

public protocol PhotoSourceCredentialReading: Sendable {
    func credential(for sourceID: PhotoSourceID) async throws -> String?
}

public protocol PhotoSourceCredentialStoring: PhotoSourceCredentialReading {
    func store(_ credential: String, for sourceID: PhotoSourceID) async throws
    func removeCredential(for sourceID: PhotoSourceID) async throws
}

public enum PhotoSourceCredentialError: Error, LocalizedError, Equatable, Sendable {
    case emptyCredential
    case invalidEncoding
    case unavailableStorage
    case corruptStorage
    case persistence

    public var errorDescription: String? {
        switch self {
        case .emptyCredential: return "API Key 不能为空。"
        case .invalidEncoding: return "无法读取已保存的 API Key。"
        case .unavailableStorage: return "无法访问图片数据源持久数据。"
        case .corruptStorage: return "图片数据源持久数据已损坏。"
        case .persistence: return "无法保存图片数据源设置。"
        }
    }
}

/// API Key 保存在 App Group 的应用持久数据中，主 App 与 File Provider 读取同一份文件。
public actor AppGroupPhotoSourceCredentialStore: PhotoSourceCredentialStoring {
    private struct Payload: Codable {
        static let currentVersion = 1

        let version: Int
        var values: [String: String]

        static let empty = Payload(version: currentVersion, values: [:])
    }

    private static let maximumFileSize = 64 * 1_024
    private static let maximumCredentialLength = 8 * 1_024

    private let fileManager: FileManager
    private let fileURL: URL?

    public init(baseURL: URL? = nil) {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        let root = baseURL ?? fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
        )?
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("Mirage", isDirectory: true)
        self.fileURL = root?.appendingPathComponent(
            "photo-source-credentials-v1.json",
            isDirectory: false
        )
    }

    public func credential(for sourceID: PhotoSourceID) async throws -> String? {
        try load().values[sourceID.rawValue]
    }

    public func store(_ credential: String, for sourceID: PhotoSourceID) async throws {
        let normalized = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw PhotoSourceCredentialError.emptyCredential }
        guard normalized.utf8.count <= Self.maximumCredentialLength else {
            throw PhotoSourceCredentialError.invalidEncoding
        }
        var payload = try load()
        payload.values[sourceID.rawValue] = normalized
        try persist(payload)
    }

    public func removeCredential(for sourceID: PhotoSourceID) async throws {
        var payload = try load()
        guard payload.values.removeValue(forKey: sourceID.rawValue) != nil else { return }
        try persist(payload)
    }

    private func load() throws -> Payload {
        guard let fileURL else { throw PhotoSourceCredentialError.unavailableStorage }
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size >= 0,
                  size <= Self.maximumFileSize else {
                throw PhotoSourceCredentialError.corruptStorage
            }
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.version == Payload.currentVersion,
                  payload.values.keys.allSatisfy({ PhotoSourceID(rawValue: $0) != nil }),
                  payload.values.values.allSatisfy({
                      !$0.isEmpty && $0.utf8.count <= Self.maximumCredentialLength
                  }) else {
                throw PhotoSourceCredentialError.corruptStorage
            }
            return payload
        } catch let error as PhotoSourceCredentialError {
            throw error
        } catch {
            throw PhotoSourceCredentialError.corruptStorage
        }
    }

    private func persist(_ payload: Payload) throws {
        guard let fileURL else { throw PhotoSourceCredentialError.unavailableStorage }
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(payload)
            guard data.count <= Self.maximumFileSize else {
                throw PhotoSourceCredentialError.persistence
            }
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch let error as PhotoSourceCredentialError {
            throw error
        } catch {
            throw PhotoSourceCredentialError.persistence
        }
    }
}
