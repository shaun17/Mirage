import Darwin
import Foundation

enum PhotoSourceBatchStoreError: Error, LocalizedError, Equatable, Sendable {
    case leaseLost
    case valueTooLarge
    case unavailable

    var errorDescription: String? {
        switch self {
        case .leaseLost: return "图片数据源共享请求租约已失效。"
        case .valueTooLarge: return "图片数据源共享缓存超出大小限制。"
        case .unavailable: return "图片数据源共享缓存不可用。"
        }
    }
}

enum PhotoSourceBudgetUpdateKind: Sendable {
    case success
    case failure
}

/// 只持久化公开搜索元数据、额度和短租约；API Key、原查询和图片字节都不会写入磁盘。
actor PhotoSourceBatchStore {
    private static let defaultMaximumBatchFiles = 256
    private static let maximumEncodedBytes = 4 * 1_024 * 1_024

    private let fileManager: FileManager
    private let batchesURL: URL
    private let leasesURL: URL
    private let budgetsURL: URL
    private let locksURL: URL
    private let maximumBatchFiles: Int

    init(baseURL: URL, maximumBatchFiles: Int = defaultMaximumBatchFiles) throws {
        let root = baseURL.standardizedFileURL
            .resolvingSymlinksInPath()
            .appendingPathComponent("photo-source-cache-v2", isDirectory: true)
        let fileManager = FileManager.default
        self.fileManager = fileManager
        self.batchesURL = root.appendingPathComponent("batches", isDirectory: true)
        self.leasesURL = root.appendingPathComponent("leases", isDirectory: true)
        self.budgetsURL = root.appendingPathComponent("budgets", isDirectory: true)
        self.locksURL = root.appendingPathComponent("locks", isDirectory: true)
        self.maximumBatchFiles = max(maximumBatchFiles, 1)
        try fileManager.createDirectory(at: batchesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: leasesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: budgetsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: locksURL, withIntermediateDirectories: true)
    }

    static func production() -> PhotoSourceBatchStore? {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroupStorage.appGroupIdentifier
        ) else { return nil }
        let baseURL = groupURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("Mirage", isDirectory: true)
        return try? PhotoSourceBatchStore(baseURL: baseURL)
    }

    func batch(for key: PhotoSourceBatchKey, now: Date = Date()) throws -> CachedPhotoSourceBatch? {
        try withFileLock(named: "batch-\(key.rawValue)") {
            try readBatchUnlocked(for: key, now: now)
        }
    }

    /// 锁内只认领短租约，网络请求始终在锁外执行。
    func claimBatch(
        for key: PhotoSourceBatchKey,
        owner: UUID,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) throws -> PhotoSourceBatchClaim {
        try withFileLock(named: "batch-\(key.rawValue)") {
            if let cached = try readBatchUnlocked(for: key, now: now) {
                return .cached(cached)
            }
            let leaseURL = self.leaseURL(for: key)
            if let lease = readLeaseUnlocked(from: leaseURL), lease.expiresAt > now, lease.owner != owner {
                return .waiting(until: lease.expiresAt)
            }
            let lease = PhotoSourceBatchLease(
                owner: owner,
                expiresAt: now.addingTimeInterval(max(leaseDuration, 1))
            )
            try encode(lease).write(to: leaseURL, options: .atomic)
            return .owned
        }
    }

    /// 首个仍持有租约的进程提交批次；竞速输家采用已存在的胜者批次。
    func commitBatch(
        _ batch: CachedPhotoSourceBatch,
        for key: PhotoSourceBatchKey,
        owner: UUID,
        now: Date = Date()
    ) throws -> CachedPhotoSourceBatch {
        let committed = try withFileLock(named: "batch-\(key.rawValue)") {
            if let cached = try readBatchUnlocked(for: key, now: now) {
                removeLeaseUnlocked(for: key, owner: owner)
                return cached
            }
            guard let lease = readLeaseUnlocked(from: leaseURL(for: key)),
                  lease.owner == owner else {
                throw PhotoSourceBatchStoreError.leaseLost
            }
            try validate(batch, for: key, now: now, permitsExpired: false)
            try encode(batch).write(to: batchURL(for: key), options: .atomic)
            removeLeaseUnlocked(for: key, owner: owner)
            return batch
        }
        try pruneBatchesIfNeeded()
        return committed
    }

    func releaseBatchLease(for key: PhotoSourceBatchKey, owner: UUID) throws {
        try withFileLock(named: "batch-\(key.rawValue)") {
            removeLeaseUnlocked(for: key, owner: owner)
        }
    }

    /// 慢请求只续自己仍持有的租约；owner 已被接管时立即停止，不会覆盖新持有者。
    func renewBatchLease(
        for key: PhotoSourceBatchKey,
        owner: UUID,
        leaseDuration: TimeInterval,
        now: Date = Date()
    ) throws -> Bool {
        try withFileLock(named: "batch-\(key.rawValue)") {
            let url = leaseURL(for: key)
            guard let lease = readLeaseUnlocked(from: url), lease.owner == owner else {
                return false
            }
            let renewed = PhotoSourceBatchLease(
                owner: owner,
                expiresAt: now.addingTimeInterval(max(leaseDuration, 1))
            )
            try encode(renewed).write(to: url, options: .atomic)
            return true
        }
    }

    func budgetState(
        for key: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID
    ) throws -> PhotoSourceBudgetState? {
        try withFileLock(named: "budget-\(key.rawValue)") {
            let url = budgetURL(for: key)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let state = try decode(PhotoSourceBudgetState.self, from: url)
            guard state.schemaVersion == PhotoSourceBudgetState.schemaVersion,
                  state.keyFingerprint == key.rawValue,
                  state.sourceID == sourceID,
                  state.consecutiveFailures >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return state
        }
    }

    /// 在文件锁内合并额度状态；有效阻断不能被并发请求的迟到成功响应清除。
    func mergeBudgetState(
        _ state: PhotoSourceBudgetState,
        for key: PhotoSourceBudgetKey,
        updateKind: PhotoSourceBudgetUpdateKind
    ) throws -> PhotoSourceBudgetState {
        try withFileLock(named: "budget-\(key.rawValue)") {
            guard state.schemaVersion == PhotoSourceBudgetState.schemaVersion,
                  state.keyFingerprint == key.rawValue,
                  state.consecutiveFailures >= 0 else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let url = budgetURL(for: key)
            let existing: PhotoSourceBudgetState?
            if fileManager.fileExists(atPath: url.path) {
                let decoded = try decode(PhotoSourceBudgetState.self, from: url)
                guard decoded.schemaVersion == PhotoSourceBudgetState.schemaVersion,
                      decoded.keyFingerprint == key.rawValue,
                      decoded.sourceID == state.sourceID,
                      decoded.consecutiveFailures >= 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                existing = decoded
            } else {
                existing = nil
            }
            let merged = mergedBudgetState(
                existing: existing,
                proposed: state,
                key: key,
                updateKind: updateKind
            )
            try encode(merged).write(to: url, options: .atomic)
            return merged
        }
    }

    private func mergedBudgetState(
        existing: PhotoSourceBudgetState?,
        proposed: PhotoSourceBudgetState,
        key: PhotoSourceBudgetKey,
        updateKind: PhotoSourceBudgetUpdateKind
    ) -> PhotoSourceBudgetState {
        guard let existing else { return proposed }
        let existingActive = existing.blockedUntil.map { $0 > proposed.updatedAt } == true
        let proposedActive = proposed.blockedUntil.map { $0 > proposed.updatedAt } == true

        if updateKind == .success, existingActive, !proposedActive {
            return existing
        }
        guard existingActive, proposedActive else {
            return proposed.updatedAt >= existing.updatedAt ? proposed : existing
        }

        let existingUntil = existing.blockedUntil ?? .distantPast
        let proposedUntil = proposed.blockedUntil ?? .distantPast
        let preferredIssue: PhotoSourceIssueKind?
        if proposedUntil > existingUntil {
            preferredIssue = proposed.issueKind
        } else if existingUntil > proposedUntil {
            preferredIssue = existing.issueKind
        } else {
            preferredIssue = Self.issuePriority(proposed.issueKind)
                >= Self.issuePriority(existing.issueKind)
                ? proposed.issueKind
                : existing.issueKind
        }
        let failureCount = updateKind == .failure
            ? min(max(proposed.consecutiveFailures, existing.consecutiveFailures + 1), 32)
            : max(proposed.consecutiveFailures, existing.consecutiveFailures)
        return PhotoSourceBudgetState(
            key: key,
            sourceID: proposed.sourceID,
            blockedUntil: max(existingUntil, proposedUntil),
            issueKind: preferredIssue,
            consecutiveFailures: failureCount,
            quota: proposed.quota ?? existing.quota,
            updatedAt: max(existing.updatedAt, proposed.updatedAt)
        )
    }

    private static func issuePriority(_ issue: PhotoSourceIssueKind?) -> Int {
        switch issue {
        case .invalidCredential: return 6
        case .rateLimited: return 5
        case .network: return 4
        case .decoding, .invalidResponse: return 3
        case .missingCredential: return 2
        case .unavailable: return 1
        case nil: return 0
        }
    }

    private func readBatchUnlocked(
        for key: PhotoSourceBatchKey,
        now: Date
    ) throws -> CachedPhotoSourceBatch? {
        let url = batchURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let batch = try decode(CachedPhotoSourceBatch.self, from: url)
            try validate(batch, for: key, now: now, permitsExpired: false)
            return batch
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func validate(
        _ batch: CachedPhotoSourceBatch,
        for key: PhotoSourceBatchKey,
        now: Date,
        permitsExpired: Bool
    ) throws {
        let uniqueIDs = Set(batch.records.map(\.id))
        guard batch.schemaVersion == CachedPhotoSourceBatch.schemaVersion,
              batch.keyFingerprint == key.rawValue,
              batch.policyVersion > 0,
              batch.upstreamPageSize > 0,
              batch.records.count <= batch.upstreamPageSize,
              uniqueIDs.count == batch.records.count,
              batch.fetchedAt <= batch.expiresAt,
              (batch.upstreamNextCursor?.rawValue.utf8.count ?? 0) <= 512,
              permitsExpired || batch.expiresAt > now else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private func readLeaseUnlocked(from url: URL) -> PhotoSourceBatchLease? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try decode(PhotoSourceBatchLease.self, from: url)
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func removeLeaseUnlocked(for key: PhotoSourceBatchKey, owner: UUID) {
        let url = leaseURL(for: key)
        guard let lease = readLeaseUnlocked(from: url), lease.owner == owner else { return }
        try? fileManager.removeItem(at: url)
    }

    /// 容量只是软上限：先清理损坏或已过期批次，仍在供应商强制 TTL 内的响应不能提前淘汰，
    /// 否则相同请求会在 24 小时内重复计入 Pixabay/Pexels 额度。
    private func pruneBatchesIfNeeded(now: Date = Date()) throws {
        try withFileLock(named: "batch-prune") {
            let files = try fileManager.contentsOfDirectory(
                at: batchesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            guard files.count > maximumBatchFiles else { return }
            var unexpired: [URL] = []
            for url in files {
                guard let batch = try? decode(CachedPhotoSourceBatch.self, from: url),
                      batch.expiresAt > now else {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                unexpired.append(url)
            }
            guard unexpired.count > maximumBatchFiles else { return }
            // 全部仍在合同要求的 TTL 内；保留它们，等后续提交时再清理过期文件。
            return
        }
    }

    private func batchURL(for key: PhotoSourceBatchKey) -> URL {
        batchesURL.appendingPathComponent(key.rawValue).appendingPathExtension("json")
    }

    private func leaseURL(for key: PhotoSourceBatchKey) -> URL {
        leasesURL.appendingPathComponent(key.rawValue).appendingPathExtension("json")
    }

    private func budgetURL(for key: PhotoSourceBudgetKey) -> URL {
        budgetsURL.appendingPathComponent(key.rawValue).appendingPathExtension("json")
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumEncodedBytes else {
            throw PhotoSourceBatchStoreError.valueTooLarge
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumEncodedBytes else {
            throw PhotoSourceBatchStoreError.valueTooLarge
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func withFileLock<T>(named name: String, _ operation: () throws -> T) throws -> T {
        // 固定分片既保留跨进程互斥，又避免每个查询永久创建一个锁文件和 NSLock。
        let shard = String(StableImageID.seedHash("photo-source-lock|\(name)").prefix(2))
        let lockURL = locksURL.appendingPathComponent("shard-\(shard)").appendingPathExtension("lock")
        let processLock = PhotoSourceFileLockRegistry.shared.lock(for: lockURL.path)
        let deadline = Date().addingTimeInterval(0.25)
        while !processLock.try() {
            if Task.isCancelled { throw CancellationError() }
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            Darwin.usleep(5_000)
        }
        defer { processLock.unlock() }

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            try acquireExclusiveLock(descriptor, deadline: deadline)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        defer { releaseFileLock(descriptor) }
        return try operation()
    }

    private func acquireExclusiveLock(_ descriptor: Int32, deadline: Date) throws {
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while Darwin.fcntl(descriptor, F_SETLK, &lock) == -1 {
            if errno == EINTR { continue }
            guard errno == EACCES || errno == EAGAIN else { throw currentPOSIXError() }
            if Task.isCancelled { throw CancellationError() }
            guard Date() < deadline else { throw POSIXError(.ETIMEDOUT) }
            Darwin.usleep(5_000)
        }
    }

    private func releaseFileLock(_ descriptor: Int32) {
        var lock = flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while Darwin.fcntl(descriptor, F_SETLK, &lock) == -1, errno == EINTR {}
        _ = Darwin.close(descriptor)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// fcntl 记录锁属于进程；同进程多个 store 实例仍需按规范路径共享 NSLock。
private final class PhotoSourceFileLockRegistry: @unchecked Sendable {
    static let shared = PhotoSourceFileLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for path: String) -> NSLock {
        let canonicalPath = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[canonicalPath] { return existing }
        let lock = NSLock()
        locks[canonicalPath] = lock
        return lock
    }
}
