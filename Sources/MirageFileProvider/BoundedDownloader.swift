import Foundation

/// 使用流式 URLSession delegate 在接收过程中执行硬字节上限。
final class BoundedDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var finished = false
    private var cancelled = false

    init(url: URL, maximumBytes: Int) {
        self.url = url
        self.maximumBytes = maximumBytes
        super.init()
    }

    /// 下载 HTTPS 内容；任务取消会立即终止底层连接并恢复 continuation。
    func download() async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw DownloadError.insecureURL
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: url)
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

    /// 接到取消信号后确保 continuation 只恢复一次。
    private func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    /// 在收到响应头时拒绝 HTTP 错误及明确超限的响应。
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
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

    /// 允许 HTTPS 内部跳转，但拒绝任何把安全请求降级到明文 HTTP 的重定向。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https", request.url?.host != nil else {
            completionHandler(nil)
            finish(.failure(DownloadError.insecureURL))
            return
        }
        completionHandler(request)
    }

    /// 分块累积数据，一旦超过上限立即取消连接。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard buffer.count <= maximumBytes - data.count else { return true }
            buffer.append(data)
            return false
        }
        if exceeded {
            dataTask.cancel()
            finish(.failure(DownloadError.tooLarge(maximumBytes)))
        }
    }

    /// 正常结束时交付完整数据；底层错误转换为稳定网络错误。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(DownloadError.network(error.localizedDescription)))
        } else {
            finish(.success(lock.withLock { buffer }))
        }
    }

    /// 串行化所有终止路径，防止取消与 delegate 同时恢复 continuation。
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

/// 下载层只暴露可分类的安全错误。
enum DownloadError: Error, LocalizedError, Sendable {
    case insecureURL
    case invalidResponse
    case tooLarge(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL: return "远程图片地址必须使用 HTTPS。"
        case .invalidResponse: return "远程图片服务返回了无效响应。"
        case let .tooLarge(limit): return "远程图片超过 \(limit) 字节上限。"
        case let .network(message): return "远程图片下载失败：\(message)"
        }
    }
}
