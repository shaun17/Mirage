import CryptoKit
import Darwin
import Foundation

/// 发现页快照的来源；网络失败时明确标记为确定性兜底数据。
public enum DiscoveryFeedSource: String, Codable, Equatable, Sendable {
    case network
    case fallback
}

/// 根目录推荐头像的持久化提交单元，记录顺序本身就是 Finder 的展示顺序。
public struct DiscoveryFeedSnapshot: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let refreshedAt: Date
    public let records: [RemoteImageRecord]
    public let source: DiscoveryFeedSource
    public let catalogKey: String
    public let queryKey: String

    public init(
        generation: UInt64,
        refreshedAt: Date,
        records: [RemoteImageRecord],
        source: DiscoveryFeedSource,
        catalogKey: String,
        queryKey: String
    ) {
        self.generation = generation
        self.refreshedAt = refreshedAt
        self.records = records
        self.source = source
        self.catalogKey = catalogKey
        self.queryKey = queryKey
    }
}

/// File Provider 某个 occurrence 在变更日志中的稳定状态。
public struct ProviderStoredItemState: Codable, Equatable, Sendable {
    public let identifier: String
    public let fingerprint: String

    public init(identifier: String, fingerprint: String) {
        self.identifier = identifier
        self.fingerprint = fingerprint
    }
}

/// 从一个持久化锚点到当前锚点合并后的净变化。
public struct ProviderStoredChanges: Equatable, Sendable {
    public let anchor: UInt64
    public let deletedIdentifiers: [String]
    public let updatedIdentifiers: [String]

    public init(anchor: UInt64, deletedIdentifiers: [String], updatedIdentifiers: [String]) {
        self.anchor = anchor
        self.deletedIdentifiers = deletedIdentifiers
        self.updatedIdentifiers = updatedIdentifiers
    }
}

/// 读取方提交的锚点已经早于当前 scope 保留的历史窗口。
public enum ProviderChangeStorageError: Error, Equatable, Sendable {
    case anchorExpired
    case invalidAnchor
}

public struct RecentImageRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { image.id }
    public let image: RemoteImageRecord
    public let accessedAt: Date

    public init(image: RemoteImageRecord, accessedAt: Date = Date()) {
        self.image = image
        self.accessedAt = accessedAt
    }
}

/// 主 App 一次性读取或修改后得到的资料库快照，修订号用于拒绝迟到的旧结果。
public struct LibrarySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let favoriteIDs: Set<String>
    public let favorites: [RemoteImageRecord]
    public let recent: [RecentImageRecord]

    public init(
        revision: UInt64,
        favoriteIDs: Set<String>,
        favorites: [RemoteImageRecord],
        recent: [RecentImageRecord]
    ) {
        self.revision = revision
        self.favoriteIDs = favoriteIDs
        self.favorites = favorites
        self.recent = recent
    }
}

public enum AppGroupStorageError: Error, LocalizedError, Sendable {
    case unavailableAppGroup(String)

    public var errorDescription: String? {
        switch self {
        case let .unavailableAppGroup(identifier): return "无法访问 App Group：\(identifier)"
        }
    }
}

