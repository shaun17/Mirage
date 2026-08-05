import Foundation

struct PicrewDiscoveryEntry: Equatable, Sendable {
    let makerID: String
    let thumbnailPath: String
    let canvasSizeCode: Int
    let score: Int64
}

private enum PicrewDiscoveryConfiguration {
    static let pageSize = 40
    static let maximumEntryCount = 400
    static let initialEndpoint = URL(string: "https://picrew.me/en/discovery")!
    static let continuationEndpoint = URL(string: "https://api.picrew.me/player/api/discovery")!

    static func continuationURL(after score: Int64) -> URL? {
        var components = URLComponents(
            url: continuationEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: String(pageSize)),
            URLQueryItem(name: "score", value: String(score)),
            URLQueryItem(name: "lang", value: "en"),
        ]
        return components?.url
    }
}

public enum PicrewDiscoveryMediaPolicy {
    public static func isAllowedThumbnailURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "cdn.picrew.me",
              url.port == nil,
              url.path.hasPrefix("/shareImg/thumb/") else {
            return false
        }
        return ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
    }
}

/// Picrew Discovery 首屏嵌在 Astro 状态中，后续批次使用页面自身的 score 游标 JSON 结构。
enum PicrewDiscoveryParser {
    private static let stateMarker = #"id="it-astro-state""#
    private static let discoveryKey = "picrew-discoveries"
    private static let maximumHTMLBytes = 2 * 1_024 * 1_024

    static func entries(from data: Data) -> [PicrewDiscoveryEntry] {
        guard data.count <= maximumHTMLBytes,
              let stateData = embeddedStateData(in: data),
              let values = try? JSONSerialization.jsonObject(with: stateData) as? [Any],
              let keyIndex = values.firstIndex(where: { ($0 as? String) == discoveryKey }),
              values.indices.contains(keyIndex + 1),
              let references = values[keyIndex + 1] as? [Any] else {
            return []
        }

        var seenPaths = Set<String>()
        return references.prefix(PicrewDiscoveryConfiguration.pageSize).compactMap { reference in
            guard let objectIndex = integer(reference),
                  values.indices.contains(objectIndex),
                  let object = values[objectIndex] as? [String: Any],
                  let makerID: String = referenced("id", in: object, values: values),
                  let thumbnailPath: String = referenced("url", in: object, values: values),
                  let canvasSizeCode = referencedInteger("cs", in: object, values: values),
                  let score = referencedInt64("score", in: object, values: values),
                  makerID.allSatisfy(\.isNumber),
                  isAllowedThumbnailPath(thumbnailPath),
                  seenPaths.insert(thumbnailPath).inserted else {
                return nil
            }
            return PicrewDiscoveryEntry(
                makerID: makerID,
                thumbnailPath: thumbnailPath,
                canvasSizeCode: canvasSizeCode,
                score: score
            )
        }
    }

    static func continuationEntries(from data: Data) -> [PicrewDiscoveryEntry] {
        guard data.count <= maximumHTMLBytes,
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var seenPaths = Set<String>()
        return objects.prefix(PicrewDiscoveryConfiguration.pageSize).compactMap { object in
            guard let makerID = scalarString(object["id"]),
                  let thumbnailPath = object["url"] as? String,
                  let canvasSizeCode = integer(object["cs"]),
                  let score = int64(object["score"]),
                  makerID.allSatisfy(\.isNumber),
                  isAllowedThumbnailPath(thumbnailPath),
                  seenPaths.insert(thumbnailPath).inserted else {
                return nil
            }
            return PicrewDiscoveryEntry(
                makerID: makerID,
                thumbnailPath: thumbnailPath,
                canvasSizeCode: canvasSizeCode,
                score: score
            )
        }
    }

    private static func embeddedStateData(in data: Data) -> Data? {
        guard let html = String(data: data, encoding: .utf8),
              let markerRange = html.range(of: stateMarker),
              let openingBracket = html.range(
                of: ">",
                range: markerRange.upperBound..<html.endIndex
              ),
              let closingTag = html.range(
                of: "</script>",
                range: openingBracket.upperBound..<html.endIndex
              ) else {
            return nil
        }
        return Data(html[openingBracket.upperBound..<closingTag.lowerBound].utf8)
    }

