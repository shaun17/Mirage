import CryptoKit
import Dispatch
import Foundation

public enum MetMuseumError: Error, Equatable, Sendable {
    case rateLimited(retryAt: Date?)
    case invalidResponse(statusCode: Int)
    case invalidCursor
    case decoding(String)
    case network(String)
}

extension MetMuseumError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "The Met 请求过于频繁，请稍后重试。"
        case let .invalidResponse(statusCode):
            return "The Met 返回异常状态：\(statusCode)"
        case .invalidCursor:
            return "The Met 分页位置已失效，请重新搜索。"
        case let .decoding(message):
            return "The Met 数据解析失败：\(message)"
        case let .network(message):
            return "The Met 网络错误：\(message)"
        }
    }
}

extension MetMuseumError: PhotoSourceFailure {
    public var sourceID: PhotoSourceID { .metMuseum }

    public var issueKind: PhotoSourceIssueKind {
        switch self {
        case .rateLimited:
            return .rateLimited
        case .invalidResponse, .invalidCursor:
            return .invalidResponse
        case .decoding:
            return .decoding
        case .network:
            return .network
        }
    }

    public var retryAt: Date? {
        guard case let .rateLimited(retryAt) = self else { return nil }
        return retryAt
    }
}

/// The Met 没有远端分页：每次先重新取得完整 ID 快照，再用摘要校验本地 offset 游标。
public struct MetMuseumClient: PhotoSourceSearching, Sendable {
    public static let defaultSearchEndpoint = URL(
        string: "https://collectionapi.metmuseum.org/public/collection/v1/search"
    )!
    public static let defaultObjectsEndpoint = URL(
        string: "https://collectionapi.metmuseum.org/public/collection/v1/objects"
    )!

    public let sourceID = PhotoSourceID.metMuseum

    private static let maximumConcurrentDetailRequests = 4
    private static let maximumPageSize = 50
    private static let maximumDetailsScannedPerPage = 80
    private static let cursorVersion = "v1"

    private let searchEndpoint: URL
    private let objectsEndpoint: URL
    private let requestLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let requestGate: MetMuseumRequestGate
    private let now: @Sendable () -> Date

