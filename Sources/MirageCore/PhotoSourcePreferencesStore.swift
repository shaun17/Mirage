import Foundation

public struct PhotoSourcePreferencesSnapshot: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let appSourceIDs: [PhotoSourceID]
    public let fileProviderSourceIDs: [PhotoSourceID]

    public init(
        revision: UInt64 = 1,
        appSourceIDs: [PhotoSourceID] = [.openverse],
        fileProviderSourceIDs: [PhotoSourceID] = [.openverse]
    ) {
        self.revision = max(revision, 1)
        self.appSourceIDs = Self.normalized(appSourceIDs, surface: .app)
        self.fileProviderSourceIDs = Self.normalized(fileProviderSourceIDs, surface: .fileProvider)
    }

    public func sourceIDs(for surface: PhotoSourceSurface) -> [PhotoSourceID] {
        surface == .app ? appSourceIDs : fileProviderSourceIDs
    }

    private static func normalized(
        _ sourceIDs: [PhotoSourceID],
        surface: PhotoSourceSurface
    ) -> [PhotoSourceID] {
        var seen = Set<PhotoSourceID>()
        let requested = Set(sourceIDs)
        return PhotoSourceRegistry.descriptors.compactMap { descriptor in
            guard requested.contains(descriptor.id), descriptor.supports(surface),
                  seen.insert(descriptor.id).inserted else { return nil }
            return descriptor.id
        }
    }
}

public enum PhotoSourcePreferencesError: Error, LocalizedError, Equatable, Sendable {
    case unavailableAppGroup
    case sourceUnavailable
    case unsupportedSurface
    case noEnabledSources(PhotoSourceSurface)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .unavailableAppGroup: return "无法访问图片数据源共享设置。"
        case .sourceUnavailable: return "该图片数据源正在适配。"
        case .unsupportedSurface: return "该图片数据源不支持当前使用范围。"
        case .noEnabledSources: return "至少需要保留一个图片数据源。"
        case .encoding: return "无法保存图片数据源设置。"
        }
    }
}

public protocol PhotoSourcePreferencesReading: Sendable {
    func snapshot() async -> PhotoSourcePreferencesSnapshot
    func configurationKey(for surface: PhotoSourceSurface) async -> String
}

