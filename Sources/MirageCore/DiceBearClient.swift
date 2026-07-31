import Foundation

public protocol DiceBearProviding: Sendable {
    /// 生成稳定、无个人信息的头像元数据，不发起网络请求。
    func avatars(query: String, offset: Int, count: Int) async -> [RemoteImageRecord]
}

public extension DiceBearProviding {
    /// 不需要分页的调用统一从第一个头像开始，保持发现页等旧调用语义。
    func avatars(query: String, count: Int) async -> [RemoteImageRecord] {
        await avatars(query: query, offset: 0, count: count)
    }
}

/// 构造 DiceBear 10.x PNG 地址；真正的图片下载由消费方按需进行。
public struct DiceBearClient: DiceBearProviding, Sendable {
    private let endpoint: URL
    private let styles: [DiceBearStyle]

    public init(
        endpoint: URL = URL(string: "https://api.dicebear.com")!,
        styles: [DiceBearStyle] = DiceBearStyle.allCases
    ) {
        self.endpoint = endpoint
        self.styles = styles.isEmpty ? DiceBearStyle.allCases : styles
    }

    /// 查询文字只参与本地 SHA-256；风格按摘要稳定随机，原始文字不会进入远程 URL。
    public func avatars(query: String, offset: Int = 0, count: Int) async -> [RemoteImageRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeOffset = max(offset, 0)
        let safeCount = min(max(count, 0), 20)
        let end = safeOffset.addingReportingOverflow(safeCount)
        guard !end.overflow else { return [] }
        return (safeOffset..<end.partialValue).compactMap { index in
            let material = "mirage|\(normalized)|\(index)"
            let seedHash = StableImageID.seedHash(material)
            let style = selectedStyle(seedMaterial: material)
            guard let url = imageURL(style: style, seed: seedHash) else { return nil }
            return RemoteImageRecord(
                id: StableImageID.diceBear(style: style.rawValue, seedMaterial: material),
                title: "\(style.displayName) avatar",
                source: .diceBear,
                imageURL: url,
                thumbnailURL: url,
                sourcePageURL: URL(string: "https://www.dicebear.com/styles/\(style.rawValue)/"),
                license: style.license,
                creator: style.creator,
                creatorURL: style.creatorURL,
                width: 256,
                height: 256,
                mimeType: "image/png"
            )
        }
    }

    /// 对每个候选风格独立打分并取最高值；目录重排不改变结果，新增风格也只影响少量记录。
    private func selectedStyle(seedMaterial: String) -> DiceBearStyle {
        var selected = styles[0]
        var selectedRank = styleRank(selected, seedMaterial: seedMaterial)
        for style in styles.dropFirst() {
            let rank = styleRank(style, seedMaterial: seedMaterial)
            if rank > selectedRank || (rank == selectedRank && style.rawValue > selected.rawValue) {
                selected = style
                selectedRank = rank
            }
        }
        return selected
    }

    /// 只取摘要前 64 位即可均匀排序；风格名参与摘要，使各候选得到彼此独立的稳定分数。
    private func styleRank(_ style: DiceBearStyle, seedMaterial: String) -> UInt64 {
        let digest = StableImageID.seedHash("mirage-style-v1|\(seedMaterial)|\(style.rawValue)")
        return UInt64(String(digest.prefix(16)), radix: 16) ?? 0
    }

    /// 公共 HTTP API 的光栅输出上限为 256 像素；固定版本与尺寸保持记录可复现。
    private func imageURL(style: DiceBearStyle, seed: String) -> URL? {
        let path = endpoint
            .appendingPathComponent("10.x", isDirectory: true)
            .appendingPathComponent(style.rawValue, isDirectory: true)
            .appendingPathComponent("png", isDirectory: false)
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "seed", value: seed),
            URLQueryItem(name: "size", value: "256")
        ]
        guard let url = components?.url, url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
