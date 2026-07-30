import FileProvider
import Foundation

/// 根据目录范围构造父子一致的 File Provider 树。
struct ProviderCatalog: Sendable {
    let repository: ProviderRepository

    /// 根目录始终公开两个可见目录，并附带一个系统隐藏的 Spotlight backing 容器。
    func rootDirectories() -> [ProviderItem] {
        [
            ProviderItem(
                directory: ProviderIdentifiers.recent,
                parent: .rootContainer,
                name: "最近使用"
            ),
            ProviderItem(
                directory: ProviderIdentifiers.favorites,
                parent: .rootContainer,
                name: "收藏"
            ),
            ProviderItem(
                directory: ProviderIdentifiers.searchBacking,
                parent: .rootContainer,
                name: "_SearchBacking",
                hidden: true
            )
        ]
    }

    /// 为给定范围读取当前全量快照。
    func items(for scope: ProviderEnumerationScope) async throws -> [ProviderItem] {
        let items: [ProviderItem]
        switch scope {
        case .root:
            items = rootDirectories() + (try await repository.discoveryItems())
        case .search:
            items = try await repository.cachedSearchItems()
        case .recent:
            items = try await repository.recentItems()
        case .favorites:
            items = try await repository.favoriteItems()
        case .workingSet:
            async let discovery = repository.discoveryItems()
            async let recent = repository.recentItems()
            async let favorites = repository.favoriteItems()
            async let search = repository.cachedSearchItems()
            let values = try await (discovery, recent, favorites, search)
            // working set 包含所有 occurrence 及其父目录，同一 record 在不同视图仍保持独立 ID。
            items = rootDirectories() + values.0 + values.1 + values.2 + values.3
        case let .single(identifier):
            items = try await item(for: identifier).map { [$0] } ?? []
        }
        try Task.checkCancellation()
        return items
    }

    /// 把系统回查的稳定标识解析为完整条目。
    func item(for identifier: NSFileProviderItemIdentifier) async throws -> ProviderItem? {
        try Task.checkCancellation()
        switch identifier {
        case .rootContainer:
            return .root()
        case ProviderIdentifiers.recent:
            return rootDirectories()[0]
        case ProviderIdentifiers.favorites:
            return rootDirectories()[1]
        case ProviderIdentifiers.searchBacking:
            return rootDirectories()[2]
        default:
            guard let occurrence = try await repository.occurrence(for: identifier) else { return nil }
            try Task.checkCancellation()
            return ProviderItem(
                record: occurrence.record,
                view: occurrence.reference.view,
                lastUsedDate: occurrence.lastUsedDate
            )
        }
    }

    /// 构造当前快照并提交 occurrence 版本，供全量枚举和变更枚举共用同一边界。
    func preparedItems(for scope: ProviderEnumerationScope) async throws -> [ProviderItem] {
        let current = try await items(for: scope)
        try Task.checkCancellation()
        _ = try await repository.commitScope(
            scope.storageKey,
            items: current,
            migratesLegacySearch: scope.migratesLegacySearch
        )
        try Task.checkCancellation()
        return current
    }

    /// 从持久化日志读取净差异，并把仍存在的 updated ID 解析为当前完整元数据。
    func changes(
        for scope: ProviderEnumerationScope,
        after anchor: UInt64
    ) async throws -> (updated: [ProviderItem], deleted: [NSFileProviderItemIdentifier], anchor: UInt64) {
        let current = try await preparedItems(for: scope)
        try Task.checkCancellation()
        let changes = try await repository.changes(in: scope.storageKey, after: anchor)
        try Task.checkCancellation()
        let byIdentifier = Dictionary(uniqueKeysWithValues: current.map { ($0.itemIdentifier.rawValue, $0) })
        var deleted = Set(changes.deletedIdentifiers)
        let updated = changes.updatedIdentifiers.compactMap { identifier -> ProviderItem? in
            guard let item = byIdentifier[identifier] else {
                deleted.insert(identifier)
                return nil
            }
            return item
        }
        return (
            updated,
            deleted.sorted().map { NSFileProviderItemIdentifier($0) },
            changes.anchor
        )
    }

    /// 当前锚点读取前先提交 scope 快照，使系统拿到的边界覆盖眼前可枚举的数据。
    func currentAnchor(for scope: ProviderEnumerationScope) async throws -> UInt64 {
        _ = try await preparedItems(for: scope)
        try Task.checkCancellation()
        let anchor = try await repository.currentAnchor()
        try Task.checkCancellation()
        return anchor
    }
}

/// 普通目录、工作集和单条订阅共用同一枚举器实现。
enum ProviderEnumerationScope: Sendable {
    case root
    case search
    case recent
    case favorites
    case workingSet
    case single(NSFileProviderItemIdentifier)
}

extension ProviderEnumerationScope {
    /// scope key 参与持久化，单条订阅也用完整 occurrence ID 隔离历史。
    var storageKey: String {
        switch self {
        case .root: return "root"
        case .search: return "search"
        case .recent: return "recent"
        case .favorites: return "favorites"
        case .workingSet: return "working-set"
        case let .single(identifier): return "single:\(identifier.rawValue)"
        }
    }

    /// 首次迁移时这两个 scope 需要显式删除旧进程遗留的 search occurrence。
    var migratesLegacySearch: Bool {
        switch self {
        case .search, .workingSet: return true
        default: return false
        }
    }
}