/// App 与扩展通过 App Group defaults 共享非敏感选择；API Key 永不进入这里。
public actor PhotoSourcePreferencesStore: PhotoSourcePreferencesReading {
    private static let storageKey = "photo-source-preferences-v1"
    private let defaults: UserDefaults

    public init(suiteName: String = AppGroupStorage.appGroupIdentifier) throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PhotoSourcePreferencesError.unavailableAppGroup
        }
        self.defaults = defaults
    }

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
    }

    public func snapshot() -> PhotoSourcePreferencesSnapshot {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(PhotoSourcePreferencesSnapshot.self, from: data) else {
            return PhotoSourcePreferencesSnapshot()
        }
        return PhotoSourcePreferencesSnapshot(
            revision: decoded.revision,
            appSourceIDs: decoded.appSourceIDs,
            fileProviderSourceIDs: decoded.fileProviderSourceIDs
        )
    }

    public func configurationKey(for surface: PhotoSourceSurface) -> String {
        let value = snapshot()
        let ids = value.sourceIDs(for: surface).map(\.rawValue).joined(separator: ",")
        return "photo-sources-v1:\(surface.rawValue):\(value.revision):\(ids)"
    }

    @discardableResult
    public func setEnabled(
        _ enabled: Bool,
        sourceID: PhotoSourceID,
        surface: PhotoSourceSurface
    ) throws -> PhotoSourcePreferencesSnapshot {
        guard PhotoSourceRegistry.descriptor(for: sourceID)?.supports(surface) == true else {
            throw PhotoSourcePreferencesError.unsupportedSurface
        }
        let current = snapshot()
        var ids = current.sourceIDs(for: surface)
        if enabled {
            if !ids.contains(sourceID) { ids.append(sourceID) }
        } else {
            ids.removeAll { $0 == sourceID }
            guard !ids.isEmpty else { throw PhotoSourcePreferencesError.noEnabledSources(surface) }
        }
        guard ids != current.sourceIDs(for: surface) else { return current }
        let updated = makeSnapshot(from: current, replacing: ids, surface: surface)
        try persist(updated)
        return updated
    }

    /// 一次提交某个供应商的全部使用范围，避免 Settings 的单次保存产生半完成状态或多次 revision。
    @discardableResult
    public func saveConfiguration(
        for sourceID: PhotoSourceID,
        enabledSurfaces: Set<PhotoSourceSurface>,
        invalidateConfiguration: Bool = false
    ) throws -> PhotoSourcePreferencesSnapshot {
        guard let descriptor = PhotoSourceRegistry.descriptor(for: sourceID) else {
            throw PhotoSourcePreferencesError.sourceUnavailable
        }
        guard descriptor.availability == .available else {
            throw PhotoSourcePreferencesError.sourceUnavailable
        }
        guard enabledSurfaces.isSubset(of: descriptor.supportedSurfaces) else {
            throw PhotoSourcePreferencesError.unsupportedSurface
        }

        let current = snapshot()
        let appIDs = descriptor.supports(.app)
            ? Self.sourceIDs(
                current.appSourceIDs,
                updating: sourceID,
                enabled: enabledSurfaces.contains(.app)
            )
            : current.appSourceIDs
        let fileProviderIDs = descriptor.supports(.fileProvider)
            ? Self.sourceIDs(
                current.fileProviderSourceIDs,
                updating: sourceID,
                enabled: enabledSurfaces.contains(.fileProvider)
            )
            : current.fileProviderSourceIDs

        guard !appIDs.isEmpty else {
            throw PhotoSourcePreferencesError.noEnabledSources(.app)
        }
        guard !fileProviderIDs.isEmpty else {
            throw PhotoSourcePreferencesError.noEnabledSources(.fileProvider)
        }
        let didChangeSources = appIDs != current.appSourceIDs
            || fileProviderIDs != current.fileProviderSourceIDs
        guard didChangeSources || invalidateConfiguration else { return current }

        let updated = PhotoSourcePreferencesSnapshot(
            revision: Self.nextRevision(after: current.revision),
            appSourceIDs: appIDs,
            fileProviderSourceIDs: fileProviderIDs
        )
        try persist(updated)
        return updated
    }

    /// 保存、替换或移除凭据后推进版本，使旧搜索游标和快照明确失效。
    @discardableResult
    public func advanceRevision() throws -> PhotoSourcePreferencesSnapshot {
        let current = snapshot()
        let updated = PhotoSourcePreferencesSnapshot(
            revision: Self.nextRevision(after: current.revision),
            appSourceIDs: current.appSourceIDs,
            fileProviderSourceIDs: current.fileProviderSourceIDs
        )
        try persist(updated)
        return updated
    }

    @discardableResult
    public func disableEverywhere(_ sourceID: PhotoSourceID) throws -> PhotoSourcePreferencesSnapshot {
        let current = snapshot()
        let appIDs = Self.nonemptySourceIDs(
            current.appSourceIDs.filter { $0 != sourceID },
            surface: .app,
            excluding: sourceID
        )
        let fileProviderIDs = Self.nonemptySourceIDs(
            current.fileProviderSourceIDs.filter { $0 != sourceID },
            surface: .fileProvider,
            excluding: sourceID
        )
        let updated = PhotoSourcePreferencesSnapshot(
            revision: Self.nextRevision(after: current.revision),
            appSourceIDs: appIDs,
            fileProviderSourceIDs: fileProviderIDs
        )
        try persist(updated)
        return updated
    }

    private func makeSnapshot(
        from current: PhotoSourcePreferencesSnapshot,
        replacing ids: [PhotoSourceID],
        surface: PhotoSourceSurface
    ) -> PhotoSourcePreferencesSnapshot {
        PhotoSourcePreferencesSnapshot(
            revision: Self.nextRevision(after: current.revision),
            appSourceIDs: surface == .app ? ids : current.appSourceIDs,
            fileProviderSourceIDs: surface == .fileProvider ? ids : current.fileProviderSourceIDs
        )
    }

    private func persist(_ value: PhotoSourcePreferencesSnapshot) throws {
        guard let data = try? JSONEncoder().encode(value) else {
            throw PhotoSourcePreferencesError.encoding
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func nextRevision(after revision: UInt64) -> UInt64 {
        revision == .max ? 1 : revision + 1
    }

    private static func sourceIDs(
        _ current: [PhotoSourceID],
        updating sourceID: PhotoSourceID,
        enabled: Bool
    ) -> [PhotoSourceID] {
        if enabled {
            return current.contains(sourceID) ? current : current + [sourceID]
        }
        return current.filter { $0 != sourceID }
    }

    /// 删除凭据不能留下空配置；优先恢复注册表中第一个仍受支持的无凭据来源。
    private static func nonemptySourceIDs(
        _ sourceIDs: [PhotoSourceID],
        surface: PhotoSourceSurface,
        excluding removedSourceID: PhotoSourceID
    ) -> [PhotoSourceID] {
        guard sourceIDs.isEmpty else { return sourceIDs }
        let fallback = PhotoSourceRegistry.descriptors.first {
            $0.id != removedSourceID
                && $0.supports(surface)
                && $0.credentialRequirement == .none
        }
        return fallback.map { [$0.id] } ?? []
    }
}
