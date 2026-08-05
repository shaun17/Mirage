import FileProvider
import Foundation
import MirageCore

/// File Provider 推荐树输入的一批冻结记录。page 从 1 开始，根目录固定对应第 1 批。
struct ProviderDiscoveryBatch: Sendable {
    let page: Int
    let generation: UInt64
    let records: [RemoteImageRecord]
    let hasMore: Bool
}

/// 非法批次不能进入 Finder 的持久副本，否则会留下无法再解析的公开 ID。
enum ProviderDiscoveryTreeError: Error, Equatable, Sendable {
    case invalidPage(Int)
    case tooManyRecords(Int)
    case pageOverflow(Int)
}

/// 把冻结推荐批次投影为每层最多 40 张图片的递归 File Provider 目录。
enum ProviderDiscoveryTreePlanner {
    static let batchSize = 40
    static let maximumPage = DiscoveryPageReference.maximumPage
    static let continuationFolderName = "更多图片"

    /// 构造一层完整快照。固定资料库目录只会出现在根批，续页目录始终追加在数组末尾。
    static func items(
        for batch: ProviderDiscoveryBatch,
        fixedDirectories: [ProviderItem] = []
    ) throws -> [ProviderItem] {
        try validate(batch)

        var seen = Set<String>()
        let uniqueRecords = batch.records.filter { seen.insert($0.id).inserted }
        let images: [ProviderItem]
        if batch.page == 1 {
            images = uniqueRecords.map {
                ProviderItem(
                    record: $0,
                    view: .discover,
                    discoveryGeneration: batch.generation
                )
            }
        } else {
            guard let reference = DiscoveryPageReference(page: batch.page) else {
                throw ProviderDiscoveryTreeError.invalidPage(batch.page)
            }
            images = uniqueRecords.map {
                ProviderItem(
                    record: $0,
                    reference: RecordReference(recordID: $0.id, discoveryPage: reference),
                    discoveryGeneration: batch.generation
                )
            }
        }

        var result = batch.page == 1 ? fixedDirectories + images : images
        if let continuation = try continuationItem(after: batch) {
            result.append(continuation)
        }
        return result
    }

    /// 用父批次重建唯一的“更多图片”目录；逻辑 ID 稳定，generation 只推进元数据版本。
    static func continuationItem(after batch: ProviderDiscoveryBatch) throws -> ProviderItem? {
        try validate(batch)
        guard batch.hasMore else { return nil }

        let next = batch.page.addingReportingOverflow(1)
        guard !next.overflow, let reference = DiscoveryPageReference(page: next.partialValue) else {
            throw ProviderDiscoveryTreeError.pageOverflow(batch.page)
        }
        return ProviderItem(
            directory: reference.itemIdentifier,
            parent: reference.parentItemIdentifier,
            name: continuationFolderName,
            metadataVersionToken: "generation:\(batch.generation)",
            discoveryGeneration: batch.generation
        )
    }

    /// 将 File Provider 的 40 张逻辑批次映射为累计推荐记录区间，并显式拒绝乘加溢出。
    static func recordRange(for page: Int) throws -> Range<Int> {
        guard (1...DiscoveryPageReference.maximumPage).contains(page) else {
            throw ProviderDiscoveryTreeError.invalidPage(page)
        }
        let pageOffset = page.subtractingReportingOverflow(1)
        let lowerBound = pageOffset.partialValue.multipliedReportingOverflow(by: batchSize)
        let upperBound = lowerBound.partialValue.addingReportingOverflow(batchSize)
        guard !pageOffset.overflow, !lowerBound.overflow, !upperBound.overflow else {
            throw ProviderDiscoveryTreeError.pageOverflow(page)
        }
        return lowerBound.partialValue..<upperBound.partialValue
    }

    /// Repository 使用 bounds 命名读取同一稳定窗口，避免各层重复实现 40/20 映射。
    static func recordBounds(for page: Int) throws -> Range<Int> {
        try recordRange(for: page)
    }