    private static func referenced<T>(
        _ key: String,
        in object: [String: Any],
        values: [Any]
    ) -> T? {
        guard let index = integer(object[key]), values.indices.contains(index) else { return nil }
        return values[index] as? T
    }

    private static func referencedInteger(
        _ key: String,
        in object: [String: Any],
        values: [Any]
    ) -> Int? {
        guard let index = integer(object[key]), values.indices.contains(index) else { return nil }
        return integer(values[index])
    }

    private static func referencedInt64(
        _ key: String,
        in object: [String: Any],
        values: [Any]
    ) -> Int64? {
        guard let index = integer(object[key]), values.indices.contains(index) else { return nil }
        return int64(values[index])
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        return (value as? NSNumber)?.stringValue
    }

    private static func isAllowedThumbnailPath(_ path: String) -> Bool {
        guard path.hasPrefix("shareImg/thumb/"), !path.contains("..") else { return false }
        return ["jpg", "jpeg", "png", "webp"].contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        )
    }
}

typealias PicrewDiscoveryFetch = @Sendable (URL) async throws -> Data

private actor PicrewDiscoveryStore {
    private let fetch: PicrewDiscoveryFetch
    private var cachedEntries: [PicrewDiscoveryEntry] = []
    private var expiresAt: Date?
    private var isExhausted = false
    private var continuationRetryAt: Date?
    private var refreshTask: (id: UUID, task: Task<[PicrewDiscoveryEntry]?, Never>)?
    private var continuationTask: (id: UUID, task: Task<[PicrewDiscoveryEntry]?, Never>)?

    init(fetch: @escaping PicrewDiscoveryFetch) {
        self.fetch = fetch
    }

    func entry(at index: Int) async -> PicrewDiscoveryEntry? {
        guard (0..<PicrewDiscoveryConfiguration.maximumEntryCount).contains(index) else {
            return nil
        }
        await prepareInitialEntries()
        while cachedEntries.count <= index, !isExhausted {
            guard await loadContinuation() else { break }
        }
        guard cachedEntries.indices.contains(index) else { return nil }
        return cachedEntries[index]
    }

    private func prepareInitialEntries() async {
        if let expiresAt, expiresAt > Date() { return }
        let id: UUID
        let task: Task<[PicrewDiscoveryEntry]?, Never>
        if let refreshTask {
            id = refreshTask.id
            task = refreshTask.task
        } else {
            id = UUID()
            let fetch = self.fetch
            task = Task {
                guard let data = try? await fetch(PicrewDiscoveryConfiguration.initialEndpoint) else {
                    return nil
                }
                return PicrewDiscoveryParser.entries(from: data)
            }
            refreshTask = (id, task)
        }

        let entries = await task.value
        guard refreshTask?.id == id else { return }
        refreshTask = nil
        cachedEntries = Self.unique(entries ?? [])
        expiresAt = Date().addingTimeInterval(cachedEntries.isEmpty ? 30 : 600)
        isExhausted = cachedEntries.count < PicrewDiscoveryConfiguration.pageSize
        continuationRetryAt = nil
    }

    private func loadContinuation() async -> Bool {
        guard cachedEntries.count < PicrewDiscoveryConfiguration.maximumEntryCount,
              continuationRetryAt.map({ $0 <= Date() }) ?? true,
              let score = cachedEntries.last?.score,
              let url = PicrewDiscoveryConfiguration.continuationURL(after: score) else {
            return false
        }

        let previousCount = cachedEntries.count
        let id: UUID
        let task: Task<[PicrewDiscoveryEntry]?, Never>
        if let continuationTask {
            id = continuationTask.id
            task = continuationTask.task
        } else {
            id = UUID()
            let fetch = self.fetch
            task = Task {
                guard let data = try? await fetch(url) else { return nil }
                return PicrewDiscoveryParser.continuationEntries(from: data)
            }
            continuationTask = (id, task)
        }

        let entries = await task.value
        guard continuationTask?.id == id else {
            return cachedEntries.count > previousCount
        }
        continuationTask = nil
        guard let entries else {
            continuationRetryAt = Date().addingTimeInterval(30)
            return false
        }

        let existingPaths = Set(cachedEntries.map(\.thumbnailPath))
        let additions = entries.filter { !existingPaths.contains($0.thumbnailPath) }
        cachedEntries.append(contentsOf: additions)
        if cachedEntries.count > PicrewDiscoveryConfiguration.maximumEntryCount {
            cachedEntries.removeLast(
                cachedEntries.count - PicrewDiscoveryConfiguration.maximumEntryCount
            )
        }
        isExhausted = entries.count < PicrewDiscoveryConfiguration.pageSize
            || additions.isEmpty
            || cachedEntries.count == PicrewDiscoveryConfiguration.maximumEntryCount
        expiresAt = Date().addingTimeInterval(600)
        continuationRetryAt = nil
        return cachedEntries.count > previousCount
    }

    private static func unique(
        _ entries: [PicrewDiscoveryEntry]
    ) -> [PicrewDiscoveryEntry] {
        var paths = Set<String>()
        return entries.filter { paths.insert($0.thumbnailPath).inserted }
    }
}

