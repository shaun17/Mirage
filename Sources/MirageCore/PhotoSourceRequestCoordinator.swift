import Foundation

/// 聚合器仍按消费者配额读取；该适配器负责从更大的不可变上游批次中切片。
struct CoordinatedPhotoSource: PhotoSourceSearching, Sendable {
    let sourceID: PhotoSourceID
    private let source: any PhotoSourceSearching
    private let policy: PhotoSourceRequestPolicy
    private let coordinator: PhotoSourceRequestCoordinator
    private let configurationPartition: String

    init(
        source: any PhotoSourceSearching,
        policy: PhotoSourceRequestPolicy,
        coordinator: PhotoSourceRequestCoordinator,
        configurationPartition: String
    ) {
        self.sourceID = source.sourceID
        self.source = source
        self.policy = policy
        self.coordinator = coordinator
        self.configurationPartition = configurationPartition
    }

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        do {
            return try await coordinator.search(
                source: source,
                policy: policy,
                query: query,
                cursor: cursor,
                pageSize: pageSize,
                configurationPartition: configurationPartition
            )
        } catch is PhotoSourceBatchStoreError {
            // 存储细节不跨越 Core 边界；App 与 File Provider 统一收到可归类的来源故障。
            throw PhotoSourceDeferredError(
                sourceID: sourceID,
                issueKind: .unavailable,
                retryAt: nil
            )
        }
    }
}

