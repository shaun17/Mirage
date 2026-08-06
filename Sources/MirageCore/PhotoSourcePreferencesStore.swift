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

/// 发现页筛选使用同一份 App Group 快照；图片与头像供 File Provider 读取，GIF 仅由 App 使用。
public struct DiscoveryFilterPreferencesSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let photoSourceID: PhotoSourceID?
    public let avatarTypes: Set<AvatarType>
    public let giphyContentTypes: Set<GiphyContentType>

    public init(
        revision: UInt64 = 1,
        photoSourceID: PhotoSourceID? = nil,
        avatarTypes: Set<AvatarType> = Set(AvatarType.allCases),
        giphyContentTypes: Set<GiphyContentType> = Set(GiphyContentType.allCases)
    ) {
        self.revision = max(revision, 1)
        self.photoSourceID = Self.normalizedPhotoSourceID(photoSourceID)
        self.avatarTypes = Self.nonempty(
            avatarTypes.intersection(AvatarType.allCases)
        )
        self.giphyContentTypes = Self.nonempty(
            giphyContentTypes.intersection(GiphyContentType.allCases)
        )
    }

    /// 图片推荐快照只随图片来源选择变化，头像和 GIF 筛选不会无意义地换代。
    public var photoCatalogKey: String {
        "discover-photo-filter-v1:\(photoSourceID?.rawValue ?? "all")"
    }

    /// Finder 只能跟随同时支持自动推荐与 File Provider 的来源。
    /// App 专属来源或已在 Finder 设置中关闭的来源回退为 Finder 的全部可用来源，不能发布空目录。
    public func fileProviderPhotoSourceID(
        enabledSourceIDs: Set<PhotoSourceID>? = nil
    ) -> PhotoSourceID? {
        guard let photoSourceID,
              let descriptor = PhotoSourceRegistry.descriptor(for: photoSourceID),
              descriptor.availability == .available,
              descriptor.supportsAggregatedSearch(
                  on: .fileProvider,
                  purpose: .recommendation
              ),
              enabledSourceIDs?.contains(photoSourceID) ?? true else {
            return nil
        }
        return photoSourceID
    }

    /// Finder 的缓存只按实际生效的来源隔离，不让 App 专属筛选制造无效 generation。
    public func fileProviderPhotoCatalogKey(
        enabledSourceIDs: Set<PhotoSourceID>? = nil
    ) -> String {
        let sourceID = fileProviderPhotoSourceID(enabledSourceIDs: enabledSourceIDs)
        return "provider-photo-filter-v2:\(sourceID?.rawValue ?? "all")"
    }

    /// 头像目录缓存按有序类型集合隔离，切换后不会复用上一个范围的 occurrence。
    public var avatarCatalogKey: String {
        let values = AvatarType.allCases.filter(avatarTypes.contains).map(\.rawValue)
        return "discover-avatar-filter-v1:\(values.joined(separator: ","))"
    }

    private static func normalizedPhotoSourceID(_ sourceID: PhotoSourceID?) -> PhotoSourceID? {
        guard let sourceID,
              let descriptor = PhotoSourceRegistry.descriptor(for: sourceID),
              descriptor.availability == .available,
              descriptor.supportsAggregatedSearch(on: .app, purpose: .interactive) else {
            return nil
        }
        return sourceID
    }

    private static func nonempty<T: Hashable & CaseIterable>(_ values: Set<T>) -> Set<T>
    where T.AllCases: Collection, T.AllCases.Element == T {
        values.isEmpty ? Set(T.allCases) : values
    }
}