/// 将 Discovery 预览按页面自身的 40 条游标映射成 App 内头像卡片；不发布给 Finder。
struct PicrewDiscoveryClient: AvatarSourceGenerating, Sendable {
    private static let thumbnailBaseURL = URL(string: "https://cdn.picrew.me")!
    private static let sharedStore = PicrewDiscoveryStore(fetch: fetchDiscoveryPage)

    private let store: PicrewDiscoveryStore

    init() {
        store = Self.sharedStore
    }

    init(fetch: @escaping PicrewDiscoveryFetch) {
        store = PicrewDiscoveryStore(fetch: fetch)
    }

    let avatarCatalogIdentifier = ImageSource.picrew.rawValue
    let supportedAvatarTypes: Set<AvatarType> = [.anime]

    func avatar(
        seedMaterial: String,
        generationDay _: AvatarGenerationDay
    ) async -> RemoteImageRecord? {
        guard let index = AvatarSeed.absoluteIndex(from: seedMaterial),
              let entry = await store.entry(at: index) else { return nil }
        return Self.record(from: entry)
    }

    private static func record(from entry: PicrewDiscoveryEntry) -> RemoteImageRecord? {
        let thumbnailURL = thumbnailBaseURL.appending(path: entry.thumbnailPath)
        guard PicrewDiscoveryMediaPolicy.isAllowedThumbnailURL(thumbnailURL),
              let sourcePageURL = URL(
                string: "https://picrew.me/en/image_maker/\(entry.makerID)"
              ) else {
            return nil
        }
        return RemoteImageRecord(
            id: StableImageID.picrewDiscovery(
                makerID: entry.makerID,
                thumbnailPath: entry.thumbnailPath
            ),
            title: "Picrew 头像作品 · Maker #\(entry.makerID)",
            source: .picrew,
            avatarType: .anime,
            imageURL: thumbnailURL,
            thumbnailURL: thumbnailURL,
            sourcePageURL: sourcePageURL,
            license: .picrewUsage,
            mimeType: "image/jpeg"
        )
    }

    private static func fetchDiscoveryPage(from url: URL) async throws -> Data {
        switch url.host?.lowercased() {
        case "picrew.me", "www.picrew.me":
            return try await BoundedDownloader(
                url: url,
                maximumBytes: 2 * 1_024 * 1_024,
                timeoutInterval: 15,
                allowedHosts: ["picrew.me", "www.picrew.me"],
                acceptedMIMETypes: ["text/html"]
            ).download()
        case "api.picrew.me":
            return try await BoundedDownloader(
                url: url,
                maximumBytes: 512 * 1_024,
                timeoutInterval: 15,
                allowedHosts: ["api.picrew.me"],
                acceptedMIMETypes: ["application/json"]
            ).download()
        default:
            throw URLError(.unsupportedURL)
        }
    }
}
