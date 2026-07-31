import Foundation

/// App 与 File Provider 共用的推荐流规则，避免两端首页查询和刷新节奏分叉。
public enum DiscoveryRecommendation {
    /// 推荐流的关键词轮换目录。
    ///
    /// Openverse 匿名接口每个查询只开放前约 240 条结果，单关键词必然见底；
    /// 当前关键词耗尽后自动切到下一个，同一条逻辑流因此接近无限。
    /// 顺序即轮换顺序，只增不改——改动会让冻结代次的游标错位，需要连带升级 catalogKey。
    public static let queries = [
        "portrait", "face", "people", "landscape", "architecture",
        "cityscape", "interior design", "workspace", "texture", "technology"
    ]

    /// 单关键词场景（内容筛选与无共享存储时的网络兜底）仍使用目录首词。
    public static let query = queries[0]

    /// v5 收紧照片质量与内容安全并扩展头像目录；旧快照可能含不适内容，读取时整代作废。
    public static let catalogKey = "mirage-recommendations-v5"

    /// 网络失败时只把内部稳定种子交给 DiceBear，不发送到远端搜索服务。
    public static let fallbackSeed = "mirage-recommendations-fallback-v2"

    /// App 每次追加 20 张；File Provider 在同一冻结代次上聚合为每层 50 张。
    public static let pageSize = 20

    /// 新的首次读取最多每小时刷新一次；App 的同一轮滚动始终冻结在原 generation。
    public static let refreshInterval: TimeInterval = 60 * 60
}