/// 非敏感发现页偏好按独立 key 写入共享 defaults；API Key 仍只保存在凭据存储中。
public final class DiscoveryFilterPreferencesStore: @unchecked Sendable {
    private static let revisionKey = "discover-filter-preferences-revision-v1"
    private static let photoSourceKey = "discover-photo-source-filter-v1"
    private static let avatarTypesKey = "discover-avatar-type-filter-v1"
    private static let giphyContentTypesKey = "discover-giphy-content-type-filter-v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(userDefaults: UserDefaults) {
        defaults = userDefaults
    }

    /// 首次升级时只迁移共享容器中尚不存在的旧 App 偏好，之后 App Group 成为唯一来源。
    public static func production(
        legacyDefaults: UserDefaults = .standard
    ) -> DiscoveryFilterPreferencesStore {
        let shared = UserDefaults(suiteName: AppGroupStorage.appGroupIdentifier) ?? legacyDefaults
        let store = DiscoveryFilterPreferencesStore(userDefaults: shared)
        store.migrateMissingValues(from: legacyDefaults)
        return store
    }

    public func snapshot() -> DiscoveryFilterPreferencesSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotWithoutLock()
    }

    @discardableResult
    public func setPhotoSourceID(_ sourceID: PhotoSourceID?) -> DiscoveryFilterPreferencesSnapshot {
        mutate { current in
            DiscoveryFilterPreferencesSnapshot(
                revision: Self.nextRevision(after: current.revision),
                photoSourceID: sourceID,
                avatarTypes: current.avatarTypes,
                giphyContentTypes: current.giphyContentTypes
            )
        }
    }

    @discardableResult
    public func setAvatarTypes(_ types: Set<AvatarType>) -> DiscoveryFilterPreferencesSnapshot {
        mutate { current in
            DiscoveryFilterPreferencesSnapshot(
                revision: Self.nextRevision(after: current.revision),
                photoSourceID: current.photoSourceID,
                avatarTypes: types,
                giphyContentTypes: current.giphyContentTypes
            )
        }
    }

    @discardableResult
    public func setGiphyContentTypes(
        _ types: Set<GiphyContentType>
    ) -> DiscoveryFilterPreferencesSnapshot {
        mutate { current in
            DiscoveryFilterPreferencesSnapshot(
                revision: Self.nextRevision(after: current.revision),
                photoSourceID: current.photoSourceID,
                avatarTypes: current.avatarTypes,
                giphyContentTypes: types
            )
        }
    }

    private func mutate(
        _ update: (DiscoveryFilterPreferencesSnapshot) -> DiscoveryFilterPreferencesSnapshot
    ) -> DiscoveryFilterPreferencesSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let current = snapshotWithoutLock()
        let updated = update(current)
        guard updated.photoSourceID != current.photoSourceID
                || updated.avatarTypes != current.avatarTypes
                || updated.giphyContentTypes != current.giphyContentTypes else {
            return current
        }
        persistWithoutLock(updated)
        return updated
    }

    private func snapshotWithoutLock() -> DiscoveryFilterPreferencesSnapshot {
        let revision = defaults.string(forKey: Self.revisionKey).flatMap(UInt64.init) ?? 1
        let photoSourceID = defaults.string(forKey: Self.photoSourceKey).flatMap(PhotoSourceID.init)
        let avatarTypes = Set(
            defaults.stringArray(forKey: Self.avatarTypesKey)?.compactMap(AvatarType.init) ?? []
        )
        let giphyContentTypes = Set(
            defaults.stringArray(forKey: Self.giphyContentTypesKey)?
                .compactMap(GiphyContentType.init) ?? []
        )
        return DiscoveryFilterPreferencesSnapshot(
            revision: revision,
            photoSourceID: photoSourceID,
            avatarTypes: avatarTypes,
            giphyContentTypes: giphyContentTypes
        )
    }

    private func persistWithoutLock(_ snapshot: DiscoveryFilterPreferencesSnapshot) {
        defaults.set(String(snapshot.revision), forKey: Self.revisionKey)
        defaults.set(snapshot.photoSourceID?.rawValue ?? "all", forKey: Self.photoSourceKey)
        defaults.set(
            AvatarType.allCases.filter(snapshot.avatarTypes.contains).map(\.rawValue),
            forKey: Self.avatarTypesKey
        )
        defaults.set(
            GiphyContentType.allCases.filter(snapshot.giphyContentTypes.contains).map(\.rawValue),
            forKey: Self.giphyContentTypesKey
        )
    }

    private func migrateMissingValues(from legacyDefaults: UserDefaults) {
        guard defaults !== legacyDefaults else { return }
        lock.lock()
        defer { lock.unlock() }
        let keys = [Self.photoSourceKey, Self.avatarTypesKey, Self.giphyContentTypesKey]
        var migrated = false
        for key in keys where defaults.object(forKey: key) == nil {
            guard let value = legacyDefaults.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            migrated = true
        }
        guard migrated else { return }
        let current = snapshotWithoutLock()
        defaults.set(
            String(Self.nextRevision(after: current.revision)),
            forKey: Self.revisionKey
        )
    }

    private static func nextRevision(after revision: UInt64) -> UInt64 {
        revision == .max ? 1 : revision + 1
    }
}
