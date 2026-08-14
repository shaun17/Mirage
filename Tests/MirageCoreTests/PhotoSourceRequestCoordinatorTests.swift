import Foundation
import XCTest
@testable import MirageCore

final class PhotoSourceRequestCoordinatorTests: XCTestCase {
    /// Pexels 固定抓取 80 条；App 连续四个 20 张页面只消耗一次上游请求且不丢记录。
    func testEightyRecordBatchServesFourAppPagesBeforeNextRequest() async throws {
        let upstream = BatchPhotoSource(sourceID: .pexels, delay: .zero)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "revision:1"
        )

        var cursor: PhotoSourceCursor?
        var delivered: [String] = []
        for _ in 0..<4 {
            let page = try await source.search(query: "  Red   Panda ", cursor: cursor, pageSize: 20)
            delivered.append(contentsOf: page.records.map(\.id))
            cursor = page.nextCursor
        }

        XCTAssertEqual(delivered, (0..<80).map { "pexels-\($0)" })
        XCTAssertEqual(Set(delivered).count, 80)
        let firstCalls = await upstream.recordedCalls()
        XCTAssertEqual(firstCalls, [BatchSourceCall(cursor: nil, pageSize: 80)])

        let fifth = try await source.search(query: "red panda", cursor: cursor, pageSize: 20)
        XCTAssertEqual(fifth.records.first?.id, "pexels-80")
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls, [
            BatchSourceCall(cursor: nil, pageSize: 80),
            BatchSourceCall(cursor: "2", pageSize: 80)
        ])
    }

    /// Pixabay 按 40 条缓存 24 小时；App 的两个 20 张页面只消耗一次上游请求。
    func testPixabayFortyRecordBatchServesTwoAppPages() async throws {
        let policy = PhotoSourceRequestPolicies.policy(for: .pixabay)
        XCTAssertEqual(policy.preferredBatchSize, 40)
        XCTAssertEqual(policy.maximumBatchSize, 200)
        XCTAssertEqual(policy.metadataTimeToLive, 24 * 60 * 60)
        XCTAssertTrue(policy.requiresPersistentCoordination)
        let upstream = BatchPhotoSource(sourceID: .pixabay, delay: .zero)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "credential:pixabay"
        )

        let first = try await source.search(query: "nature", cursor: nil, pageSize: 20)
        let second = try await source.search(query: "nature", cursor: first.nextCursor, pageSize: 20)

        XCTAssertEqual(first.records.map(\.id), (0..<20).map { "pixabay-\($0)" })
        XCTAssertEqual(second.records.map(\.id), (20..<40).map { "pixabay-\($0)" })
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls, [BatchSourceCall(cursor: nil, pageSize: 40)])
    }

    /// Openverse 的 40 条逻辑批次由两个匿名 20 条请求组成；两个 App 页复用该批次，续批从远端第 3 页开始。
    func testOpenverseFortyRecordBatchUsesTwentyRecordUpstreamPages() async throws {
        let policy = PhotoSourceRequestPolicies.policy(for: .openverse)
        XCTAssertEqual(PhotoSourceRequestPolicies.catalogVersion, 3)
        XCTAssertEqual(policy.version, 2)
        XCTAssertEqual(policy.preferredBatchSize, 40)
        XCTAssertEqual(policy.maximumBatchSize, 40)
        let client = TwentyRecordOpenverse()
        let source = CoordinatedPhotoSource(
            source: OpenversePhotoSource(client: client),
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "anonymous"
        )

        let first = try await source.search(query: "nature", cursor: nil, pageSize: 20)
        let callsAfterFirstPage = await client.recordedCalls()
        let firstCursor = try XCTUnwrap(first.nextCursor)
        let second = try await source.search(query: "nature", cursor: firstCursor, pageSize: 20)
        let firstBatchIDs = first.records.map(\.id) + second.records.map(\.id)

        XCTAssertEqual(callsAfterFirstPage, [
            OpenverseBatchCall(page: 1, pageSize: 20),
            OpenverseBatchCall(page: 2, pageSize: 20)
        ])
        XCTAssertEqual(first.records.map(\.id), (0..<20).map { "openverse-\($0)" })
        XCTAssertEqual(second.records.map(\.id), (20..<40).map { "openverse-\($0)" })
        XCTAssertEqual(Set(firstBatchIDs).count, 40)
        let callsAfterSecondPage = await client.recordedCalls()
        XCTAssertEqual(callsAfterSecondPage, [
            OpenverseBatchCall(page: 1, pageSize: 20),
            OpenverseBatchCall(page: 2, pageSize: 20)
        ])

        let secondCursor = try XCTUnwrap(second.nextCursor)
        let third = try await source.search(query: "nature", cursor: secondCursor, pageSize: 20)

        XCTAssertEqual(third.records.map(\.id), (40..<60).map { "openverse-\($0)" })
        let allCalls = await client.recordedCalls()
        XCTAssertEqual(allCalls, [
            OpenverseBatchCall(page: 1, pageSize: 20),
            OpenverseBatchCall(page: 2, pageSize: 20),
            OpenverseBatchCall(page: 3, pageSize: 20),
            OpenverseBatchCall(page: 4, pageSize: 20)
        ])
    }

    /// 非 20 倍数的逻辑页用页内偏移续读，不能丢掉第二个远端页尚未交付的记录。
    func testOpenverseCursorPreservesPartialAnonymousPage() async throws {
        let client = TwentyRecordOpenverse()
        let source = OpenversePhotoSource(client: client)

        let first = try await source.search(query: "nature", cursor: nil, pageSize: 25)
        XCTAssertEqual(first.records.map(\.id), (0..<25).map { "openverse-\($0)" })
        XCTAssertEqual(first.nextCursor?.rawValue, "ov1:2:5")

        let second = try await source.search(
            query: "nature",
            cursor: try XCTUnwrap(first.nextCursor),
            pageSize: 25
        )
        XCTAssertEqual(second.records.map(\.id), (25..<50).map { "openverse-\($0)" })
        XCTAssertEqual(second.nextCursor?.rawValue, "ov1:3:10")
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [
            OpenverseBatchCall(page: 1, pageSize: 20),
            OpenverseBatchCall(page: 2, pageSize: 20),
            OpenverseBatchCall(page: 2, pageSize: 20),
            OpenverseBatchCall(page: 3, pageSize: 20)
        ])
    }

    /// 远端提前耗尽时返回已有记录并终止，不能为了凑 40 条继续请求不存在的页面。
    func testOpenverseShortFinalPageHasNoContinuation() async throws {
        let client = TwentyRecordOpenverse(lastPage: 1)
        let source = OpenversePhotoSource(client: client)

        let page = try await source.search(query: "nature", cursor: nil, pageSize: 40)

        XCTAssertEqual(page.records.map(\.id), (0..<20).map { "openverse-\($0)" })
        XCTAssertNil(page.nextCursor)
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [OpenverseBatchCall(page: 1, pageSize: 20)])
    }

    /// 第二个匿名页失败时不能缓存第一个页的半成品；解除退避后的重试必须从第一页重新组批。
    func testOpenverseSecondChunkFailureDoesNotCachePartialBatch() async throws {
        let client = FailOnceSecondPageOpenverse()
        let policy = PhotoSourceRequestPolicy(
            version: 2,
            preferredBatchSize: 40,
            maximumBatchSize: 40,
            metadataTimeToLive: 60 * 60,
            transientBackoffMaximum: 0
        )
        let source = CoordinatedPhotoSource(
            source: OpenversePhotoSource(client: client),
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "anonymous-fail-once"
        )

        do {
            _ = try await source.search(query: "nature", cursor: nil, pageSize: 20)
            XCTFail("第二个 Openverse 匿名页失败时整个逻辑批次都应失败")
        } catch {
            XCTAssertEqual(error as? URLError, URLError(.networkConnectionLost))
        }

        let recovered = try await source.search(query: "nature", cursor: nil, pageSize: 20)
        XCTAssertEqual(recovered.records.map(\.id), (0..<20).map { "openverse-\($0)" })
        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [
            OpenverseBatchCall(page: 1, pageSize: 20),
            OpenverseBatchCall(page: 2, pageSize: 20),
            OpenverseBatchCall(page: 1, pageSize: 20),
            OpenverseBatchCall(page: 2, pageSize: 20)
        ])
    }

    /// 相邻远端页偶发重复 ID 时逻辑批次必须去重，并按已消费远端页继续前进。
    func testOpenverseLogicalBatchDeduplicatesAcrossAnonymousPages() async throws {
        let client = OverlappingOpenverse()
        let source = OpenversePhotoSource(client: client)

        let page = try await source.search(query: "nature", cursor: nil, pageSize: 40)

        XCTAssertEqual(page.records.count, 39)
        XCTAssertEqual(Set(page.records.map(\.id)).count, 39)
        XCTAssertEqual(page.nextCursor?.rawValue, "ov1:3:0")
    }

    func testPixabayConnectionTestReusesPersistentTwentyFourHourCache() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = BatchPhotoSource(sourceID: .pixabay, delay: .zero)
        let policy = PhotoSourceRequestPolicies.policy(for: .pixabay)
        let firstCoordinator = PhotoSourceRequestCoordinator(
            store: try PhotoSourceBatchStore(baseURL: root),
            requiresPersistentCoordination: true
        )
        let secondCoordinator = PhotoSourceRequestCoordinator(
            store: try PhotoSourceBatchStore(baseURL: root),
            requiresPersistentCoordination: true
        )

        try await firstCoordinator.testConnection(
            source: upstream,
            policy: policy,
            query: "nature",
            configurationPartition: "credential:pixabay"
        )
        try await secondCoordinator.testConnection(
            source: upstream,
            policy: policy,
            query: "nature",
            configurationPartition: "credential:pixabay"
        )

        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls, [BatchSourceCall(cursor: nil, pageSize: 3)])
    }

    func testPixabayQueryLimitIsAppliedBeforeCacheFingerprinting() async throws {
        let upstream = BatchPhotoSource(sourceID: .pixabay, delay: .zero)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pixabay),
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "credential:pixabay"
        )
        let sharedPrefix = String(repeating: "a", count: 100)

        _ = try await source.search(query: sharedPrefix + "first", cursor: nil, pageSize: 20)
        _ = try await source.search(query: sharedPrefix + "second", cursor: nil, pageSize: 20)

        let queries = await upstream.recordedQueries()
        XCTAssertEqual(queries, [sharedPrefix])
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls, [BatchSourceCall(cursor: nil, pageSize: 40)])
    }

    /// 缓存达到软上限时仍不能淘汰未满 24 小时的 Pixabay 响应并导致重复计费。
    func testBatchPruningKeepsUnexpiredProviderResponses() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PhotoSourceBatchStore(baseURL: root, maximumBatchFiles: 2)
        let now = Date()
        var keys: [PhotoSourceBatchKey] = []

        for index in 0..<3 {
            let key = PhotoSourceBatchKey(
                sourceID: .pixabay,
                query: "query-\(index)",
                upstreamCursor: nil,
                batchSize: 40,
                policyVersion: 1,
                configurationPartition: "credential:pixabay"
            )
            keys.append(key)
            let owner = UUID()
            guard case .owned = try await store.claimBatch(
                for: key,
                owner: owner,
                leaseDuration: 15,
                now: now
            ) else {
                return XCTFail("新缓存键应能取得租约")
            }
            let batch = CachedPhotoSourceBatch(
                key: key,
                sourceID: .pixabay,
                policyVersion: 1,
                upstreamPageSize: 40,
                page: PhotoSourcePage(records: [], nextCursor: nil),
                fetchedAt: now,
                expiresAt: now.addingTimeInterval(24 * 60 * 60)
            )
            _ = try await store.commitBatch(batch, for: key, owner: owner, now: now)
        }

        let oldest = try await store.batch(for: keys[0], now: now.addingTimeInterval(60))
        XCTAssertNotNil(oldest)
    }

    /// App 与 Finder 使用独立 offset，但共享不可变批次；跨 coordinator 并发冷启动仍只发一次 HTTP。
    func testAppAndFinderSharePersistentBatchWithIndependentOffsets() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = BatchPhotoSource(sourceID: .pexels, delay: .milliseconds(100))
        let appStore = try PhotoSourceBatchStore(baseURL: root)
        let finderStore = try PhotoSourceBatchStore(baseURL: root)
        let policy = PhotoSourceRequestPolicies.policy(for: .pexels)
        let app = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(store: appStore),
            configurationPartition: "revision:2"
        )
        let finder = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(store: finderStore),
            configurationPartition: "revision:2"
        )

        async let appPage = app.search(query: "city", cursor: nil, pageSize: 20)
        async let finderPage = finder.search(query: "city", cursor: nil, pageSize: 40)
        let (appResult, finderResult) = try await (appPage, finderPage)

        XCTAssertEqual(appResult.records.map(\.id), (0..<20).map { "pexels-\($0)" })
        XCTAssertEqual(finderResult.records.map(\.id), (0..<40).map { "pexels-\($0)" })
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls, [BatchSourceCall(cursor: nil, pageSize: 80)])
    }

    /// 同进程多个相同 miss 复用同一个 in-flight Task，不能因系统重复枚举放大请求数。
    func testConcurrentIdenticalMissesUseSingleFlight() async throws {
        let upstream = BatchPhotoSource(sourceID: .openverse, delay: .milliseconds(80))
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .openverse),
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "revision:3"
        )

        let pages = try await withThrowingTaskGroup(of: PhotoSourcePage.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await source.search(query: "workspace", cursor: nil, pageSize: 20)
                }
            }
            var values: [PhotoSourcePage] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(pages.count, 12)
        XCTAssertTrue(pages.allSatisfy { $0.records.count == 20 })
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls, [BatchSourceCall(cursor: nil, pageSize: 40)])
    }

    /// 单源 429 即使被聚合层部分成功掩盖，后续调用也应在共享预算层阻断而不再次访问网络。
    func testRateLimitBlocksRepeatedUpstreamRequest() async {
        let resetAt = Date().addingTimeInterval(120)
        let upstream = RateLimitedPhotoSource(resetAt: resetAt)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "revision:4"
        )

        do {
            _ = try await source.search(query: "nature", cursor: nil, pageSize: 20)
            XCTFail("首次请求应返回限流错误")
        } catch {
            XCTAssertEqual((error as? any PhotoSourceFailure)?.issueKind, .rateLimited)
        }
        do {
            _ = try await source.search(query: "nature", cursor: nil, pageSize: 20)
            XCTFail("退避期间应直接阻断")
        } catch let error as PhotoSourceDeferredError {
            XCTAssertEqual(error.issueKind, .rateLimited)
            if let retryAt = error.retryAt {
                XCTAssertEqual(retryAt.timeIntervalSince1970, resetAt.timeIntervalSince1970, accuracy: 0.01)
            } else {
                XCTFail("应保留服务端重置时间")
            }
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        let callCount = await upstream.callCount()
        XCTAssertEqual(callCount, 1)
    }

    /// 取消某个等待者必须立即返回，同时保留共享 loader 供其他等待者完成。
    func testCancellingOneWaiterDoesNotWaitForOrCancelSharedRequest() async throws {
        let upstream = BatchPhotoSource(sourceID: .pexels, delay: .milliseconds(300))
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "credential:shared"
        )
        let owner = Task {
            try await source.search(query: "city", cursor: nil, pageSize: 20)
        }
        try await Task.sleep(for: .milliseconds(30))
        let waiter = Task {
            try await source.search(query: "city", cursor: nil, pageSize: 20)
        }
        try await Task.sleep(for: .milliseconds(30))

        let clock = ContinuousClock()
        let started = clock.now
        owner.cancel()
        do {
            _ = try await owner.value
            XCTFail("被取消的等待者不应返回结果")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(150))

        let result = try await waiter.value
        XCTAssertEqual(result.records.count, 20)
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    /// owner 在取得持久租约后取消时应立即释放，另一 coordinator 不必等待 15 秒租约自然过期。
    func testCancellingLeaseOwnerAllowsAnotherCoordinatorToTakeOverImmediately() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = CancellationLeasePhotoSource()
        let policy = PhotoSourceRequestPolicies.policy(for: .openverse)
        let app = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: "anonymous:cancelled-owner"
        )
        let finder = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: "anonymous:cancelled-owner"
        )

        let owner = Task {
            try await app.search(query: "city", cursor: nil, pageSize: 20)
        }
        let ownerStarted = await upstream.waitForCalls(1)
        XCTAssertTrue(ownerStarted)
        owner.cancel()
        do {
            _ = try await owner.value
            XCTFail("被取消的 owner 不应返回结果")
        } catch is CancellationError {
            // expected
        }

        let successor = Task {
            try await finder.search(query: "city", cursor: nil, pageSize: 20)
        }
        guard await upstream.waitForCalls(2) else {
            successor.cancel()
            _ = try? await successor.value
            return XCTFail("另一 coordinator 应在取消后立即取得已释放的租约")
        }

        let page = try await successor.value
        XCTAssertEqual(page.records.count, 20)
        let callCount = await upstream.callCount()
        XCTAssertEqual(callCount, 2)
    }

    /// 游标绑定查询和凭据分区；错配或旧页码都必须在访问网络前被拒绝。
    func testMismatchedAndLegacyCursorsAreRejectedBeforeNetwork() async throws {
        let upstream = BatchPhotoSource(sourceID: .pexels, delay: .zero)
        let coordinator = PhotoSourceRequestCoordinator()
        let policy = PhotoSourceRequestPolicies.policy(for: .pexels)
        let firstSource = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: coordinator,
            configurationPartition: "credential:first"
        )
        let first = try await firstSource.search(query: "city", cursor: nil, pageSize: 20)
        XCTAssertNotNil(first.nextCursor)

        do {
            _ = try await firstSource.search(query: "portrait", cursor: first.nextCursor, pageSize: 20)
            XCTFail("跨查询游标应失效")
        } catch let error as PhotoSearchError {
            XCTAssertEqual(error, .invalidCursor)
        }
        let changedCredential = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: coordinator,
            configurationPartition: "credential:second"
        )
        do {
            _ = try await changedCredential.search(query: "city", cursor: first.nextCursor, pageSize: 20)
            XCTFail("跨凭据游标应失效")
        } catch let error as PhotoSearchError {
            XCTAssertEqual(error, .invalidCursor)
        }
        do {
            _ = try await firstSource.search(
                query: "city",
                cursor: PhotoSourceCursor(rawValue: "2"),
                pageSize: 20
            )
            XCTFail("旧页码不能套用新的 80 条分页边界")
        } catch let error as PhotoSearchError {
            XCTAssertEqual(error, .invalidCursor)
        }
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    /// 已部分消费的不可变批次过期后必须使游标失效，不能重抓重排后的同一上游页。
    func testExpiredPartialBatchDoesNotRefetchBehindCursor() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = BatchPhotoSource(sourceID: .pexels, delay: .zero)
        let policy = PhotoSourceRequestPolicy(
            version: 1,
            preferredBatchSize: 80,
            maximumBatchSize: 80,
            metadataTimeToLive: 0.03
        )
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: "credential:expiry"
        )
        let first = try await source.search(query: "city", cursor: nil, pageSize: 20)
        try await Task.sleep(for: .milliseconds(80))

        do {
            _ = try await source.search(query: "city", cursor: first.nextCursor, pageSize: 20)
            XCTFail("过期批次的 offset 游标应失效")
        } catch let error as PhotoSearchError {
            XCTAssertEqual(error, .invalidCursor)
        }
        let calls = await upstream.recordedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    /// App 已缓存旧预算时，也必须看到 Finder 随后写入的共享 429 状态。
    func testPersistedRateLimitOverridesAnotherCoordinatorMemoryState() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partition = "credential:shared-budget"
        let policy = PhotoSourceRequestPolicies.policy(for: .pexels)
        let successful = QuotaPhotoSource(remaining: 10, resetAt: nil)
        let limited = RateLimitedPhotoSource(resetAt: Date().addingTimeInterval(120))
        let app = CoordinatedPhotoSource(
            source: successful,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: partition
        )
        let finder = CoordinatedPhotoSource(
            source: limited,
            policy: policy,
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: partition
        )

        _ = try await app.search(query: "warm", cursor: nil, pageSize: 20)
        do {
            _ = try await finder.search(query: "limited", cursor: nil, pageSize: 40)
            XCTFail("Finder 请求应触发限流")
        } catch {
            XCTAssertEqual((error as? any PhotoSourceFailure)?.issueKind, .rateLimited)
        }
        do {
            _ = try await app.search(query: "after", cursor: nil, pageSize: 20)
            XCTFail("App 应采用 Finder 写入的共享退避")
        } catch let error as PhotoSourceDeferredError {
            XCTAssertEqual(error.issueKind, .rateLimited)
        }
        let successfulCalls = await successful.callCount()
        let limitedCalls = await limited.callCount()
        XCTAssertEqual(successfulCalls, 1)
        XCTAssertEqual(limitedCalls, 1)
    }

    /// 成功响应若报告 remaining=0，即使缺 reset 也使用 fallback，缓存内页面仍可继续消费。
    func testZeroRemainingWithoutResetBlocksOnlyNextUpstreamBatch() async throws {
        let upstream = QuotaPhotoSource(remaining: 0, resetAt: nil)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(),
            configurationPartition: "credential:zero"
        )
        var cursor: PhotoSourceCursor?
        for _ in 0..<4 {
            cursor = try await source.search(query: "city", cursor: cursor, pageSize: 20).nextCursor
        }
        do {
            _ = try await source.search(query: "city", cursor: cursor, pageSize: 20)
            XCTFail("新批次应被额度状态阻断")
        } catch let error as PhotoSourceDeferredError {
            XCTAssertEqual(error.issueKind, .rateLimited)
            XCTAssertNotNil(error.retryAt)
        }
        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 1)
    }

    /// 较早启动但较晚完成的成功响应不能清除并发请求刚写入的 429。
    func testLateSuccessCannotClearConcurrentRateLimit() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resetAt = Date().addingTimeInterval(120)
        let upstream = ConcurrentBudgetPhotoSource(resetAt: resetAt)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: "credential:budget-race"
        )

        let slowSuccess = Task {
            try await source.search(query: "slow-success", cursor: nil, pageSize: 20)
        }
        await upstream.waitUntilSlowRequestStarts()
        do {
            _ = try await source.search(query: "rate-limited", cursor: nil, pageSize: 20)
            XCTFail("并发请求应返回限流")
        } catch {
            XCTAssertEqual((error as? any PhotoSourceFailure)?.issueKind, .rateLimited)
        }
        _ = try await slowSuccess.value

        do {
            _ = try await source.search(query: "must-not-network", cursor: nil, pageSize: 20)
            XCTFail("迟到成功不能清除仍有效的限流")
        } catch let error as PhotoSourceDeferredError {
            XCTAssertEqual(error.issueKind, .rateLimited)
        }
        let queries = await upstream.recordedQueries()
        XCTAssertEqual(queries, ["slow-success", "rate-limited"])
    }

    /// 最后一个等待者在租约等待期间取消后，共享 loader 不得在未来自行补发 HTTP。
    func testCancellingLastWaiterBeforeLeaseAcquisitionPreventsFutureRequest() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PhotoSourceBatchStore(baseURL: root)
        let partition = "credential:no-waiters"
        let key = PhotoSourceBatchKey(
            sourceID: .pexels,
            query: "city",
            upstreamCursor: nil,
            batchSize: 80,
            policyVersion: 1,
            configurationPartition: partition
        )
        guard case .owned = try await store.claimBatch(
            for: key,
            owner: UUID(),
            leaseDuration: 1
        ) else {
            return XCTFail("测试应先持有跨进程租约")
        }
        let upstream = BatchPhotoSource(sourceID: .pexels, delay: .zero)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(store: store),
            configurationPartition: partition
        )
        let request = Task {
            try await source.search(query: "city", cursor: nil, pageSize: 40)
        }
        try await Task.sleep(for: .milliseconds(80))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("已取消等待者不应收到结果")
        } catch is CancellationError {
            // expected
        }
        try await Task.sleep(for: .milliseconds(1_100))

        let calls = await upstream.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    /// 生产共享存储不可用时凭据来源必须闭锁；无额度要求的 Openverse 仍可工作。
    func testMissingProductionStoreFailsClosedForCredentialedSources() async throws {
        let coordinator = PhotoSourceRequestCoordinator(
            store: nil,
            requiresPersistentCoordination: true
        )
        for sourceID in [PhotoSourceID.pexels, .pixabay] {
            let upstream = BatchPhotoSource(sourceID: sourceID, delay: .zero)
            let source = CoordinatedPhotoSource(
                source: upstream,
                policy: PhotoSourceRequestPolicies.policy(for: sourceID),
                coordinator: coordinator,
                configurationPartition: "credential:\(sourceID.rawValue):store-unavailable"
            )
            do {
                _ = try await source.search(query: "city", cursor: nil, pageSize: 20)
                XCTFail("\(sourceID.rawValue) 不得降级为无协调网络请求")
            } catch let error as any PhotoSourceFailure {
                XCTAssertEqual(error.sourceID, sourceID)
                XCTAssertEqual(error.issueKind, .unavailable)
            }

            do {
                try await coordinator.testConnection(
                    source: upstream,
                    policy: PhotoSourceRequestPolicies.policy(for: sourceID),
                    query: "nature",
                    configurationPartition: "credential:\(sourceID.rawValue):test-store-unavailable"
                )
                XCTFail("连接测试不得绕过缺失的生产共享存储")
            } catch let error as any PhotoSourceFailure {
                XCTAssertEqual(error.sourceID, sourceID)
                XCTAssertEqual(error.issueKind, .unavailable)
            }
            let calls = await upstream.recordedCalls()
            XCTAssertTrue(calls.isEmpty)
        }

        let openverseUpstream = BatchPhotoSource(sourceID: .openverse, delay: .zero)
        let openverse = CoordinatedPhotoSource(
            source: openverseUpstream,
            policy: PhotoSourceRequestPolicies.policy(for: .openverse),
            coordinator: coordinator,
            configurationPartition: "credential:none"
        )
        let page = try await openverse.search(query: "city", cursor: nil, pageSize: 20)
        XCTAssertEqual(page.records.count, 20)
        let openverseCalls = await openverseUpstream.recordedCalls()
        XCTAssertEqual(openverseCalls.count, 1)
    }

    /// 已存在的预算文件不可读时不能当作“无限制”，否则可能绕过仍有效的 429。
    func testCorruptPersistedBudgetFailsClosedBeforeNetwork() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = QuotaPhotoSource(remaining: 100, resetAt: nil)
        let source = CoordinatedPhotoSource(
            source: upstream,
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: "credential:corrupt-budget"
        )
        _ = try await source.search(query: "first", cursor: nil, pageSize: 20)

        let budgetsURL = root
            .appendingPathComponent("photo-source-cache-v2", isDirectory: true)
            .appendingPathComponent("budgets", isDirectory: true)
        let budgetFiles = try FileManager.default.contentsOfDirectory(
            at: budgetsURL,
            includingPropertiesForKeys: nil
        )
        let budgetFile = try XCTUnwrap(budgetFiles.first)
        try Data("not-json".utf8).write(to: budgetFile, options: .atomic)

        do {
            _ = try await source.search(query: "second", cursor: nil, pageSize: 20)
            XCTFail("损坏的预算文件必须阻止新网络请求")
        } catch {
            // 任意持久读取错误都应 fail-closed；关键断言是下面没有新增 HTTP。
        }
        let calls = await upstream.callCount()
        XCTAssertEqual(calls, 1)
    }

    /// heartbeat 只能续当前 owner；延长后原到期点不能被另一进程接管。
    func testLeaseRenewalExtendsCrossProcessOwnership() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PhotoSourceBatchStore(baseURL: root)
        let key = PhotoSourceBatchKey(
            sourceID: .pexels,
            query: "city",
            upstreamCursor: nil,
            batchSize: 80,
            policyVersion: 1,
            configurationPartition: "credential:lease"
        )
        let owner = UUID()
        let other = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        guard case .owned = try await store.claimBatch(
            for: key,
            owner: owner,
            leaseDuration: 15,
            now: start
        ) else {
            return XCTFail("首个 owner 应认领成功")
        }
        let renewed = try await store.renewBatchLease(
            for: key,
            owner: owner,
            leaseDuration: 15,
            now: start.addingTimeInterval(10)
        )
        XCTAssertTrue(renewed)
        guard case let .waiting(until) = try await store.claimBatch(
            for: key,
            owner: other,
            leaseDuration: 15,
            now: start.addingTimeInterval(16)
        ) else {
            return XCTFail("续租后不应在原到期点被接管")
        }
        XCTAssertEqual(until, start.addingTimeInterval(25))
    }

    /// 持久缓存只含公开元数据与摘要，不能落盘原查询或凭据分区材料。
    func testPersistentCacheDoesNotContainRawQueryOrCredential() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let query = "private search phrase"
        let credential = "super-secret-api-key"
        let source = CoordinatedPhotoSource(
            source: BatchPhotoSource(sourceID: .pexels, delay: .zero),
            policy: PhotoSourceRequestPolicies.policy(for: .pexels),
            coordinator: PhotoSourceRequestCoordinator(
                store: try PhotoSourceBatchStore(baseURL: root)
            ),
            configurationPartition: credential
        )
        _ = try await source.search(query: query, cursor: nil, pageSize: 20)

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let files = (enumerator?.allObjects as? [URL]) ?? []
        let persisted = files.compactMap { try? Data(contentsOf: $0) }
            .reduce(into: Data()) { $0.append($1) }
        let text = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(text.contains(query))
        XCTAssertFalse(text.contains(credential))

        let partition = PhotoSearchEnvironment.requestPartition(
            sourceID: .pexels,
            credential: credential
        )
        XCTAssertFalse(partition.contains(credential))
        XCTAssertNotEqual(
            partition,
            PhotoSearchEnvironment.requestPartition(sourceID: .pexels, credential: "another-key")
        )
    }

    /// 系统 token 保持紧凑且不包含用户原始查询。
    func testBufferedCursorIsCompactAndDoesNotContainQuery() throws {
        let policy = PhotoSourceRequestPolicies.policy(for: .pexels)
        let position = PhotoSourceBatchPosition(
            policyVersion: policy.version,
            batchSize: 80,
            offset: 40,
            upstreamCursor: PhotoSourceCursor(rawValue: "123"),
            requestFingerprint: PhotoSourceBatchKey.requestFingerprint(
                sourceID: .pexels,
                query: "private search phrase",
                batchSize: 80,
                policyVersion: policy.version,
                configurationPartition: "credential:test"
            )
        )
        let cursor = try position.cursor()

        XCTAssertLessThan(cursor.rawValue.utf8.count, 1_024)
        XCTAssertFalse(cursor.rawValue.contains("private search phrase"))
        XCTAssertEqual(
            try PhotoSourceBatchPosition.resolve(
                cursor,
                policy: policy,
                consumerPageSize: 20,
                requestFingerprint: position.requestFingerprint
            ),
            position
        )
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MiragePhotoSourceRequestTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct BatchSourceCall: Equatable, Sendable {
    let cursor: String?
    let pageSize: Int
}

private struct OpenverseBatchCall: Equatable, Sendable {
    let page: Int
    let pageSize: Int
}

/// 模拟匿名 Openverse 的 20 条硬上限，并按远端页码生成全局连续的稳定记录。
private actor TwentyRecordOpenverse: OpenverseSearching {
    private let lastPage: Int?
    private var calls: [OpenverseBatchCall] = []

    init(lastPage: Int? = nil) {
        self.lastPage = lastPage
    }

    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        calls.append(OpenverseBatchCall(page: page, pageSize: pageSize))
        let deliveredCount = min(pageSize, 20)
        let start = (page - 1) * 20
        let records = (start..<(start + deliveredCount)).map { index in
            let url = URL(string: "https://example.com/openverse/\(index).jpg")!
            return RemoteImageRecord(
                id: "openverse-\(index)",
                title: "Openverse \(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
        let nextPage = page == lastPage ? nil : page + 1
        return ImageSearchPage(records: records, nextPage: nextPage)
    }

    func recordedCalls() -> [OpenverseBatchCall] { calls }
}

private actor FailOnceSecondPageOpenverse: OpenverseSearching {
    private var hasFailed = false
    private var calls: [OpenverseBatchCall] = []

    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        calls.append(OpenverseBatchCall(page: page, pageSize: pageSize))
        if page == 2, !hasFailed {
            hasFailed = true
            throw URLError(.networkConnectionLost)
        }
        return ImageSearchPage(
            records: makeOpenverseRecords(page: page, pageSize: pageSize),
            nextPage: page + 1
        )
    }

    func recordedCalls() -> [OpenverseBatchCall] { calls }
}

private actor OverlappingOpenverse: OpenverseSearching {
    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        let start = page == 1 ? 0 : 19
        let records = (start..<(start + pageSize)).map { index in
            let url = URL(string: "https://example.com/openverse/\(index).jpg")!
            return RemoteImageRecord(
                id: "openverse-\(index)",
                title: "Openverse \(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
        return ImageSearchPage(records: records, nextPage: page + 1)
    }
}

private func makeOpenverseRecords(page: Int, pageSize: Int) -> [RemoteImageRecord] {
    let start = (page - 1) * 20
    return (start..<(start + min(pageSize, 20))).map { index in
        let url = URL(string: "https://example.com/openverse/\(index).jpg")!
        return RemoteImageRecord(
            id: "openverse-\(index)",
            title: "Openverse \(index)",
            source: .openverse,
            imageURL: url,
            thumbnailURL: url,
            license: .cc0
        )
    }
}

private actor BatchPhotoSource: PhotoSourceSearching {
    nonisolated let sourceID: PhotoSourceID
    private let delay: Duration
    private var calls: [BatchSourceCall] = []
    private var queries: [String] = []

    init(sourceID: PhotoSourceID, delay: Duration) {
        self.sourceID = sourceID
        self.delay = delay
    }

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        queries.append(query)
        calls.append(BatchSourceCall(cursor: cursor?.rawValue, pageSize: pageSize))
        if delay > .zero { try await Task.sleep(for: delay) }
        let page = cursor.flatMap { Int($0.rawValue) } ?? 1
        let start = (page - 1) * pageSize
        let records = (start..<(start + pageSize)).map { index in
            let url = URL(string: "https://example.com/\(sourceID.rawValue)/\(index).jpg")!
            let metadata = Self.metadata(for: sourceID)
            return RemoteImageRecord(
                id: "\(sourceID.rawValue)-\(index)",
                title: "Image \(index)",
                source: metadata.source,
                imageURL: url,
                thumbnailURL: url,
                license: metadata.license
            )
        }
        return PhotoSourcePage(
            records: records,
            nextCursor: page < 2 ? PhotoSourceCursor(rawValue: String(page + 1)) : nil
        )
    }

    func recordedCalls() -> [BatchSourceCall] { calls }
    func recordedQueries() -> [String] { queries }

    private static func metadata(for sourceID: PhotoSourceID) -> (source: ImageSource, license: LicenseInfo) {
        switch sourceID {
        case .openverse: return (.openverse, .cc0)
        case .metMuseum: return (.metMuseum, .cc0)
        case .nasa: return (.nasa, .nasaMediaUsage)
        case .pexels: return (.pexels, .pexels)
        case .pixabay: return (.pixabay, .pixabay)
        case .giphy: return (.giphy, .giphy)
        }
    }
}

private actor CancellationLeasePhotoSource: PhotoSourceSearching {
    nonisolated let sourceID = PhotoSourceID.openverse
    private var calls = 0

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        calls += 1
        if calls == 1 {
            try await Task.sleep(for: .seconds(30))
        }
        let records = (0..<pageSize).map { index in
            let url = URL(string: "https://example.com/openverse/cancel-\(index).jpg")!
            return RemoteImageRecord(
                id: "openverse-cancel-\(index)",
                title: "Openverse Cancel \(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
        return PhotoSourcePage(records: records, nextCursor: nil)
    }

    func waitForCalls(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if calls >= expected { return true }
            await Task.yield()
        }
        return calls >= expected
    }

    func callCount() -> Int { calls }
}

private actor RateLimitedPhotoSource: PhotoSourceSearching {
    nonisolated let sourceID = PhotoSourceID.pexels
    private let resetAt: Date
    private var calls = 0

    init(resetAt: Date) {
        self.resetAt = resetAt
    }

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        calls += 1
        throw PexelsError.rateLimited(resetAt: resetAt)
    }

    func callCount() -> Int { calls }
}

