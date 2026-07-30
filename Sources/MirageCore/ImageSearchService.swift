import Foundation

/// 根据显式前缀决定图片搜索来源，并维护默认结果的来源顺序。
public struct ImageSearchService: Sendable {
    private let openverse: any OpenverseSearching
    private let diceBear: any DiceBearProviding
    private let defaultPhotoCount: Int
    private let defaultAvatarCount: Int

    public init(
        openverse: any OpenverseSearching = OpenverseClient(),
        diceBear: any DiceBearProviding = DiceBearClient(),
        defaultPhotoCount: Int = 20,
        defaultAvatarCount: Int = 4
    ) {
        self.openverse = openverse
        self.diceBear = diceBear
        self.defaultPhotoCount = min(max(defaultPhotoCount, 1), 50)
        self.defaultAvatarCount = min(max(defaultAvatarCount, 0), 20)
    }

    /// 无前缀时 Openverse 在前、DiceBear 少量补充；显式前缀只访问对应来源。
    public func search(_ rawQuery: String) async throws -> [RemoteImageRecord] {
        let query = SearchQueryParser.parse(rawQuery)
        guard !query.text.isEmpty else { return [] }

        switch query.scope {
        case .photo:
            return try await openverse.search(query: query.text, pageSize: defaultPhotoCount)
        case .avatar:
            return await diceBear.avatars(query: query.text, count: max(defaultAvatarCount, 12))
        case .automatic:
            async let photos = openverse.search(query: query.text, pageSize: defaultPhotoCount)
            async let avatars = diceBear.avatars(query: query.text, count: defaultAvatarCount)
            // await 顺序就是最终展示优先级，不受网络完成先后影响。
            let (photoResults, avatarResults) = try await (photos, avatars)
            return photoResults + avatarResults
        }
    }
}
