import FileProvider
import Foundation
import MirageCore

/// 根据目录范围构造父子一致的 File Provider 树。
struct ProviderCatalog: Sendable {
    let repository: ProviderRepository

    init(repository: ProviderRepository) {
        self.repository = repository
    }

    /// 根目录固定公开资料库目录，并附带一个系统隐藏的 Spotlight backing 容器。
    func rootDirectories(discoveryGeneration: UInt64? = nil) async -> [ProviderItem] {
        [
            ProviderItem(
                directory: ProviderIdentifiers.avatars,
                parent: .rootContainer,
                name: ProviderLocalization.current.string("头像"),
                discoveryGeneration: discoveryGeneration
            ),
            ProviderItem(
                directory: ProviderIdentifiers.recent,
                parent: .rootContainer,
                name: ProviderLocalization.current.string("最近使用"),
                discoveryGeneration: discoveryGeneration
            ),
            ProviderItem(
                directory: ProviderIdentifiers.favorites,
                parent: .rootContainer,
                name: ProviderLocalization.current.string("收藏"),
                discoveryGeneration: discoveryGeneration
            ),
            ProviderItem(
                directory: ProviderIdentifiers.searchBacking,
                parent: .rootContainer,
                name: "_SearchBacking",
                hidden: true,
                discoveryGeneration: discoveryGeneration
            )
        ]
    }

    /// 为给定范围读取当前全量快照。
    func items(for scope: ProviderEnumerationScope) async throws -> [ProviderItem] {
        let items: [ProviderItem]
        switch scope {
        case .root:
            items = try await rootItems()
        case let .discoveryPage(reference):
            items = try await discoveryPageItems(reference)
        case .avatars:
            items = try await repository.avatarItems()
        case let .avatarPage(reference):
            items = try await repository.avatarItems(for: reference)
        case .search:
            items = try await repository.cachedSearchItems()
        case .recent:
            items = try await repository.recentItems()
        case .favorites:
            items = try await repository.favoriteItems()
        case .workingSet:
            items = try await workingSetSnapshot().items
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
        case ProviderIdentifiers.avatars,
             ProviderIdentifiers.recent,
             ProviderIdentifiers.favorites,
             ProviderIdentifiers.searchBacking:
            return await rootDirectories().first { $0.itemIdentifier == identifier }
        default:
            if let reference = ProviderIdentifiers.avatarPageReference(from: identifier) {
                return try await repository.avatarContinuationItem(for: reference)
            }
            if let reference = ProviderIdentifiers.discoveryPageReference(from: identifier) {
                guard let parentBatch = try await repository.parentBatch(
                    publishing: reference
                ) else { return nil }
                return try ProviderDiscoveryTreePlanner.continuationItem(after: parentBatch)
            }
            guard let occurrence = try await repository.occurrence(for: identifier) else { return nil }
            try Task.checkCancellation()
            return ProviderItem(
                record: occurrence.record,
                reference: occurrence.reference,
                lastUsedDate: occurrence.lastUsedDate,
                discoveryGeneration: occurrence.discoveryGeneration
            )
        }
    }

    /// 构造当前快照并提交 occurrence 版本，供全量枚举和变更枚举共用同一边界。
    func preparedItems(for scope: ProviderEnumerationScope) async throws -> [ProviderItem] {
        // 必须先于任何异步构造或联网捕获；域重建后，迟到结果只能失败而不能回填旧树。
        let publicationEpoch = try await repository.currentPublicationEpoch()
        try Task.checkCancellation()
        if case .workingSet = scope {
            let snapshot = try await workingSetSnapshot()
            try Task.checkCancellation()
            _ = try await repository.commitWorkingSet(
                items: snapshot.items,
                recursiveScopes: snapshot.recursiveScopes,
                rootGeneration: snapshot.rootGeneration,
                expectedPublicationEpoch: publicationEpoch
            )
            try Task.checkCancellation()
            return snapshot.items
        }

        let current = try await items(for: scope)
        try Task.checkCancellation()
        _ = try await repository.commitScope(
            scope,
            items: current,
            expectedPublicationEpoch: publicationEpoch
        )
        try Task.checkCancellation()
        switch scope {
        case .root, .discoveryPage:
            // 根换代或新子目录首次公开后，把完整可达树加入系统唯一有效的刷新入口。
            await repository.signalWorkingSet()
        case .avatars, .avatarPage, .search, .recent, .favorites, .workingSet, .single:
            break
        }
        return current
    }