/// App 与扩展共享的文件存储。Actor 保护实例内并发，路径锁与 fcntl 保护跨进程事务。
public actor AppGroupStorage {
    public static let appGroupIdentifier = "N4TQ2P9B46.group.com.wenren.Mirage"

    private let fileManager: FileManager
    private let baseURL: URL
    private let itemsURL: URL
    private let recentURL: URL
    private let searchItemsURL: URL
    private let favoritesURL: URL
    private let discoverySnapshotURL: URL
    private let searchBackingURL: URL
    private let providerStateURL: URL
    private let lockDirectoryURL: URL
    private var snapshotRevision: UInt64 = 0
    private static let providerHistoryLimit = 64
    private static let providerSchemaVersion = 1
    private static let favoritesSchemaVersion = 1
    private static let searchBackingSchemaVersion = 1

    /// 测试可传临时目录；生产环境留空后解析固定 App Group。
    public init(baseURL injectedURL: URL? = nil, fileManager: FileManager = .default) throws {
        let resolvedURL: URL
        if let injectedURL {
            resolvedURL = injectedURL
        } else if let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) {
            resolvedURL = groupURL.appendingPathComponent("Mirage", isDirectory: true)
        } else {
            throw AppGroupStorageError.unavailableAppGroup(Self.appGroupIdentifier)
        }
        self.fileManager = fileManager
        self.baseURL = resolvedURL
        self.itemsURL = resolvedURL.appendingPathComponent("items", isDirectory: true)
        self.recentURL = resolvedURL.appendingPathComponent("recent", isDirectory: true)
        self.searchItemsURL = resolvedURL.appendingPathComponent("search-items", isDirectory: true)
        self.favoritesURL = resolvedURL.appendingPathComponent("favorites.json")
        self.discoverySnapshotURL = resolvedURL.appendingPathComponent("discovery-feed.json")
        self.searchBackingURL = resolvedURL.appendingPathComponent("search-backing.json")
        self.providerStateURL = resolvedURL.appendingPathComponent("provider-sync-state.json")
        self.lockDirectoryURL = resolvedURL.appendingPathComponent("locks", isDirectory: true)
        try fileManager.createDirectory(at: itemsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recentURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: searchItemsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: lockDirectoryURL, withIntermediateDirectories: true)
    }

    /// 将一个条目的元数据写进独立 JSON，避免修改共享大文件。
    public func writeItem(_ item: RemoteImageRecord) throws {
        try encode(item).write(to: itemURL(id: item.id), options: .atomic)
    }

    /// 根据稳定 ID 读取单个条目；不存在时返回 nil。
    public func readItem(id: String) throws -> RemoteImageRecord? {
        let url = itemURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decode(RemoteImageRecord.self, from: url)
    }

    /// 读取所有独立条目，忽略系统临时文件但不吞掉损坏 JSON 的错误。
    public func readItems() throws -> [RemoteImageRecord] {
        try jsonFiles(in: itemsURL).map { try decode(RemoteImageRecord.self, from: $0) }
            .sorted { $0.id < $1.id }
    }

    /// 删除指定条目元数据；不存在时保持幂等。
    public func removeItem(id: String) throws {
        let url = itemURL(id: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    /// 读取上次完整提交的发现快照；记录内容直接来自快照，不依赖全局 item 文件。
    public func readDiscoveryFeedSnapshot() throws -> DiscoveryFeedSnapshot? {
        try withExclusiveFileLock(named: "discovery-feed") {
            try readDiscoveryFeedSnapshotUnlocked()
        }
    }

    /// 在跨进程事务中递增 generation 并提交完整记录快照，避免并发提交丢失版本。
    @discardableResult
    public func commitDiscoveryFeed(
        records: [RemoteImageRecord],
        refreshedAt: Date,
        source: DiscoveryFeedSource,
        catalogKey: String,
        queryKey: String
    ) throws -> DiscoveryFeedSnapshot {
        try withExclusiveFileLock(named: "discovery-feed") {
            let nextGeneration = (try readDiscoveryFeedSnapshotUnlocked()?.generation ?? 0) &+ 1
            let snapshot = DiscoveryFeedSnapshot(
                generation: nextGeneration,
                refreshedAt: refreshedAt,
                records: records,
                source: source,
                catalogKey: catalogKey,
                queryKey: queryKey
            )
            try encode(snapshot).write(to: discoverySnapshotURL, options: .atomic)
            return snapshot
        }
    }

    /// 搜索 backing 提交当前顺序，并把每条权威记录独立持久化，旧搜索 occurrence 仍可回查。
    public func commitSearchBacking(queryKey: String, records: [RemoteImageRecord]) throws {
        try Task.checkCancellation()
        try withExclusiveFileLock(named: "search-backing") {
            // 覆盖当前快照前先迁移其中记录，保证升级后的首次新查询也不会丢失旧 occurrence。
            let previous = try readSearchBackingSnapshotUnlocked()
            try persistSearchRecordsUnlocked(previous.records)
            try persistSearchRecordsUnlocked(records)
            let snapshot = SearchBackingSnapshot(
                schemaVersion: Self.searchBackingSchemaVersion,
                queryKey: queryKey,
                records: records,
                committedAt: Date()
            )
            try encode(snapshot).write(to: searchBackingURL, options: .atomic)
        }
    }

    /// 返回快照内的稳定记录顺序；旧 recordIDs 格式会在锁内一次性迁移。
    public func readSearchBackingRecords() throws -> [RemoteImageRecord] {
        try withExclusiveFileLock(named: "search-backing") {
            let snapshot = try readSearchBackingSnapshotUnlocked()
            try persistSearchRecordsUnlocked(snapshot.records)
            return snapshot.records
        }
    }

    /// 按稳定 ID 读取搜索 occurrence 的独立权威记录，不受后续查询替换当前 backing 影响。
    public func readSearchRecord(id: String) throws -> RemoteImageRecord? {
        try withExclusiveFileLock(named: "search-backing") {
            let url = searchItemURL(id: id)
            if fileManager.fileExists(atPath: url.path) {
                return try decode(RemoteImageRecord.self, from: url)
            }
            // 兼容尚未建立逐条索引的旧快照，并在本次读取中完成迁移。
            let record = try readSearchBackingSnapshotUnlocked().records.first { $0.id == id }
            if let record { try persistSearchRecordsUnlocked([record]) }
            return record
        }
    }

    /// 扫描仍可解码的历史元数据，用于首次迁移时删除旧搜索 occurrence，而不删除底层记录。
    public func readRecoverableItemIDs() throws -> [String] {
        try jsonFiles(in: itemsURL).compactMap { url in
            try? decode(RemoteImageRecord.self, from: url).id
        }.sorted()
    }

    /// 比较 scope 的旧新快照并原子追加变更批次；只有真实变化才推进全局 generation。
    @discardableResult
    public func commitProviderScope(
        _ scope: String,
        items: [ProviderStoredItemState],
        initialDeletedIdentifiers: [String] = []
    ) throws -> UInt64 {
        try withExclusiveFileLock(named: "provider-sync-state") {
            var state = try readProviderStateUnlocked()
            var scopeState = state.scopes[scope] ?? ProviderScopeState()
            let oldItems = Dictionary(uniqueKeysWithValues: scopeState.items.map { ($0.identifier, $0) })
            let newItems = Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, $0) })
            var deleted = Set(oldItems.keys).subtracting(newItems.keys)
            if scopeState.hasCommittedSnapshot == false {
                deleted.formUnion(initialDeletedIdentifiers.filter { newItems[$0] == nil })
            }
            let updated = Set(newItems.compactMap { identifier, item in
                oldItems[identifier] == item ? nil : identifier
            })
            scopeState.items = items
            scopeState.hasCommittedSnapshot = true
            guard !deleted.isEmpty || !updated.isEmpty else {
                state.scopes[scope] = scopeState
                try writeProviderStateUnlocked(state)
                return state.generation
            }

            state.generation &+= 1
            scopeState.history.append(
                ProviderChangeBatch(
                    generation: state.generation,
                    deletedIdentifiers: deleted.sorted(),
                    updatedIdentifiers: updated.sorted()
                )
            )
            if scopeState.history.count > Self.providerHistoryLimit {
                let overflow = scopeState.history.count - Self.providerHistoryLimit
                let removed = scopeState.history.prefix(overflow)
                scopeState.minimumValidAnchor = max(
                    scopeState.minimumValidAnchor,
                    removed.last?.generation ?? scopeState.minimumValidAnchor
                )
                scopeState.history.removeFirst(overflow)
            }
            state.scopes[scope] = scopeState
            try writeProviderStateUnlocked(state)
            return state.generation
        }
    }

    /// 合并 anchor 之后的批次；同一 ID 的后续操作覆盖前序操作，得到最终净差异。
    public func providerChanges(in scope: String, after anchor: UInt64) throws -> ProviderStoredChanges {
        try withExclusiveFileLock(named: "provider-sync-state") {
            let state = try readProviderStateUnlocked()
            guard anchor >= state.minimumValidAnchor else {
                throw ProviderChangeStorageError.anchorExpired
            }
            guard anchor <= state.generation else { throw ProviderChangeStorageError.invalidAnchor }
            let scopeState = state.scopes[scope] ?? ProviderScopeState()
            guard anchor >= scopeState.minimumValidAnchor else {
                throw ProviderChangeStorageError.anchorExpired
            }
            var deleted = Set<String>()
            var updated = Set<String>()
            for batch in scopeState.history where batch.generation > anchor {
                for identifier in batch.deletedIdentifiers {
                    updated.remove(identifier)
                    deleted.insert(identifier)
                }
                for identifier in batch.updatedIdentifiers {
                    deleted.remove(identifier)
                    updated.insert(identifier)
                }
            }
            return ProviderStoredChanges(
                anchor: state.generation,
                deletedIdentifiers: deleted.sorted(),
                updatedIdentifiers: updated.sorted()
            )
        }
    }

    /// 当前锚点保存在 App Group 中，因此扩展进程重启不会回到 1。
    public func currentProviderAnchor() throws -> UInt64 {
        try withExclusiveFileLock(named: "provider-sync-state") {
            try readProviderStateUnlocked().generation
        }
    }

    /// 按调用方给出的 ID 顺序重建收藏索引，并保留已有快照中的权威记录。
    public func writeFavoriteIDs(_ ids: [String]) throws {
        try withExclusiveFileLock(named: "favorites") {
            let current = try readFavoriteSnapshotUnlocked()
            let uniqueIDs = Self.uniqueIDs(ids)
            var recordsByID = Self.recordsByID(current.records)
            for id in uniqueIDs where recordsByID[id] == nil {
                recordsByID[id] = try readItem(id: id)
            }
            let snapshot = FavoriteSnapshot(
                schemaVersion: Self.favoritesSchemaVersion,
                recordIDs: uniqueIDs,
                records: uniqueIDs.compactMap { recordsByID[$0] }
            )
            try writeFavoriteSnapshotUnlocked(snapshot)
        }
    }

    /// 收藏文件尚未创建时按空集合处理；旧 [String] 文件会原位迁移为记录快照。
    public func readFavoriteIDs() throws -> [String] {
        try withExclusiveFileLock(named: "favorites") {
            try readFavoriteSnapshotUnlocked().recordIDs
        }
    }

    /// 返回收藏快照内的权威元数据，不再通过共享 items 目录回查。
    public func readFavoriteRecords() throws -> [RemoteImageRecord] {
        try withExclusiveFileLock(named: "favorites") {
            let snapshot = try readFavoriteSnapshotUnlocked()
            let recordsByID = Self.recordsByID(snapshot.records)
            return snapshot.recordIDs.compactMap { recordsByID[$0] }
        }
    }

    /// 原子读取收藏与最近使用；收藏元数据直接来自 favorites 记录快照。
    public func readLibrarySnapshot(recentLimit: Int = 100) throws -> LibrarySnapshot {
        try withExclusiveFileLock(named: "favorites") {
            let favorites = try readFavoriteSnapshotUnlocked()
            return try makeLibrarySnapshot(favorites: favorites, recentLimit: recentLimit)
        }
    }

    /// 在跨进程锁内完成“读取—切换—落盘—返回快照”，避免多个实例相互覆盖。
    public func toggleFavorite(
        _ item: RemoteImageRecord,
        recentLimit: Int = 100
    ) throws -> LibrarySnapshot {
        try withExclusiveFileLock(named: "favorites") {
            let current = try readFavoriteSnapshotUnlocked()
            var ids = current.recordIDs
            var recordsByID = Self.recordsByID(current.records)
            if let existingIndex = ids.firstIndex(of: item.id) {
                ids.remove(at: existingIndex)
                recordsByID.removeValue(forKey: item.id)
            } else {
                ids.append(item.id)
                recordsByID[item.id] = item
                try writeItem(item)
            }
            let snapshot = FavoriteSnapshot(
                schemaVersion: Self.favoritesSchemaVersion,
                recordIDs: ids,
                records: ids.compactMap { recordsByID[$0] }
            )
            try writeFavoriteSnapshotUnlocked(snapshot)
            return try makeLibrarySnapshot(favorites: snapshot, recentLimit: recentLimit)
        }
    }

    /// 在跨进程事务中完成最近记录写入与裁剪，避免多实例 TOCTOU 和误删新记录。
    public func writeRecent(_ image: RemoteImageRecord, at date: Date = Date(), limit: Int = 100) throws {
        try Task.checkCancellation()
        try writeItem(image)
        try withExclusiveFileLock(named: "recent") {
            let record = RecentImageRecord(image: image, accessedAt: date)
            try encode(record).write(to: recentItemURL(id: image.id), options: .atomic)
            try pruneRecentUnlocked(to: max(limit, 0))
        }
    }

    /// 最近记录按访问时间倒序，时间相同时使用稳定 ID 保证顺序固定。
    public func readRecent(limit: Int = 100) throws -> [RecentImageRecord] {
        try withExclusiveFileLock(named: "recent") {
            try readRecentUnlocked(limit: limit)
        }
    }

    /// 删除一条最近记录，不影响条目元数据或收藏状态。
    public func removeRecent(id: String) throws {
        try withExclusiveFileLock(named: "recent") {
            try removeRecentUnlocked(id: id)
        }
    }

    /// 使用 ID 摘要作为文件名，避免冒号和外部文字进入路径。
    private func itemURL(id: String) -> URL {
        itemsURL.appendingPathComponent(Self.fileKey(id) + ".json")
    }

    /// recent 与 items 使用同一命名规则，但位于独立目录。
    private func recentItemURL(id: String) -> URL {
        recentURL.appendingPathComponent(Self.fileKey(id) + ".json")
    }

    /// 搜索 occurrence 的权威记录使用独立目录，避免当前 query 快照替换后无法回查。
    private func searchItemURL(id: String) -> URL {
        searchItemsURL.appendingPathComponent(Self.fileKey(id) + ".json")
    }

    /// 调用方持有 recent 锁时读取、排序并截取最近记录。
    private func readRecentUnlocked(limit: Int) throws -> [RecentImageRecord] {
        let sorted = try allRecentUnlocked().sorted {
            $0.accessedAt == $1.accessedAt ? $0.id < $1.id : $0.accessedAt > $1.accessedAt
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    /// 对超出上限的最旧记录逐条删除；调用方必须持有 recent 锁。
    private func pruneRecentUnlocked(to limit: Int) throws {
        let records = try readRecentUnlocked(limit: .max)
        for record in records.dropFirst(limit) { try removeRecentUnlocked(id: record.id) }
    }

    /// 删除单条最近记录；调用方必须持有 recent 锁以保护枚举—删除事务。
    private func removeRecentUnlocked(id: String) throws {
        let url = recentItemURL(id: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    /// 解码全部最近记录供锁内排序与清理使用。
    private func allRecentUnlocked() throws -> [RecentImageRecord] {
        try jsonFiles(in: recentURL).map { try decode(RecentImageRecord.self, from: $0) }
    }

    /// 生成内部一致的快照，并为每次读取或事务提交分配单调递增修订号。
    private func makeLibrarySnapshot(
        favorites: FavoriteSnapshot,
        recentLimit: Int
    ) throws -> LibrarySnapshot {
        let recordsByID = Self.recordsByID(favorites.records)
        let favoriteItems = favorites.recordIDs.compactMap { recordsByID[$0] }
        let recentItems = try readRecent(limit: recentLimit)
        snapshotRevision += 1
        return LibrarySnapshot(
            revision: snapshotRevision,
            favoriteIDs: Set(favorites.recordIDs),
            favorites: favoriteItems,
            recent: recentItems
        )
    }

    /// 未持有锁时读取发现快照，仅供已经建立事务边界的公开方法调用。
    private func readDiscoveryFeedSnapshotUnlocked() throws -> DiscoveryFeedSnapshot? {
        guard fileManager.fileExists(atPath: discoverySnapshotURL.path) else { return nil }
        return try decode(DiscoveryFeedSnapshot.self, from: discoverySnapshotURL)
    }

    /// 读取搜索记录快照，并把旧 recordIDs 索引一次性升级为内嵌记录。
    private func readSearchBackingSnapshotUnlocked() throws -> SearchBackingSnapshot {
        guard fileManager.fileExists(atPath: searchBackingURL.path) else {
            return SearchBackingSnapshot(
                schemaVersion: Self.searchBackingSchemaVersion,
                queryKey: "",
                records: [],
                committedAt: .distantPast
            )
        }
        let data = try Data(contentsOf: searchBackingURL)
        let currentError: Error
        do {
            let snapshot = try decode(SearchBackingSnapshot.self, from: data)
            guard snapshot.schemaVersion == Self.searchBackingSchemaVersion else {
                throw StorageSnapshotValidationError.unsupportedSchema
            }
            return snapshot
        } catch {
            currentError = error
        }

        do {
            let legacy = try decode(LegacySearchBackingSnapshot.self, from: data)
            let records = try legacy.recordIDs.compactMap { try readItem(id: $0) }
            let migrated = SearchBackingSnapshot(
                schemaVersion: Self.searchBackingSchemaVersion,
                queryKey: legacy.queryKey,
                records: records,
                committedAt: legacy.committedAt
            )
            try encode(migrated).write(to: searchBackingURL, options: .atomic)
            return migrated
        } catch {
            throw currentError
        }
    }

    /// 原子写入搜索专属逐条记录；调用方必须持有 search-backing 锁。
    private func persistSearchRecordsUnlocked(_ records: [RemoteImageRecord]) throws {
        for record in records {
            try encode(record).write(to: searchItemURL(id: record.id), options: .atomic)
        }
    }

    /// 读取收藏记录快照，并把旧 [String] 索引一次性升级为内嵌记录。
    private func readFavoriteSnapshotUnlocked() throws -> FavoriteSnapshot {
        guard fileManager.fileExists(atPath: favoritesURL.path) else {
            return FavoriteSnapshot(
                schemaVersion: Self.favoritesSchemaVersion,
                recordIDs: [],
                records: []
            )
        }
        let data = try Data(contentsOf: favoritesURL)
        let currentError: Error
        do {
            let snapshot = try decode(FavoriteSnapshot.self, from: data)
            guard snapshot.schemaVersion == Self.favoritesSchemaVersion else {
                throw StorageSnapshotValidationError.unsupportedSchema
            }
            return snapshot
        } catch {
            currentError = error
        }

        do {
            let legacyIDs = Self.uniqueIDs(try decode([String].self, from: data))
            let records = try legacyIDs.compactMap { try readItem(id: $0) }
            let migrated = FavoriteSnapshot(
                schemaVersion: Self.favoritesSchemaVersion,
                recordIDs: legacyIDs,
                records: records
            )
            try writeFavoriteSnapshotUnlocked(migrated)
            return migrated
        } catch {
            throw currentError
        }
    }

    /// 原子替换收藏快照；调用方必须已经持有 favorites 锁。
    private func writeFavoriteSnapshotUnlocked(_ snapshot: FavoriteSnapshot) throws {
        try encode(snapshot).write(to: favoritesURL, options: .atomic)
    }

    /// 按首次出现去重，保持 Finder 与主 App 已经观察到的稳定顺序。
    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// 为记录快照建立安全索引，重复 ID 保留首次出现的权威内容。
    private static func recordsByID(_ records: [RemoteImageRecord]) -> [String: RemoteImageRecord] {
        var result: [String: RemoteImageRecord] = [:]
        for record in records where result[record.id] == nil {
            result[record.id] = record
        }
        return result
    }

    /// 仅枚举最终 JSON 文件，原子写入过程中的临时文件不会被读取。
    private func jsonFiles(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    /// 每次创建编码器，避免共享可变 Foundation 对象跨隔离域传播。
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// 从磁盘完整读取后再解码；原子替换保证不会看到半个 JSON。
    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// 从已有 Data 解码，供格式迁移和损坏恢复复用同一套 JSON 规则。
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// provider 状态首次创建时从 1 开始；损坏或旧 schema 会归档并重建锚点纪元。
    private func readProviderStateUnlocked() throws -> ProviderPersistentState {
        guard fileManager.fileExists(atPath: providerStateURL.path) else {
            return ProviderPersistentState(
                schemaVersion: Self.providerSchemaVersion,
                generation: 1,
                minimumValidAnchor: 0,
                scopes: [:]
            )
        }
        let data = try Data(contentsOf: providerStateURL)
        do {
            let state = try decode(ProviderPersistentState.self, from: data)
            try validateProviderState(state)
            return state
        } catch {
            return try recoverProviderState(from: data, decodingError: error)
        }
    }

    /// 整个锚点状态是一个小型事务文件，原子替换保证 generation 与批次同步落盘。
    private func writeProviderStateUnlocked(_ state: ProviderPersistentState) throws {
        try encode(state).write(to: providerStateURL, options: .atomic)
    }

    /// 校验 schema 与锚点边界，避免语义损坏的 JSON 被当作有效差异历史。
    private func validateProviderState(_ state: ProviderPersistentState) throws {
        guard state.schemaVersion == Self.providerSchemaVersion else {
            throw StorageSnapshotValidationError.unsupportedSchema
        }
        guard state.minimumValidAnchor <= state.generation else {
            throw StorageSnapshotValidationError.invalidProviderState
        }
        for scope in state.scopes.values {
            guard scope.minimumValidAnchor <= state.generation else {
                throw StorageSnapshotValidationError.invalidProviderState
            }
            var previousGeneration: UInt64 = 0
            for batch in scope.history {
                guard batch.generation > previousGeneration,
                      batch.generation <= state.generation else {
                    throw StorageSnapshotValidationError.invalidProviderState
                }
                previousGeneration = batch.generation
            }
        }
    }

    /// 保存原始坏文件并创建新锚点下界，使旧锚点明确过期且允许重新全量枚举。
    private func recoverProviderState(
        from data: Data,
        decodingError: Error
    ) throws -> ProviderPersistentState {
        let recoveredAnchor = providerRecoveryAnchor(from: data)
        let recovered = ProviderPersistentState(
            schemaVersion: Self.providerSchemaVersion,
            generation: recoveredAnchor,
            minimumValidAnchor: recoveredAnchor,
            scopes: [:]
        )
        archiveInvalidProviderState(data, decodingError: decodingError)
        try writeProviderStateUnlocked(recovered)
        return recovered
    }

    /// 使用时钟高水位并尽量提取旧 generation，确保正常历史中的旧锚点都落在恢复边界之前。
    private func providerRecoveryAnchor(from data: Data) -> UInt64 {
        let clockValue = max(Date().timeIntervalSince1970 * 1_000_000, 2)
        let clockAnchor = UInt64(clockValue)
        guard let previous = try? decode(ProviderGenerationEnvelope.self, from: data).generation,
              previous < UInt64.max else {
            return clockAnchor
        }
        return max(clockAnchor, previous + 1)
    }

    /// 归档字节保持原样；归档失败写系统日志，但不让可恢复状态永久卡死。
    private func archiveInvalidProviderState(_ data: Data, decodingError: Error) {
        let timestamp = UInt64(max(Date().timeIntervalSince1970 * 1_000, 0))
        let archiveURL = baseURL.appendingPathComponent(
            "provider-sync-state.invalid-\(timestamp)-\(UUID().uuidString).json"
        )
        do {
            try data.write(to: archiveURL, options: .atomic)
        } catch {
            NSLog(
                "Mirage provider 状态归档失败：%@；原始解码错误：%@",
                String(describing: error),
                String(describing: decodingError)
            )
        }
    }

    /// 对稳定 sidecar 文件加独占锁，覆盖完整同步事务且不会在锁内发生 await。
    private func withExclusiveFileLock<T>(
        named name: String,
        _ transaction: () throws -> T
    ) throws -> T {
        let lockURL = lockDirectoryURL.appendingPathComponent(name + ".lock")
        let processLock = ProcessFileLockRegistry.shared.lock(for: lockURL.path)
        processLock.lock()
        defer { processLock.unlock() }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            try acquireExclusiveLock(descriptor)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        defer { releaseFileLock(descriptor) }
        return try transaction()
    }

    /// fcntl 负责跨进程阻塞；进程内实例竞争已由路径级 NSLock 串行化。
    private func acquireExclusiveLock(_ descriptor: Int32) throws {
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) == -1 {
            guard errno == EINTR else { throw currentPOSIXError() }
        }
    }

    /// 释放锁并关闭描述符；defer 保证事务抛错时也不会遗留进程锁。
    private func releaseFileLock(_ descriptor: Int32) {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while Darwin.fcntl(descriptor, F_SETLK, &lock) == -1, errno == EINTR {}
        _ = Darwin.close(descriptor)
    }

    /// 把当前 errno 转为 Foundation 可传播的类型化错误。
    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// SHA-256 文件键固定长度且不泄露原始 ID。
    private static func fileKey(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// fcntl 锁属于进程而非线程，因此同进程的多个 storage 实例还需共享路径级互斥锁。
private final class ProcessFileLockRegistry: @unchecked Sendable {
    static let shared = ProcessFileLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    /// 返回并长期保留指定路径的唯一锁对象，确保所有 actor 实例竞争同一把锁。
    func lock(for path: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[path] { return existing }
        let created = NSLock()
        locks[path] = created
        return created
    }
}

/// 收藏索引同时保存顺序与记录快照，recordIDs 仅承担顺序和旧 API 兼容。
private struct FavoriteSnapshot: Codable {
    let schemaVersion: Int
    let recordIDs: [String]
    let records: [RemoteImageRecord]
}

/// 最近一次搜索的持久化快照；记录内容不再依赖共享 items 文件。
private struct SearchBackingSnapshot: Codable {
    let schemaVersion: Int
    let queryKey: String
    let records: [RemoteImageRecord]
    let committedAt: Date
}

/// 旧版搜索文件只保存 ID，首次读取时从 legacy items 回填一次并升级。
private struct LegacySearchBackingSnapshot: Codable {
    let queryKey: String
    let recordIDs: [String]
    let committedAt: Date
}

/// 所有 scope 共享一个单调 generation，每个 scope 独立保留差异历史。
private struct ProviderPersistentState: Codable {
    var schemaVersion: Int
    var generation: UInt64
    var minimumValidAnchor: UInt64
    var scopes: [String: ProviderScopeState]
}

/// 即使完整 schema 无法解码，也尽量从旧文件提取 generation 建立更高恢复边界。
private struct ProviderGenerationEnvelope: Decodable {
    let generation: UInt64
}

/// 持久化 JSON 虽可解码但不符合当前语义时触发受控恢复。
private enum StorageSnapshotValidationError: Error {
    case unsupportedSchema
    case invalidProviderState
}

/// scope 的当前快照与有限历史共同支持 old-new 删除和元数据更新。
private struct ProviderScopeState: Codable {
    var items: [ProviderStoredItemState] = []
    var history: [ProviderChangeBatch] = []
    var minimumValidAnchor: UInt64 = 0
    var hasCommittedSnapshot = false
}

/// 单次提交产生的删除和更新集合，新增条目也属于更新。
private struct ProviderChangeBatch: Codable {
    let generation: UInt64
    let deletedIdentifiers: [String]
    let updatedIdentifiers: [String]
}