    /// 默认每 50ms 最多发起一个请求（约 20 req/s），显著低于官方 80 req/s 上限。
    public init(
        session: URLSession = .shared,
        searchEndpoint: URL = defaultSearchEndpoint,
        objectsEndpoint: URL = defaultObjectsEndpoint,
        minimumRequestInterval: TimeInterval = 0.05,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            searchEndpoint: searchEndpoint,
            objectsEndpoint: objectsEndpoint,
            minimumRequestInterval: minimumRequestInterval,
            now: now,
            requestLoader: { request in
                try await session.data(for: request)
            }
        )
    }

    /// 闭包注入供隔离测试与自定义传输层复用；节流仍由客户端统一执行。
    init(
        searchEndpoint: URL = defaultSearchEndpoint,
        objectsEndpoint: URL = defaultObjectsEndpoint,
        minimumRequestInterval: TimeInterval = 0.05,
        now: @escaping @Sendable () -> Date = { Date() },
        requestLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.searchEndpoint = searchEndpoint
        self.objectsEndpoint = objectsEndpoint
        self.requestLoader = requestLoader
        self.requestGate = MetMuseumRequestGate(minimumInterval: minimumRequestInterval)
        self.now = now
    }

    public func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        try Task.checkCancellation()
        let cursorState = try Self.decodeCursor(cursor)
        let objectIDs = try await fetchObjectIDs(query: query)
        let snapshotDigest = Self.digest(objectIDs)

        let offset: Int
        if let cursorState {
            guard cursorState.digest == snapshotDigest,
                  cursorState.offset <= objectIDs.count else {
                throw MetMuseumError.invalidCursor
            }
            offset = cursorState.offset
        } else {
            offset = 0
        }

        guard offset < objectIDs.count else {
            return PhotoSourcePage(records: [], nextCursor: nil)
        }

        let safePageSize = min(max(pageSize, 1), Self.maximumPageSize)
        let scanLimit = min(
            Self.maximumDetailsScannedPerPage,
            max(Self.maximumConcurrentDetailRequests, safePageSize * 4)
        )
        var records: [RemoteImageRecord] = []
        records.reserveCapacity(safePageSize)
        var nextOffset = offset
        var inspectedCount = 0

        while records.count < safePageSize,
              nextOffset < objectIDs.count,
              inspectedCount < scanLimit {
            try Task.checkCancellation()
            let remainingSlots = safePageSize - records.count
            let batchCount = min(
                Self.maximumConcurrentDetailRequests,
                remainingSlots,
                objectIDs.count - nextOffset,
                scanLimit - inspectedCount
            )
            let batchStart = nextOffset
            let batch = try await fetchObjects(
                ids: Array(objectIDs[batchStart..<(batchStart + batchCount)]),
                startingAt: batchStart
            )

            // batchCount 永不超过剩余交付容量，因此所有已获取的有效记录都会进入本页。
            records.append(contentsOf: batch.compactMap(\.record))
            nextOffset += batchCount
            inspectedCount += batchCount
        }

        let nextCursor = nextOffset < objectIDs.count
            ? Self.makeCursor(offset: nextOffset, digest: snapshotDigest)
            : nil
        return PhotoSourcePage(records: records, nextCursor: nextCursor)
    }

    private func fetchObjectIDs(query: String) async throws -> [Int] {
        var components = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "hasImages", value: "true"),
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components?.url else {
            throw MetMuseumError.network("无法构造搜索请求地址")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request)
        try validate(response)

        do {
            let payload = try JSONDecoder().decode(MetMuseumSearchResponse.self, from: data)
            return payload.objectIDs ?? []
        } catch is DecodingError {
            throw MetMuseumError.decoding("搜索响应格式无效")
        }
    }

    private func fetchObjects(
        ids: [Int],
        startingAt startIndex: Int
    ) async throws -> [(index: Int, record: RemoteImageRecord?)] {
        try await withThrowingTaskGroup(
            of: (index: Int, record: RemoteImageRecord?).self,
            returning: [(index: Int, record: RemoteImageRecord?)].self
        ) { group in
            for (relativeIndex, objectID) in ids.enumerated() {
                let index = startIndex + relativeIndex
                group.addTask { [self] in
                    (index, try await fetchObject(id: objectID))
                }
            }

            var results: [(index: Int, record: RemoteImageRecord?)] = []
            results.reserveCapacity(ids.count)
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func fetchObject(id objectID: Int) async throws -> RemoteImageRecord? {
        guard objectID > 0 else { return nil }
        let url = objectsEndpoint.appendingPathComponent(String(objectID), isDirectory: false)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse else {
            throw MetMuseumError.invalidResponse(statusCode: 0)
        }

        if http.statusCode == 404 {
            return nil
        }
        try validate(http)

        guard let payload = try? JSONDecoder().decode(MetMuseumObjectResponse.self, from: data) else {
            return nil
        }
        return Self.makeRecord(payload, requestedObjectID: objectID)
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await requestGate.waitForTurn()
        do {
            let result = try await requestLoader(request)
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MetMuseumError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw MetMuseumError.network("错误代码 \(error.code.rawValue)")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MetMuseumError.network("请求失败")
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MetMuseumError.invalidResponse(statusCode: 0)
        }
        try validate(http)
    }

    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 429:
            throw MetMuseumError.rateLimited(
                retryAt: Self.retryDate(
                    response.value(forHTTPHeaderField: "Retry-After"),
                    now: now()
                )
            )
        default:
            throw MetMuseumError.invalidResponse(statusCode: response.statusCode)
        }
    }

    private static func makeRecord(
        _ value: MetMuseumObjectResponse,
        requestedObjectID: Int
    ) -> RemoteImageRecord? {
        guard value.objectID == requestedObjectID,
              value.objectID > 0,
              value.isPublicDomain,
              let imageURL = secureURL(value.primaryImage),
              let thumbnailURL = secureURL(value.primaryImageSmall) else {
            return nil
        }
        let title = value.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = value.artistDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteImageRecord(
            id: StableImageID.metMuseum(objectID: value.objectID),
            title: title?.nilIfEmpty ?? "The Met Object \(value.objectID)",
            source: .metMuseum,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            sourcePageURL: secureURL(value.objectURL),
            license: .cc0,
            creator: creator?.nilIfEmpty,
            creatorURL: nil,
            width: nil,
            height: nil,
            mimeType: mimeType(for: imageURL)
        )
    }

    private static func secureURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.host != nil else {
            return nil
        }
        return url
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    private static func digest(_ objectIDs: [Int]) -> String {
        var data = Data(capacity: (objectIDs.count + 1) * MemoryLayout<UInt64>.size)
        var count = UInt64(objectIDs.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for objectID in objectIDs {
            var value = Int64(objectID).bigEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeCursor(_ cursor: PhotoSourceCursor?) throws -> MetMuseumCursorState? {
        guard let cursor else { return nil }
        let fields = cursor.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == Substring(cursorVersion),
              let offset = Int(fields[1]),
              offset >= 0,
              String(offset) == fields[1],
              fields[2].count == 64,
              fields[2].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw MetMuseumError.invalidCursor
        }
        return MetMuseumCursorState(offset: offset, digest: String(fields[2]))
    }

    private static func makeCursor(offset: Int, digest: String) -> PhotoSourceCursor {
        PhotoSourceCursor(rawValue: "\(cursorVersion).\(offset).\(digest)")
    }

    private static func retryDate(_ rawValue: String?, now: Date) -> Date? {
        guard let rawValue,
              let seconds = TimeInterval(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        let retryAt = now.addingTimeInterval(seconds)
        return retryAt.timeIntervalSinceReferenceDate.isFinite ? retryAt : nil
    }
}

private struct MetMuseumSearchResponse: Decodable {
    let total: Int
    let objectIDs: [Int]?
}

private struct MetMuseumObjectResponse: Decodable {
    let objectID: Int
    let isPublicDomain: Bool
    let primaryImage: String?
    let primaryImageSmall: String?
    let title: String?
    let artistDisplayName: String?
    let objectURL: String?
}

private struct MetMuseumCursorState {
    let offset: Int
    let digest: String
}

private actor MetMuseumRequestGate {
    private let minimumIntervalNanoseconds: UInt64
    private var nextRequestNanoseconds: UInt64?

    init(minimumInterval: TimeInterval) {
        let safeInterval = minimumInterval.isFinite ? min(max(minimumInterval, 0), 60) : 0.05
        self.minimumIntervalNanoseconds = UInt64((safeInterval * 1_000_000_000).rounded())
    }

    func waitForTurn() async throws {
        guard minimumIntervalNanoseconds > 0 else {
            try Task.checkCancellation()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduled = max(now, nextRequestNanoseconds ?? now)
        let (next, overflow) = scheduled.addingReportingOverflow(minimumIntervalNanoseconds)
        nextRequestNanoseconds = overflow ? UInt64.max : next
        if scheduled > now {
            try await Task.sleep(nanoseconds: scheduled - now)
        } else {
            try Task.checkCancellation()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