    private static func validate(_ batch: ProviderDiscoveryBatch) throws {
        _ = try recordRange(for: batch.page)
        guard batch.records.count <= batchSize else {
            throw ProviderDiscoveryTreeError.tooManyRecords(batch.records.count)
        }
    }
}

/// Finder 头像树输入的一批确定性记录；第 1 批位于“头像”，后续批次位于递归子目录。
struct ProviderAvatarBatch: Sendable {
    let page: Int
    let records: [RemoteImageRecord]
    let hasMore: Bool
    let filterKey: String

    init(
        page: Int,
        records: [RemoteImageRecord],
        hasMore: Bool,
        filterKey: String = "discover-avatar-filter-v1:all"
    ) {
        self.page = page
        self.records = records
        self.hasMore = hasMore
        self.filterKey = filterKey
    }
}

/// 非法头像批次不能进入持久化 File Provider 树。
enum ProviderAvatarTreeError: Error, Equatable, Sendable {
    case invalidPage(Int)
    case tooManyRecords(Int)
    case pageOverflow(Int)
}

/// 把 DiceBear 的绝对 offset 投影为每层 40 张及一个真实“加载更多”目录。
enum ProviderAvatarTreePlanner {
    static let batchSize = 40
    static let continuationFolderName = "加载更多"

    /// 首页保留既有 avatar ID；续页使用带逻辑页的位置 ID，确保回查时父级不丢失。
    static func items(for batch: ProviderAvatarBatch) throws -> [ProviderItem] {
        try validate(batch)
        var seen = Set<String>()
        let uniqueRecords = batch.records.filter { seen.insert($0.id).inserted }
        let images: [ProviderItem]
        if batch.page == 1 {
            images = uniqueRecords.map { ProviderItem(record: $0, view: .avatar) }
        } else {
            let reference = try AvatarPageReference(validating: batch.page)
            images = uniqueRecords.map {
                ProviderItem(
                    record: $0,
                    reference: RecordReference(recordID: $0.id, avatarPage: reference)
                )
            }
        }

        var result = images
        if let continuation = try continuationItem(after: batch) {
            result.append(continuation)
        }
        return result
    }

    /// 目录 ID 只由下一逻辑页决定；它始终挂在当前批次所在目录下。
    static func continuationItem(after batch: ProviderAvatarBatch) throws -> ProviderItem? {
        try validate(batch)
        guard batch.hasMore else { return nil }

        let next = batch.page.addingReportingOverflow(1)
        guard !next.overflow, let reference = AvatarPageReference(page: next.partialValue) else {
            throw ProviderAvatarTreeError.pageOverflow(batch.page)
        }
        return ProviderItem(
            directory: reference.itemIdentifier,
            parent: reference.parentItemIdentifier,
            name: continuationFolderName,
            metadataVersionToken: "avatar-pagination-v3:\(batch.filterKey)"
        )
    }

    /// 将逻辑页映射为稳定的 DiceBear 绝对 offset 区间，并显式拒绝乘加溢出。
    static func recordRange(for page: Int) throws -> Range<Int> {
        guard (1...AvatarPageReference.maximumPage).contains(page) else {
            throw ProviderAvatarTreeError.invalidPage(page)
        }
        let pageOffset = page.subtractingReportingOverflow(1)
        let lowerBound = pageOffset.partialValue.multipliedReportingOverflow(by: batchSize)
        let upperBound = lowerBound.partialValue.addingReportingOverflow(batchSize)
        guard !pageOffset.overflow, !lowerBound.overflow, !upperBound.overflow else {
            throw ProviderAvatarTreeError.pageOverflow(page)
        }
        return lowerBound.partialValue..<upperBound.partialValue
    }

    private static func validate(_ batch: ProviderAvatarBatch) throws {
        _ = try recordRange(for: batch.page)
        guard batch.records.count <= batchSize else {
            throw ProviderAvatarTreeError.tooManyRecords(batch.records.count)
        }
    }
}