    /// 已访问目录在换代后仍属于系统 working set；按持久深度直接重建当前代次的完整前缀。
    private func workingSetSnapshot() async throws -> ProviderWorkingSetSnapshot {
        async let recent = repository.recentItems()
        async let favorites = repository.favoriteItems()
        async let search = repository.cachedSearchItems()
        async let avatars = repository.rebuiltPublishedAvatarScopes()
        let root = try await rootItems()
        guard let rootGeneration = root.compactMap(\.discoveryGeneration).first else {
            throw ProviderError.expiredDiscoveryPage()
        }
        let hasContinuation = root.contains { item in
            ProviderIdentifiers.discoveryPageReference(from: item.itemIdentifier)?.page == 2
        }
        let recursive: ProviderRecursiveWorkingSetSnapshot
        if hasContinuation {
            recursive = try await repository.rebuiltOpenedDiscoveryScopes(
                rootGeneration: rootGeneration
            )
        } else {
            recursive = ProviderRecursiveWorkingSetSnapshot(items: [], scopes: [])
        }
        let values = try await (recent, favorites, search, avatars)
        return ProviderWorkingSetSnapshot(
            items: root + recursive.items + values.3.items + values.0 + values.1 + values.2,
            recursiveScopes: recursive.scopes + values.3.scopes,
            rootGeneration: rootGeneration
        )
    }

    /// 根目录一次发布固定 40 张；下一批只能通过显式“更多图片”目录打开。
    private func rootItems() async throws -> [ProviderItem] {
        let batch: ProviderDiscoveryBatch
        do {
            batch = try await repository.discoveryRootBatch()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 首次启动仍要公开固定资料库；已经发布过图片后则保留旧快照，避免瞬时失败权威清空 Finder。
            if try await repository.hasPublishedDiscoveryItemsInRootAuthorityScopes() {
                throw error
            }
            batch = try await repository.fallbackDiscoveryRootBatch()
        }
        try Task.checkCancellation()
        return try ProviderDiscoveryTreePlanner.items(
            for: batch,
            fixedDirectories: await rootDirectories(discoveryGeneration: batch.generation)
        )
    }

    /// 每个递归目录同样只发布一个固定 40 张批次及至多一个下一层目录。
    private func discoveryPageItems(
        _ reference: DiscoveryPageReference
    ) async throws -> [ProviderItem] {
        let batch = try await repository.discoveryBatch(for: reference)
        try Task.checkCancellation()
        return try ProviderDiscoveryTreePlanner.items(for: batch)
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

    /// 同步锚点必须是纯读取；实际枚举和变化请求会各自在提交后返回对应边界。
    func currentAnchor() async throws -> UInt64 {
        let anchor = try await repository.currentAnchor()
        try Task.checkCancellation()
        return anchor
    }
}

/// 一次 working-set 枚举及其要原子更新的逐目录 scope。
private struct ProviderWorkingSetSnapshot: Sendable {
    let items: [ProviderItem]
    let recursiveScopes: [ProviderScopeSnapshot]
    let rootGeneration: UInt64
}

/// 普通目录、工作集和单条订阅共用同一枚举器实现。
enum ProviderEnumerationScope: Sendable {
    case root
    case discoveryPage(DiscoveryPageReference)
    case avatars
    case avatarPage(AvatarPageReference)
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
        case let .discoveryPage(reference): return "discovery:v3:\(reference.page)"
        case .avatars: return "avatars:v4"
        case let .avatarPage(reference): return "avatars:v4:\(reference.page)"
        case .search: return "search"
        case .recent: return "recent"
        case .favorites: return "favorites"
        case .workingSet: return "working-set"
        case let .single(identifier): return "single:\(identifier.rawValue)"
        }
    }

}