/// App 与 File Provider 各有一个 actor；App Group 批次与租约负责跨进程复用和合并。
actor PhotoSourceRequestCoordinator {
    private static let maximumInMemoryBatches = 128
    private static let maximumInMemoryBudgets = 32

    private struct BatchLoadResult: Sendable {
        let batch: CachedPhotoSourceBatch
        let didRequestNetwork: Bool
    }

    private enum InFlightPhase {
        case loading
        case recordingOutcome
    }

    private struct InFlightBatch {
        let id: UUID
        let task: Task<BatchLoadResult, Error>
        var phase: InFlightPhase
        var waiterCount: Int
    }

    private enum LeaseOwnedBatchEvent: Sendable {
        case batch(BatchLoadResult)
        case leaseLost
    }

    private let store: PhotoSourceBatchStore?
    private let requiresPersistentCoordination: Bool
    private var batches: [PhotoSourceBatchKey: CachedPhotoSourceBatch] = [:]
    private var budgets: [PhotoSourceBudgetKey: PhotoSourceBudgetState] = [:]
    private var inFlight: [PhotoSourceBatchKey: InFlightBatch] = [:]

    init(
        store: PhotoSourceBatchStore? = nil,
        requiresPersistentCoordination: Bool = false
    ) {
        self.store = store
        self.requiresPersistentCoordination = requiresPersistentCoordination
    }

    static func production() -> PhotoSourceRequestCoordinator {
        PhotoSourceRequestCoordinator(
            store: PhotoSourceBatchStore.production(),
            requiresPersistentCoordination: true
        )
    }

    func search(
        source: any PhotoSourceSearching,
        policy: PhotoSourceRequestPolicy,
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int,
        configurationPartition: String
    ) async throws -> PhotoSourcePage {
        try Task.checkCancellation()
        guard pageSize > 0, pageSize <= policy.maximumBatchSize else {
            throw PhotoSearchError.invalidCursor
        }
        let requestQuery = policy.requestQuery(query)
        let batchSize = policy.batchSize(for: pageSize)
        let requestFingerprint = PhotoSourceBatchKey.requestFingerprint(
            sourceID: source.sourceID,
            query: requestQuery,
            batchSize: batchSize,
            policyVersion: policy.version,
            configurationPartition: configurationPartition
        )
        let position = try PhotoSourceBatchPosition.resolve(
            cursor,
            policy: policy,
            consumerPageSize: pageSize,
            requestFingerprint: requestFingerprint
        )
        let batch = try await loadBatch(
            source: source,
            policy: policy,
            query: requestQuery,
            position: position,
            configurationPartition: configurationPartition
        )
        try Task.checkCancellation()
        guard position.offset <= batch.records.count else {
            throw PhotoSearchError.invalidCursor
        }

        let upperBound = min(position.offset + pageSize, batch.records.count)
        let records = Array(batch.records[position.offset..<upperBound])
        let nextCursor: PhotoSourceCursor?
        if upperBound < batch.records.count {
            nextCursor = try PhotoSourceBatchPosition(
                policyVersion: position.policyVersion,
                batchSize: position.batchSize,
                offset: upperBound,
                upstreamCursor: position.upstreamCursor,
                requestFingerprint: position.requestFingerprint,
                batchID: batch.batchID
            ).cursor()
        } else if let upstreamNextCursor = batch.upstreamNextCursor {
            nextCursor = try PhotoSourceBatchPosition(
                policyVersion: position.policyVersion,
                batchSize: position.batchSize,
                upstreamCursor: upstreamNextCursor,
                requestFingerprint: position.requestFingerprint
            ).cursor()
        } else {
            nextCursor = nil
        }
        return PhotoSourcePage(records: records, nextCursor: nextCursor, quota: batch.quota)
    }

    private func loadBatch(
        source: any PhotoSourceSearching,
        policy: PhotoSourceRequestPolicy,
        query: String,
        position: PhotoSourceBatchPosition,
        configurationPartition: String
    ) async throws -> CachedPhotoSourceBatch {
        let now = Date()
        let key = PhotoSourceBatchKey(
            sourceID: source.sourceID,
            query: query,
            upstreamCursor: position.upstreamCursor,
            batchSize: position.batchSize,
            policyVersion: position.policyVersion,
            configurationPartition: configurationPartition
        )
        if let cached = batches[key], cached.expiresAt > now {
            guard position.batchID == nil || position.batchID == cached.batchID else {
                throw PhotoSearchError.invalidCursor
            }
            return cached
        }
        if let cached = try? await store?.batch(for: key, now: now) {
            guard position.batchID == nil || position.batchID == cached.batchID else {
                throw PhotoSearchError.invalidCursor
            }
            rememberBatch(cached, for: key)
            return cached
        }
        // 已部分消费的不可变批次若过期或被清理，明确使游标失效，不能对重排后的新结果套旧 offset。
        guard position.batchID == nil else { throw PhotoSearchError.invalidCursor }
        if requiresPersistentCoordination, policy.requiresPersistentCoordination, store == nil {
            throw PhotoSourceBatchStoreError.unavailable
        }

        let budgetKey = PhotoSourceBudgetKey(
            sourceID: source.sourceID,
            configurationPartition: configurationPartition,
            policyVersion: position.policyVersion
        )
        try await enforceBudget(for: budgetKey, sourceID: source.sourceID, now: now)

        let task: Task<BatchLoadResult, Error>
        let taskID: UUID
        let createdTask: Bool
        if var existing = inFlight[key] {
            existing.waiterCount += 1
            inFlight[key] = existing
            task = existing.task
            taskID = existing.id
            createdTask = false
        } else {
            taskID = UUID()
            task = Task {
                try await Self.fetchBatch(
                    source: source,
                    policy: policy,
                    query: query,
                    position: position,
                    key: key,
                    budgetKey: budgetKey,
                    store: store
                )
            }
            inFlight[key] = InFlightBatch(
                id: taskID,
                task: task,
                phase: .loading,
                waiterCount: 1
            )
            createdTask = true
        }
        defer { releaseWaiter(for: key, expectedID: taskID) }
        do {
            let result = try await Self.cancellableValue(of: task)
            try await finishSuccessfulLoadIfNeeded(
                result,
                key: key,
                expectedID: taskID,
                budgetKey: budgetKey,
                sourceID: source.sourceID,
                policy: policy
            )
            try Task.checkCancellation()
            return result.batch
        } catch is CancellationError {
            if createdTask {
                observeCompletion(
                    of: task,
                    key: key,
                    expectedID: taskID,
                    budgetKey: budgetKey,
                    sourceID: source.sourceID,
                    policy: policy
                )
            }
            throw CancellationError()
        } catch let originalError {
            try await finishFailedLoadIfNeeded(
                originalError,
                key: key,
                expectedID: taskID,
                budgetKey: budgetKey,
                sourceID: source.sourceID,
                policy: policy
            )
            throw originalError
        }
    }

    /// 设置页使用供应商合法的最小批次验证凭据；响应仍进入同一套 24 小时持久缓存。
    func testConnection(
        source: any PhotoSourceSearching,
        policy: PhotoSourceRequestPolicy,
        query: String,
        configurationPartition: String
    ) async throws {
        do {
            _ = try await search(
                source: source,
                policy: policy.connectionTestPolicy(),
                query: query,
                cursor: nil,
                pageSize: 1,
                configurationPartition: configurationPartition
            )
        } catch is PhotoSourceBatchStoreError {
            throw PhotoSourceDeferredError(
                sourceID: source.sourceID,
                issueKind: .unavailable,
                retryAt: nil
            )
        }
    }

    private static func fetchBatch(
        source: any PhotoSourceSearching,
        policy: PhotoSourceRequestPolicy,
        query: String,
        position: PhotoSourceBatchPosition,
        key: PhotoSourceBatchKey,
        budgetKey: PhotoSourceBudgetKey,
        store: PhotoSourceBatchStore?
    ) async throws -> BatchLoadResult {
        guard let store else {
            return try await requestBatch(
                source: source,
                policy: policy,
                query: query,
                position: position,
                key: key
            )
        }

        let owner = UUID()
        while true {
            try Task.checkCancellation()
            if let cached = try? await store.batch(for: key) {
                return BatchLoadResult(batch: cached, didRequestNetwork: false)
            }
            let claim: PhotoSourceBatchClaim
            claim = try await store.claimBatch(
                for: key,
                owner: owner,
                leaseDuration: 15
            )
            switch claim {
            case let .cached(cached):
                return BatchLoadResult(batch: cached, didRequestNetwork: false)
            case let .waiting(until):
                let remaining = max(until.timeIntervalSinceNow, 0.05)
                try await Task.sleep(for: .milliseconds(Int(min(remaining, 0.25) * 1_000)))
            case .owned:
                if let state = try await store.budgetState(
                    for: budgetKey,
                    sourceID: source.sourceID
                ), let blockedUntil = state.blockedUntil,
                   blockedUntil > Date() {
                    try? await store.releaseBatchLease(for: key, owner: owner)
                    throw PhotoSourceDeferredError(
                        sourceID: source.sourceID,
                        issueKind: state.issueKind ?? .unavailable,
                        retryAt: state.issueKind == .invalidCredential ? nil : blockedUntil
                    )
                }
                // 上游失败时保留短租约，让 actor 先写入共享退避，避免另一个进程立刻补打一枪。
                let result: BatchLoadResult
                do {
                    result = try await requestBatchWhileRenewingLease(
                        source: source,
                        policy: policy,
                        query: query,
                        position: position,
                        key: key,
                        store: store,
                        owner: owner
                    )
                } catch PhotoSourceBatchStoreError.leaseLost {
                    continue
                } catch is CancellationError {
                    // 取消不会写入共享退避；立即释放租约，避免 App/Finder 等待自然过期。
                    try? await store.releaseBatchLease(for: key, owner: owner)
                    throw CancellationError()
                } catch {
                    throw error
                }
                do {
                    let committed = try await store.commitBatch(
                        result.batch,
                        for: key,
                        owner: owner
                    )
                    return BatchLoadResult(batch: committed, didRequestNetwork: true)
                } catch PhotoSourceBatchStoreError.leaseLost {
                    continue
                } catch {
                    try? await store.releaseBatchLease(for: key, owner: owner)
                    throw error
                }
            }
        }
    }

    private static func requestBatchWhileRenewingLease(
        source: any PhotoSourceSearching,
        policy: PhotoSourceRequestPolicy,
        query: String,
        position: PhotoSourceBatchPosition,
        key: PhotoSourceBatchKey,
        store: PhotoSourceBatchStore,
        owner: UUID
    ) async throws -> BatchLoadResult {
        try await withThrowingTaskGroup(of: LeaseOwnedBatchEvent.self) { group in
            group.addTask {
                .batch(try await requestBatch(
                    source: source,
                    policy: policy,
                    query: query,
                    position: position,
                    key: key
                ))
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(5))
                    guard try await store.renewBatchLease(
                        for: key,
                        owner: owner,
                        leaseDuration: 15
                    ) else {
                        return .leaseLost
                    }
                }
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            switch first {
            case let .batch(result): return result
            case .leaseLost: throw PhotoSourceBatchStoreError.leaseLost
            }
        }
    }

    /// 每个等待者都可独立取消；共享 loader 继续为其他调用者和跨进程缓存完成请求。
    private static func cancellableValue(
        of task: Task<BatchLoadResult, Error>
    ) async throws -> BatchLoadResult {
        let gate = PhotoSourceTaskWaitGate<BatchLoadResult>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                Task.detached {
                    do {
                        gate.resolve(.success(try await task.value))
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private func finishSuccessfulLoadIfNeeded(
        _ result: BatchLoadResult,
        key: PhotoSourceBatchKey,
        expectedID: UUID,
        budgetKey: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID,
        policy: PhotoSourceRequestPolicy
    ) async throws {
        guard beginRecordingOutcome(for: key, expectedID: expectedID) else { return }
        defer { clearInFlightIfNeeded(for: key, expectedID: expectedID) }
        if result.didRequestNetwork {
            try await recordSuccess(
                quota: result.batch.quota,
                for: budgetKey,
                sourceID: sourceID,
                policy: policy
            )
        }
        rememberBatch(result.batch, for: key)
    }

    private func finishFailedLoadIfNeeded(
        _ error: Error,
        key: PhotoSourceBatchKey,
        expectedID: UUID,
        budgetKey: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID,
        policy: PhotoSourceRequestPolicy
    ) async throws {
        guard beginRecordingOutcome(for: key, expectedID: expectedID) else { return }
        defer { clearInFlightIfNeeded(for: key, expectedID: expectedID) }
        try await recordFailure(error, for: budgetKey, sourceID: sourceID, policy: policy)
    }

    private func observeCompletion(
        of task: Task<BatchLoadResult, Error>,
        key: PhotoSourceBatchKey,
        expectedID: UUID,
        budgetKey: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID,
        policy: PhotoSourceRequestPolicy
    ) {
        Task.detached { [self] in
            do {
                let result = try await task.value
                try await finishSuccessfulLoadIfNeeded(
                    result,
                    key: key,
                    expectedID: expectedID,
                    budgetKey: budgetKey,
                    sourceID: sourceID,
                    policy: policy
                )
            } catch is CancellationError {
                await clearInFlightIfNeeded(for: key, expectedID: expectedID)
            } catch {
                try? await finishFailedLoadIfNeeded(
                    error,
                    key: key,
                    expectedID: expectedID,
                    budgetKey: budgetKey,
                    sourceID: sourceID,
                    policy: policy
                )
            }
        }
    }

    private func beginRecordingOutcome(for key: PhotoSourceBatchKey, expectedID: UUID) -> Bool {
        guard var entry = inFlight[key], entry.id == expectedID else { return false }
        guard case .loading = entry.phase else { return false }
        entry.phase = .recordingOutcome
        inFlight[key] = entry
        return true
    }

    private func releaseWaiter(for key: PhotoSourceBatchKey, expectedID: UUID) {
        guard var entry = inFlight[key], entry.id == expectedID else { return }
        entry.waiterCount = max(entry.waiterCount - 1, 0)
        if entry.waiterCount == 0, case .loading = entry.phase {
            entry.task.cancel()
        }
        inFlight[key] = entry
    }

    private func clearInFlightIfNeeded(for key: PhotoSourceBatchKey, expectedID: UUID) {
        guard inFlight[key]?.id == expectedID else { return }
        inFlight[key] = nil
    }

    private static func requestBatch(
        source: any PhotoSourceSearching,
        policy: PhotoSourceRequestPolicy,
        query: String,
        position: PhotoSourceBatchPosition,
        key: PhotoSourceBatchKey
    ) async throws -> BatchLoadResult {
        let fetchedAt = Date()
        let page = try await source.search(
            query: query,
            cursor: position.upstreamCursor,
            pageSize: position.batchSize
        )
        try Task.checkCancellation()
        let batch = CachedPhotoSourceBatch(
            key: key,
            sourceID: source.sourceID,
            policyVersion: position.policyVersion,
            upstreamPageSize: position.batchSize,
            page: page,
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(policy.metadataTimeToLive)
        )
        return BatchLoadResult(batch: batch, didRequestNetwork: true)
    }

    private func enforceBudget(
        for key: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID,
        now: Date
    ) async throws {
        let state = try await latestBudgetState(for: key, sourceID: sourceID)
        guard let state, let blockedUntil = state.blockedUntil, blockedUntil > now else { return }
        let retryAt = state.issueKind == .invalidCredential ? nil : blockedUntil
        throw PhotoSourceDeferredError(
            sourceID: sourceID,
            issueKind: state.issueKind ?? .unavailable,
            retryAt: retryAt
        )
    }

    private func recordSuccess(
        quota: PhotoSourceQuotaSnapshot?,
        for key: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID,
        policy: PhotoSourceRequestPolicy
    ) async throws {
        let now = Date()
        let blockedUntil: Date?
        if quota?.remaining == 0 {
            let resetAt = quota?.resetAt
            blockedUntil = resetAt.flatMap { $0 > now ? $0 : nil }
                ?? now.addingTimeInterval(policy.rateLimitFallback)
        } else {
            blockedUntil = nil
        }
        let state = PhotoSourceBudgetState(
            key: key,
            sourceID: sourceID,
            blockedUntil: blockedUntil,
            issueKind: blockedUntil == nil ? nil : .rateLimited,
            consecutiveFailures: 0,
            quota: quota,
            updatedAt: now
        )
        rememberBudget(
            effectiveBudgetState(existing: budgets[key], proposed: state, updateKind: .success),
            for: key
        )
        if let store {
            let merged = try await persistBudgetState(
                state,
                for: key,
                updateKind: .success,
                store: store
            )
            rememberBudget(
                effectiveBudgetState(
                    existing: budgets[key],
                    proposed: merged,
                    updateKind: .success
                ),
                for: key
            )
        }
    }

    private func recordFailure(
        _ error: Error,
        for key: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID,
        policy: PhotoSourceRequestPolicy
    ) async throws {
        guard !(error is CancellationError) else { return }
        let now = Date()
        let previous = (try? await latestBudgetState(for: key, sourceID: sourceID)) ?? budgets[key]
        let failure = error as? any PhotoSourceFailure
        let kind = failure?.issueKind ?? .unavailable
        let count = min((previous?.consecutiveFailures ?? 0) + 1, 32)
        let blockedUntil: Date
        switch kind {
        case .missingCredential, .invalidCredential:
            blockedUntil = .distantFuture
        case .rateLimited:
            blockedUntil = [failure?.retryAt, previous?.quota?.resetAt]
                .compactMap { $0 }
                .first { $0 > now }
                ?? now.addingTimeInterval(policy.rateLimitFallback)
        case .decoding, .invalidResponse:
            blockedUntil = now.addingTimeInterval(30)
        case .network, .unavailable:
            let delay = min(pow(2, Double(min(count, 6))), policy.transientBackoffMaximum)
            blockedUntil = now.addingTimeInterval(delay)
        }
        let state = PhotoSourceBudgetState(
            key: key,
            sourceID: sourceID,
            blockedUntil: blockedUntil,
            issueKind: kind,
            consecutiveFailures: count,
            quota: previous?.quota,
            updatedAt: now
        )
        rememberBudget(
            effectiveBudgetState(existing: budgets[key], proposed: state, updateKind: .failure),
            for: key
        )
        if let store {
            let merged = try await persistBudgetState(
                state,
                for: key,
                updateKind: .failure,
                store: store
            )
            rememberBudget(
                effectiveBudgetState(
                    existing: budgets[key],
                    proposed: merged,
                    updateKind: .failure
                ),
                for: key
            )
        }
    }

    /// 共享文件可能由另一个进程刚刚更新；真正联网前总是采用时间较新的状态。
    private func latestBudgetState(
        for key: PhotoSourceBudgetKey,
        sourceID: PhotoSourceID
    ) async throws -> PhotoSourceBudgetState? {
        let cached = budgets[key]
        let persisted: PhotoSourceBudgetState?
        if let store {
            persisted = try await store.budgetState(for: key, sourceID: sourceID)
        } else {
            persisted = nil
        }
        let latest: PhotoSourceBudgetState?
        switch (cached, persisted) {
        case let (left?, right?):
            latest = effectiveBudgetState(
                existing: left,
                proposed: right,
                updateKind: right.issueKind == nil ? .success : .failure
            )
        case let (value?, nil), let (nil, value?):
            latest = value
        case (nil, nil):
            latest = nil
        }
        if let latest { rememberBudget(latest, for: key) }
        return latest
    }

    private func persistBudgetState(
        _ state: PhotoSourceBudgetState,
        for key: PhotoSourceBudgetKey,
        updateKind: PhotoSourceBudgetUpdateKind,
        store: PhotoSourceBatchStore
    ) async throws -> PhotoSourceBudgetState {
        var lastError: Error = PhotoSourceBatchStoreError.unavailable
        for attempt in 0..<3 {
            do {
                return try await store.mergeBudgetState(
                    state,
                    for: key,
                    updateKind: updateKind
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < 2 { try await Task.sleep(for: .milliseconds(50)) }
            }
        }
        throw lastError
    }

    /// Actor 内也使用与持久层相同的“有效阻断优先”规则，避免 await 写盘期间短暂放行。
    private func effectiveBudgetState(
        existing: PhotoSourceBudgetState?,
        proposed: PhotoSourceBudgetState,
        updateKind: PhotoSourceBudgetUpdateKind
    ) -> PhotoSourceBudgetState {
        guard let existing else { return proposed }
        let now = max(existing.updatedAt, proposed.updatedAt)
        let existingActive = existing.blockedUntil.map { $0 > now } == true
        let proposedActive = proposed.blockedUntil.map { $0 > now } == true
        if updateKind == .success, existingActive, !proposedActive {
            return existing
        }
        if existingActive != proposedActive {
            return existingActive ? existing : proposed
        }
        if existingActive, proposedActive {
            let existingUntil = existing.blockedUntil ?? .distantPast
            let proposedUntil = proposed.blockedUntil ?? .distantPast
            return proposedUntil >= existingUntil ? proposed : existing
        }
        return proposed.updatedAt >= existing.updatedAt ? proposed : existing
    }

    private func rememberBatch(_ batch: CachedPhotoSourceBatch, for key: PhotoSourceBatchKey) {
        if batches[key] == nil,
           batches.count >= Self.maximumInMemoryBatches,
           let oldestKey = batches.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            batches.removeValue(forKey: oldestKey)
        }
        batches[key] = batch
    }

    private func rememberBudget(_ state: PhotoSourceBudgetState, for key: PhotoSourceBudgetKey) {
        if budgets[key] == nil,
           budgets.count >= Self.maximumInMemoryBudgets,
           let oldestKey = budgets.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            budgets.removeValue(forKey: oldestKey)
        }
        budgets[key] = state
    }
}

/// 将共享 Task 的完成与单个调用者的取消分离；锁只保护 continuation 的一次性恢复。
private final class PhotoSourceTaskWaitGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if isResolved {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
