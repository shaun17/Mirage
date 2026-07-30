import Foundation

/// Mirage 明确审查过的 DiceBear CC0 风格白名单。
public enum DiceBearStyle: String, CaseIterable, Codable, Sendable {
    case pixelArt = "pixel-art"
    case lorelei
    case notionists
    case thumbs
    case openPeeps = "open-peeps"
}

public protocol DiceBearProviding: Sendable {
    /// 生成稳定、无个人信息的头像元数据，不发起网络请求。
    func avatars(query: String, count: Int) async -> [RemoteImageRecord]
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

    /// 查询文字只参与本地 SHA-256，URL、ID 与标题均不会泄露原始文字。
    public func avatars(query: String, count: Int) async -> [RemoteImageRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeCount = min(max(count, 0), 20)
        return (0..<safeCount).compactMap { index in
            let style = styles[index % styles.count]
            let material = "mirage|\(normalized)|\(index)"
            let seedHash = StableImageID.seedHash(material)
            guard let url = imageURL(style: style, seed: seedHash) else { return nil }
            return RemoteImageRecord(
                id: StableImageID.diceBear(style: style.rawValue, seedMaterial: material),
                title: "\(style.rawValue) avatar",
                source: .diceBear,
                imageURL: url,
                thumbnailURL: url,
                sourcePageURL: URL(string: "https://www.dicebear.com/styles/\(style.rawValue)/"),
                license: .cc0,
                creator: "DiceBear",
                creatorURL: URL(string: "https://www.dicebear.com"),
                width: 512,
                height: 512,
                mimeType: "image/png"
            )
        }
    }

    /// 固定使用 10.x、PNG 和 512 像素，避免服务升级改变同一记录的输出。
    private func imageURL(style: DiceBearStyle, seed: String) -> URL? {
        let path = endpoint
            .appendingPathComponent("10.x", isDirectory: true)
            .appendingPathComponent(style.rawValue, isDirectory: true)
            .appendingPathComponent("png", isDirectory: false)
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "seed", value: seed),
            URLQueryItem(name: "size", value: "512")
        ]
        guard let url = components?.url, url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
