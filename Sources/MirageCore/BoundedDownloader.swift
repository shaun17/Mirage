import Foundation

/// 使用流式 URLSession delegate 在接收过程中执行硬字节上限。
public final class BoundedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let maximumBytes: Int
    private let timeoutInterval: TimeInterval
    private let allowedHosts: Set<String>?
    private let acceptedMIMETypes: Set<String>?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var finished = false
    private var cancelled = false

    public init(
        url: URL,
        maximumBytes: Int,
        timeoutInterval: TimeInterval = 20,
        allowedHosts: Set<String>? = nil,
        acceptedMIMETypes: Set<String>? = nil
    ) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.timeoutInterval = timeoutInterval
        self.allowedHosts = allowedHosts.map { Set($0.map { $0.lowercased() }) }
        self.acceptedMIMETypes = acceptedMIMETypes.map { Set($0.map { $0.lowercased() }) }
        super.init()
    }

    /// 下载 HTTPS 内容；任务取消会立即终止底层连接并恢复 continuation。
    public func download() async throws -> Data {
        guard maximumBytes > 0, timeoutInterval > 0, isAllowed(url) else {
            throw DownloadError.insecureURL
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                var request = URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: timeoutInterval
                )
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                if let acceptedMIMETypes {
                    request.setValue(acceptedMIMETypes.sorted().joined(separator: ","), forHTTPHeaderField: "Accept")
                }
                let task = session.dataTask(with: request)
                let shouldStart = lock.withLock { () -> Bool in
                    guard !cancelled else { return false }
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return true
                }
                guard shouldStart else {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let responseURL = http.url,
              isAllowed(responseURL),
              isAcceptedMIME(http.mimeType) else {
            completionHandler(.cancel)
            finish(.failure(DownloadError.invalidResponse))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(DownloadError.tooLarge(maximumBytes)))
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url, isAllowed(redirectURL) else {
            completionHandler(nil)
            finish(.failure(DownloadError.insecureURL))
            return
        }
        completionHandler(request)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard data.count <= maximumBytes, buffer.count <= maximumBytes - data.count else {
                return true
            }
            buffer.append(data)
            return false
        }
        if exceeded {
            dataTask.cancel()
            finish(.failure(DownloadError.tooLarge(maximumBytes)))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled || lock.withLock({ cancelled }) {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(DownloadError.network(error.localizedDescription)))
            }
        } else {
            finish(.success(lock.withLock { buffer }))
        }
    }

    private func isAllowed(_ candidate: URL) -> Bool {
        guard candidate.scheme?.lowercased() == "https",
              let host = candidate.host?.lowercased() else { return false }
        return allowedHosts?.contains(host) ?? true
    }

    private func isAcceptedMIME(_ mimeType: String?) -> Bool {
        guard let acceptedMIMETypes else { return true }
        guard let mimeType else { return false }
        return acceptedMIMETypes.contains(mimeType.lowercased())
    }

    private func finish(_ result: Result<Data, Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<Data, Error>?, URLSession?) in
            guard !finished, continuation != nil else { return (nil, nil) }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, session)
        }
        guard let continuation = state.0 else { return }
        continuation.resume(with: result)
        state.1?.finishTasksAndInvalidate()
    }
}

public enum DownloadError: Error, LocalizedError, Sendable {
    case insecureURL
    case invalidResponse
    case tooLarge(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL: return "远程图片地址必须使用受信任的 HTTPS。"
        case .invalidResponse: return "远程图片服务返回了无效响应。"
        case let .tooLarge(limit): return "远程图片超过 \(limit) 字节上限。"
        case let .network(message): return "远程图片下载失败：\(message)"
        }
    }
}