private actor QuotaPhotoSource: PhotoSourceSearching {
    nonisolated let sourceID = PhotoSourceID.pexels
    private let remaining: Int
    private let resetAt: Date?
    private var calls = 0

    init(remaining: Int, resetAt: Date?) {
        self.remaining = remaining
        self.resetAt = resetAt
    }

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        calls += 1
        let page = cursor.flatMap { Int($0.rawValue) } ?? 1
        let start = (page - 1) * pageSize
        let records = (start..<(start + pageSize)).map { index in
            let url = URL(string: "https://example.com/pexels/\(index).jpg")!
            return RemoteImageRecord(
                id: "pexels-quota-\(index)",
                title: "Image \(index)",
                source: .pexels,
                imageURL: url,
                thumbnailURL: url,
                license: .pexels
            )
        }
        return PhotoSourcePage(
            records: records,
            nextCursor: PhotoSourceCursor(rawValue: String(page + 1)),
            quota: PhotoSourceQuotaSnapshot(limit: 200, remaining: remaining, resetAt: resetAt)
        )
    }

    func callCount() -> Int { calls }
}

private actor ConcurrentBudgetPhotoSource: PhotoSourceSearching {
    nonisolated let sourceID = PhotoSourceID.pexels
    private let resetAt: Date
    private var queries: [String] = []
    private var slowStarted = false
    private var slowStartWaiters: [CheckedContinuation<Void, Never>] = []

    init(resetAt: Date) {
        self.resetAt = resetAt
    }

    func search(query: String, cursor: PhotoSourceCursor?, pageSize: Int) async throws -> PhotoSourcePage {
        queries.append(query)
        if query == "slow-success" {
            slowStarted = true
            let waiters = slowStartWaiters
            slowStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            try await Task.sleep(for: .milliseconds(180))
            let url = URL(string: "https://example.com/pexels/slow.jpg")!
            return PhotoSourcePage(
                records: [RemoteImageRecord(
                    id: "pexels-slow",
                    title: "Slow",
                    source: .pexels,
                    imageURL: url,
                    thumbnailURL: url,
                    license: .pexels
                )],
                nextCursor: nil,
                quota: PhotoSourceQuotaSnapshot(limit: 200, remaining: 100)
            )
        }
        if query == "rate-limited" {
            throw PexelsError.rateLimited(resetAt: resetAt)
        }
        let url = URL(string: "https://example.com/pexels/unexpected.jpg")!
        return PhotoSourcePage(records: [RemoteImageRecord(
            id: "pexels-unexpected",
            title: "Unexpected",
            source: .pexels,
            imageURL: url,
            thumbnailURL: url,
            license: .pexels
        )], nextCursor: nil)
    }

    func waitUntilSlowRequestStarts() async {
        if slowStarted { return }
        await withCheckedContinuation { continuation in
            slowStartWaiters.append(continuation)
        }
    }

    func recordedQueries() -> [String] { queries }
}
