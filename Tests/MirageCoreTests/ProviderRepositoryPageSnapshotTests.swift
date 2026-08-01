import FileProvider
import Foundation
import MirageCore
import UniformTypeIdentifiers
import XCTest

final class ProviderRepositoryPageSnapshotTests: XCTestCase {
    private var temporaryURL: URL!

    override func setUpWithError() throws {
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MirageProviderPageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryURL, FileManager.default.fileExists(atPath: temporaryURL.path) {
            try FileManager.default.removeItem(at: temporaryURL)
        }
    }

    /// 根目录一次固定发布 50 张及唯一“更多图片”，而不是在同一目录动态追加。
    func testPreparedRootPublishesFixedFiftyAndOneContinuation() async throws {
        let context = try makeContext()

        let root = try await context.catalog.preparedItems(for: .root)
        let images = Self.images(in: root)
        let continuations = Self.discoveryDirectories(in: root)

        XCTAssertEqual(images.count, 50)
        XCTAssertTrue(images.allSatisfy { $0.parentItemIdentifier == .rootContainer })
        XCTAssertEqual(continuations.count, 1)
        XCTAssertEqual(continuations[0].filename, "更多图片")
        XCTAssertEqual(continuations[0].itemIdentifier.rawValue, "discover-page:v3:2")
        XCTAssertEqual(root.last?.itemIdentifier, continuations[0].itemIdentifier)
        let avatarDirectory = try XCTUnwrap(
            root.first { $0.itemIdentifier == ProviderIdentifiers.avatars }
        )
        XCTAssertEqual(avatarDirectory.filename, "头像")
        XCTAssertEqual(avatarDirectory.parentItemIdentifier, .rootContainer)
        XCTAssertFalse(root.contains { $0.itemIdentifier.rawValue.hasPrefix("avatar:") })
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2, 3])
    }

    /// 同一根目录反复枚举只恢复冻结缓存，成员和远端请求数都不增长。
    func testRepeatedRootEnumerationKeepsTheSameFixedSnapshot() async throws {
        let context = try makeContext()

        let first = try await context.catalog.preparedItems(for: .root)
        let second = try await context.catalog.preparedItems(for: .root)

        XCTAssertEqual(first.map(\.itemIdentifier), second.map(\.itemIdentifier))
        XCTAssertEqual(Self.images(in: second).count, 50)
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2, 3])
    }

    /// “头像”目录按需生成 50 个稳定 DiceBear occurrence，完全不读取 Openverse 推荐流。
    func testAvatarFolderLoadsFiftyStableDiceBearItemsWithoutOpenverse() async throws {
        let context = try makeContext()

        let first = try await context.catalog.preparedItems(for: .avatars)
        let images = Self.images(in: first)
        XCTAssertEqual(images.count, 50)
        XCTAssertEqual(Set(images.map(\.itemIdentifier)).count, 50)
        XCTAssertTrue(images.allSatisfy {
            $0.parentItemIdentifier == ProviderIdentifiers.avatars
                && $0.itemIdentifier.rawValue.hasPrefix("avatar:db:v10:")
        })
        let initialOpenverseRequests = await context.openverse.requestedPages()
        XCTAssertEqual(initialOpenverseRequests, [])
        let diceBearRequests = await context.diceBear.requests()
        XCTAssertEqual(
            diceBearRequests,
            [
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 0, count: 20),
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 20, count: 20),
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 40, count: 10)
            ]
        )

        for item in images {
            let occurrence = try await context.repository.occurrence(for: item.itemIdentifier)
            XCTAssertEqual(occurrence?.record.source, .diceBear)
        }

        let second = try await context.catalog.preparedItems(for: .avatars)
        XCTAssertEqual(first.map(\.itemIdentifier), second.map(\.itemIdentifier))
        let repeatedOpenverseRequests = await context.openverse.requestedPages()
        XCTAssertEqual(repeatedOpenverseRequests, [])
        let repeatedDiceBearRequests = await context.diceBear.requests()
        XCTAssertEqual(repeatedDiceBearRequests, diceBearRequests)

        let restoredRepository = ProviderRepository(
            manager: nil,
            storage: context.storage,
            discoveryFeed: context.discoveryFeed,
            diceBear: context.diceBear
        )
        let firstIdentifier = try XCTUnwrap(images.first?.itemIdentifier)
        let restored = try await restoredRepository.occurrence(for: firstIdentifier)
        XCTAssertEqual(restored?.record.source, .diceBear)

        let forgedIdentifier = ProviderIdentifiers.itemIdentifier(
            recordID: "db:v10:forged",
            view: .avatar
        )
        let forged = try await restoredRepository.occurrence(for: forgedIdentifier)
        XCTAssertNil(forged)
    }

    /// 单条头像 JSON 损坏时缓存应失效并被确定性结果覆盖，不能让目录持续枚举失败。
    func testAvatarFolderRegeneratesCorruptCachedRecord() async throws {
        let context = try makeContext()
        let first = try await context.catalog.preparedItems(for: .avatars)
        let itemDirectory = temporaryURL.appendingPathComponent("items", isDirectory: true)
        let cachedFiles = try FileManager.default.contentsOfDirectory(
            at: itemDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let corruptFile = try XCTUnwrap(cachedFiles.first)
        try Data("not-json".utf8).write(to: corruptFile, options: .atomic)

        let regenerated = try await context.catalog.preparedItems(for: .avatars)
        XCTAssertEqual(first.map(\.itemIdentifier), regenerated.map(\.itemIdentifier))
        let regeneratedRequests = await context.diceBear.requests()
        XCTAssertEqual(regeneratedRequests.count, 6)

        let cachedAgain = try await context.catalog.preparedItems(for: .avatars)
        XCTAssertEqual(regenerated.map(\.itemIdentifier), cachedAgain.map(\.itemIdentifier))
        let cachedRequests = await context.diceBear.requests()
        XCTAssertEqual(cachedRequests.count, 6)
    }

    /// 系统可能先枚举 working set；其中已经发布的根入口也必须能被回查和打开。
    func testWorkingSetPublicationAuthorizesSecondPage() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .workingSet)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        let directory = try await context.catalog.item(for: second.itemIdentifier)

        XCTAssertEqual(directory?.itemIdentifier, second.itemIdentifier)
        XCTAssertEqual(directory?.filename, "更多图片")

        let child = try await context.catalog.preparedItems(for: .discoveryPage(second))
        XCTAssertEqual(Self.images(in: child).count, 50)
    }

    /// 未被根 scope 发布的第 2 层不能通过构造 ID 提前联网。
    func testUnpublishedSecondPageIsRejectedWithoutNetwork() async throws {
        let context = try makeContext()
        let page = try XCTUnwrap(DiscoveryPageReference(page: 2))

        await XCTAssertThrowsErrorAsync(try await context.repository.discoveryBatch(for: page)) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(error.code, NSFileProviderError.Code.noSuchItem.rawValue)
        }
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [])
    }

    /// 打开“更多图片”才加载下一固定 50 张，并只在该子目录发布下一层入口。
    func testOpeningSecondPageLoadsNextFiftyAndPublishesThirdPage() async throws {
        let context = try makeContext()
        let root = try await context.catalog.preparedItems(for: .root)
        let page = try XCTUnwrap(DiscoveryPageReference(page: 2))

        let child = try await context.catalog.preparedItems(for: .discoveryPage(page))
        let images = Self.images(in: child)
        let continuation = try XCTUnwrap(Self.discoveryDirectories(in: child).only)

        XCTAssertEqual(images.count, 50)
        XCTAssertTrue(images.allSatisfy { $0.parentItemIdentifier == page.itemIdentifier })
        XCTAssertEqual(images.first?.itemIdentifier.rawValue, "discover-page-item:v3:2:provider:3:10")
        XCTAssertEqual(images.last?.itemIdentifier.rawValue, "discover-page-item:v3:2:provider:5:19")
        XCTAssertEqual(continuation.itemIdentifier.rawValue, "discover-page:v3:3")
        XCTAssertEqual(continuation.parentItemIdentifier, page.itemIdentifier)
        XCTAssertEqual(continuation.filename, "更多图片")
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2, 3, 4, 5])

        let rootAgain = try await context.catalog.preparedItems(for: .root)
        XCTAssertEqual(root.map(\.itemIdentifier), rootAgain.map(\.itemIdentifier))
    }

    /// 只打开根目录不会授权第 3 层；伪造深层 ID 既失败也不增加网络请求。
    func testUnannouncedDeepPageIsRejectedWithoutAdditionalNetwork() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let before = await context.openverse.requestedPages()
        let page = try XCTUnwrap(DiscoveryPageReference(page: 3))

        await XCTAssertThrowsErrorAsync(try await context.repository.discoveryBatch(for: page)) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(error.code, NSFileProviderError.Code.noSuchItem.rawValue)
        }
        let after = await context.openverse.requestedPages()
        XCTAssertEqual(after, before)
    }

    /// 第 2 层发布第 3 层后，递归打开继续得到独立的 50 张固定快照。
    func testOpeningThirdPageContinuesRecursively() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        _ = try await context.catalog.preparedItems(for: .discoveryPage(second))
        let third = try XCTUnwrap(DiscoveryPageReference(page: 3))

        let items = try await context.catalog.preparedItems(for: .discoveryPage(third))
        let images = Self.images(in: items)
        let continuation = try XCTUnwrap(Self.discoveryDirectories(in: items).only)

        XCTAssertEqual(images.count, 50)
        XCTAssertTrue(images.allSatisfy { $0.parentItemIdentifier == third.itemIdentifier })
        XCTAssertEqual(images.first?.itemIdentifier.rawValue, "discover-page-item:v3:3:provider:6:0")
        XCTAssertEqual(images.last?.itemIdentifier.rawValue, "discover-page-item:v3:3:provider:8:9")
        XCTAssertEqual(continuation.itemIdentifier.rawValue, "discover-page:v3:4")
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, Array(1...8))
    }

    /// 第 4 批之后仍须发布并打开第 5 批，避免 Finder 在 4×50 张处形成伪上限。
    func testOpeningFourthPagePublishesAndOpensFifthPage() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        for page in 2...3 {
            let reference = try XCTUnwrap(DiscoveryPageReference(page: page))
            _ = try await context.catalog.preparedItems(for: .discoveryPage(reference))
        }

        let fourth = try XCTUnwrap(DiscoveryPageReference(page: 4))
        let fourthItems = try await context.catalog.preparedItems(for: .discoveryPage(fourth))
        let fifth = try XCTUnwrap(DiscoveryPageReference(page: 5))
        let fifthContinuation = try XCTUnwrap(Self.discoveryDirectories(in: fourthItems).only)
        XCTAssertEqual(fifthContinuation.itemIdentifier, fifth.itemIdentifier)
        XCTAssertEqual(fifthContinuation.parentItemIdentifier, fourth.itemIdentifier)

        let resolvedFifth = try await context.catalog.item(for: fifth.itemIdentifier)
        XCTAssertEqual(resolvedFifth?.itemIdentifier, fifth.itemIdentifier)
        XCTAssertEqual(resolvedFifth?.discoveryGeneration, fifthContinuation.discoveryGeneration)

        let fifthItems = try await context.catalog.preparedItems(for: .discoveryPage(fifth))
        let fifthImages = Self.images(in: fifthItems)
        let sixth = try XCTUnwrap(DiscoveryPageReference(page: 6))
        let sixthContinuation = try XCTUnwrap(Self.discoveryDirectories(in: fifthItems).only)
        XCTAssertEqual(fifthImages.count, 50)
        XCTAssertEqual(
            fifthImages.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:5:provider:11:0"
        )
        XCTAssertEqual(
            fifthImages.last?.itemIdentifier.rawValue,
            "discover-page-item:v3:5:provider:13:9"
        )
        XCTAssertEqual(sixthContinuation.itemIdentifier, sixth.itemIdentifier)
        XCTAssertEqual(sixthContinuation.parentItemIdentifier, fifth.itemIdentifier)
        let maximumOpenedPage = try await context.storage.maximumOpenedProviderDiscoveryPage()
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(maximumOpenedPage, 5)
        XCTAssertEqual(requestedPages, Array(1...13))
    }

    /// 残缺旧状态恢复后必须能从当前根重新建立 lineage，并继续打开第 5 批。
    func testIncompleteProviderStateRecoversBeforeOpeningFifthPage() async throws {
        let stateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        let incompleteData = Data(
            """
            {"schemaVersion":3,"generation":77,"minimumValidAnchor":0,"maximumOpenedDiscoveryPage":2,"scopes":{"discovery:v3:2":{"items":[{"identifier":"discover-page-item:v3:2:legacy","fingerprint":"v1"}],"history":[],"minimumValidAnchor":0,"hasCommittedSnapshot":true}}}
            """.utf8
        )
        try incompleteData.write(to: stateURL, options: .atomic)

        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        for page in 2...4 {
            let reference = try XCTUnwrap(DiscoveryPageReference(page: page))
            _ = try await context.catalog.preparedItems(for: .discoveryPage(reference))
        }

        let fifth = try XCTUnwrap(DiscoveryPageReference(page: 5))
        let fifthDirectory = try await context.catalog.item(for: fifth.itemIdentifier)
        let fifthItems = try await context.catalog.preparedItems(for: .discoveryPage(fifth))
        let sixth = try XCTUnwrap(DiscoveryPageReference(page: 6))
        let sixthContinuation = try XCTUnwrap(Self.discoveryDirectories(in: fifthItems).only)
        let maximumOpenedPage = try await context.storage.maximumOpenedProviderDiscoveryPage()

        XCTAssertEqual(fifthDirectory?.itemIdentifier, fifth.itemIdentifier)
        XCTAssertEqual(Self.images(in: fifthItems).count, 50)
        XCTAssertEqual(sixthContinuation.itemIdentifier, sixth.itemIdentifier)
        XCTAssertEqual(maximumOpenedPage, 5)
    }

    /// 父入口发布后即使共享推荐已换代，子目录也必须沿父代次续读，不能切到新首页偏移。
    func testPublishedContinuationKeepsParentGenerationAcrossRefresh() async throws {
        let context = try makeContext()
        let root = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        let publishedGeneration = try XCTUnwrap(
            Self.discoveryDirectories(in: root).only?.discoveryGeneration
        )

        let refreshed = Self.records(prefix: "refreshed", count: 120)
        let refreshedGeneration = try await context.storage.commitDiscoveryFeed(
            records: refreshed,
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: nil
        ).generation
        XCTAssertNotEqual(refreshedGeneration, publishedGeneration)

        let child = try await context.catalog.preparedItems(for: .discoveryPage(second))
        let images = Self.images(in: child)
        XCTAssertEqual(images.count, 50)
        XCTAssertTrue(images.allSatisfy { $0.discoveryGeneration == publishedGeneration })
        XCTAssertEqual(images.first?.itemIdentifier.rawValue, "discover-page-item:v3:2:provider:3:10")
        XCTAssertEqual(images.last?.itemIdentifier.rawValue, "discover-page-item:v3:2:provider:5:19")
        XCTAssertFalse(images.contains { $0.itemIdentifier.rawValue.contains("refreshed") })
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2, 3, 4, 5])
    }

    /// 完整历史代次被裁剪后，残留底层页 sidecar 不能造成死循环或偷偷切换到当前代次。
    func testPrunedPublishedGenerationExpiresInsteadOfLoopingOrMixing() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        for index in 0..<10 {
            _ = try await context.storage.commitDiscoveryFeed(
                records: Self.records(prefix: "replacement-\(index)", count: 20),
                refreshedAt: Date().addingTimeInterval(Double(index + 1)),
                source: .network,
                catalogKey: DiscoveryRecommendation.catalogKey,
                queryKey: DiscoveryRecommendation.query,
                nextPage: 2
            )
        }
        let requestsBefore = await context.openverse.requestedPages()

        await XCTAssertThrowsErrorAsync(
            try await context.repository.discoveryBatch(for: second)
        ) { error in
            let providerError = error as NSError
            XCTAssertEqual(providerError.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(providerError.code, NSFileProviderError.Code.pageExpired.rawValue)
        }
        let requestsAfter = await context.openverse.requestedPages()
        XCTAssertEqual(requestsAfter, requestsBefore)
    }

    /// 根换代移除 continuation 后，旧深层 scope 与 occurrence 都必须因祖先断链而失效。
    func testOrphanedDescendantsAreRejectedAfterRootLineageEnds() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        _ = try await context.catalog.preparedItems(for: .discoveryPage(second))
        let third = try XCTUnwrap(DiscoveryPageReference(page: 3))
        let thirdItems = try await context.catalog.preparedItems(for: .discoveryPage(third))
        let oldOccurrence = try XCTUnwrap(Self.images(in: thirdItems).first)
        let fourth = try XCTUnwrap(DiscoveryPageReference(page: 4))

        _ = try await context.storage.commitDiscoveryFeed(
            records: Self.records(prefix: "terminal", count: 40),
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: nil
        )
        let refreshedRoot = try await context.catalog.preparedItems(for: .root)
        XCTAssertTrue(Self.discoveryDirectories(in: refreshedRoot).isEmpty)
        let requestsBeforeRejection = await context.openverse.requestedPages()

        await XCTAssertThrowsErrorAsync(try await context.repository.discoveryBatch(for: fourth)) {
            let error = $0 as NSError
            XCTAssertEqual(error.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(error.code, NSFileProviderError.Code.noSuchItem.rawValue)
        }
        let restoredOccurrence = try await context.repository.occurrence(
            for: oldOccurrence.itemIdentifier
        )
        XCTAssertNil(restoredOccurrence)
        let requestsAfterRejection = await context.openverse.requestedPages()
        XCTAssertEqual(requestsAfterRejection, requestsBeforeRejection)
    }

    /// working set 包含所有已打开且根可达的深层项；根换代后不再带回旧子树。
    func testWorkingSetRestoresReachableOpenedPagesAndPrunesStaleLineage() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        let secondItems = try await context.catalog.preparedItems(for: .discoveryPage(second))
        let third = try XCTUnwrap(DiscoveryPageReference(page: 3))
        let thirdItems = try await context.catalog.preparedItems(for: .discoveryPage(third))
        let secondImage = try XCTUnwrap(Self.images(in: secondItems).first)
        let thirdImage = try XCTUnwrap(Self.images(in: thirdItems).first)

        let workingSet = try await context.catalog.preparedItems(for: .workingSet)
        XCTAssertTrue(workingSet.contains { $0.itemIdentifier == secondImage.itemIdentifier })
        XCTAssertTrue(workingSet.contains { $0.itemIdentifier == thirdImage.itemIdentifier })
        XCTAssertTrue(workingSet.contains { $0.itemIdentifier.rawValue == "discover-page:v3:4" })

        _ = try await context.storage.commitDiscoveryFeed(
            records: Self.records(prefix: "replacement", count: 40),
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: nil
        )
        let refreshedWorkingSet = try await context.catalog.preparedItems(for: .workingSet)
        XCTAssertFalse(refreshedWorkingSet.contains { $0.itemIdentifier == secondImage.itemIdentifier })
        XCTAssertFalse(refreshedWorkingSet.contains { $0.itemIdentifier == thirdImage.itemIdentifier })
        XCTAssertTrue(Self.discoveryDirectories(in: refreshedWorkingSet).isEmpty)
    }

    /// 换代后只要 continuation 仍存在，working set 必须按已打开深度交付新代次 children，不能留下空目录。
    func testWorkingSetRebuildsOpenedPageAfterGenerationRefresh() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        let oldSecond = try await context.catalog.preparedItems(for: .discoveryPage(second))
        _ = try await context.catalog.preparedItems(for: .workingSet)
        let oldImage = try XCTUnwrap(Self.images(in: oldSecond).first)

        let refreshedGeneration = try await context.storage.commitDiscoveryFeed(
            records: Self.records(prefix: "refreshed", count: 130),
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: nil
        ).generation

        let refreshedWorkingSet = try await context.catalog.preparedItems(for: .workingSet)
        let rebuiltChildren = Self.images(in: refreshedWorkingSet).filter {
            $0.parentItemIdentifier == second.itemIdentifier
        }
        XCTAssertEqual(rebuiltChildren.count, 50)
        XCTAssertTrue(rebuiltChildren.allSatisfy {
            $0.discoveryGeneration == refreshedGeneration
        })
        XCTAssertEqual(
            rebuiltChildren.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:2:refreshed:50"
        )
        XCTAssertEqual(
            rebuiltChildren.last?.itemIdentifier.rawValue,
            "discover-page-item:v3:2:refreshed:99"
        )
        XCTAssertFalse(refreshedWorkingSet.contains { $0.itemIdentifier == oldImage.itemIdentifier })
        XCTAssertTrue(refreshedWorkingSet.contains {
            $0.itemIdentifier.rawValue == "discover-page:v3:3"
                && $0.discoveryGeneration == refreshedGeneration
        })
        let committedSecondSnapshot = try await context.storage.providerScopeSnapshot(
            ProviderEnumerationScope.discoveryPage(second).storageKey
        )
        let committedSecond = try XCTUnwrap(committedSecondSnapshot)
        XCTAssertFalse(committedSecond.isEmpty)
        XCTAssertTrue(committedSecond.allSatisfy {
            $0.discoveryGeneration == refreshedGeneration
        })
        let maximumOpenedPage = try await context.storage.maximumOpenedProviderDiscoveryPage()
        XCTAssertEqual(maximumOpenedPage, 2)
    }

    /// 已打开到第 3 层时，换代 working set 必须一次持久化两层新子树，且不能预取第 4 层内容。
    func testWorkingSetAtomicallyRebuildsTwoOpenedPagesAfterGenerationRefresh() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        let oldSecond = try await context.catalog.preparedItems(for: .discoveryPage(second))
        let third = try XCTUnwrap(DiscoveryPageReference(page: 3))
        let oldThird = try await context.catalog.preparedItems(for: .discoveryPage(third))
        _ = try await context.catalog.preparedItems(for: .workingSet)
        let oldChildIDs = Set(
            (Self.images(in: oldSecond) + Self.images(in: oldThird)).map(\.itemIdentifier)
        )
        let maximumOpenedPageBeforeRefresh = try await context.storage
            .maximumOpenedProviderDiscoveryPage()
        XCTAssertEqual(maximumOpenedPageBeforeRefresh, 3)

        let requestsBeforeRefresh = await context.openverse.requestedPages()
        XCTAssertEqual(requestsBeforeRefresh, Array(1...8))
        await context.openverse.useRecordPrefix("refreshed")
        let refreshedGeneration = try await context.storage.commitDiscoveryFeed(
            records: Self.records(prefix: "refreshed", page: 1),
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: 2
        ).generation

        let refreshedWorkingSet = try await context.catalog.preparedItems(for: .workingSet)
        let rebuiltSecond = Self.images(in: refreshedWorkingSet).filter {
            $0.parentItemIdentifier == second.itemIdentifier
        }
        let rebuiltThird = Self.images(in: refreshedWorkingSet).filter {
            $0.parentItemIdentifier == third.itemIdentifier
        }
        XCTAssertEqual(rebuiltSecond.count, 50)
        XCTAssertEqual(rebuiltThird.count, 50)
        XCTAssertTrue((rebuiltSecond + rebuiltThird).allSatisfy {
            $0.discoveryGeneration == refreshedGeneration
        })
        XCTAssertEqual(
            rebuiltSecond.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:2:refreshed:3:10"
        )
        XCTAssertEqual(
            rebuiltSecond.last?.itemIdentifier.rawValue,
            "discover-page-item:v3:2:refreshed:5:19"
        )
        XCTAssertEqual(
            rebuiltThird.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:3:refreshed:6:0"
        )
        XCTAssertEqual(
            rebuiltThird.last?.itemIdentifier.rawValue,
            "discover-page-item:v3:3:refreshed:8:9"
        )
        XCTAssertTrue(oldChildIDs.isDisjoint(with: Set(
            refreshedWorkingSet.map(\.itemIdentifier)
        )))

        let thirdContinuation = try XCTUnwrap(
            Self.discoveryDirectories(in: refreshedWorkingSet).first {
                $0.parentItemIdentifier == second.itemIdentifier
            }
        )
        XCTAssertEqual(thirdContinuation.itemIdentifier, third.itemIdentifier)
        XCTAssertEqual(thirdContinuation.discoveryGeneration, refreshedGeneration)
        let fourth = try XCTUnwrap(DiscoveryPageReference(page: 4))
        let fourthContinuation = try XCTUnwrap(
            Self.discoveryDirectories(in: refreshedWorkingSet).first {
                $0.parentItemIdentifier == third.itemIdentifier
            }
        )
        XCTAssertEqual(fourthContinuation.itemIdentifier, fourth.itemIdentifier)
        XCTAssertEqual(fourthContinuation.discoveryGeneration, refreshedGeneration)

        let persistedStorage = try AppGroupStorage(baseURL: temporaryURL)
        let persistedSecondSnapshot = try await persistedStorage.providerScopeSnapshot(
            ProviderEnumerationScope.discoveryPage(second).storageKey
        )
        let persistedThirdSnapshot = try await persistedStorage.providerScopeSnapshot(
            ProviderEnumerationScope.discoveryPage(third).storageKey
        )
        let persistedWorkingSetSnapshot = try await persistedStorage.providerScopeSnapshot(
            ProviderEnumerationScope.workingSet.storageKey
        )
        let persistedFourthSnapshot = try await persistedStorage.providerScopeSnapshot(
            ProviderEnumerationScope.discoveryPage(fourth).storageKey
        )
        let persistedSecond = try XCTUnwrap(persistedSecondSnapshot)
        let persistedThird = try XCTUnwrap(persistedThirdSnapshot)
        let persistedWorkingSet = try XCTUnwrap(persistedWorkingSetSnapshot)
        XCTAssertEqual(persistedSecond.count, 51)
        XCTAssertEqual(persistedThird.count, 51)
        XCTAssertTrue((persistedSecond + persistedThird).allSatisfy {
            $0.discoveryGeneration == refreshedGeneration
        })
        XCTAssertEqual(
            Set(persistedWorkingSet.map(\.identifier)),
            Set(refreshedWorkingSet.map { $0.itemIdentifier.rawValue })
        )
        XCTAssertTrue(persistedWorkingSet.compactMap(\.discoveryGeneration).allSatisfy {
            $0 == refreshedGeneration
        })
        let maximumOpenedPageAfterRefresh = try await persistedStorage
            .maximumOpenedProviderDiscoveryPage()
        XCTAssertEqual(maximumOpenedPageAfterRefresh, 3)
        XCTAssertNil(persistedFourthSnapshot)

        let requestsAfterRefresh = await context.openverse.requestedPages()
        XCTAssertEqual(
            Array(requestsAfterRefresh.dropFirst(requestsBeforeRefresh.count)),
            Array(2...8)
        )
    }

    /// 子页完成加载后若祖先已经换代，条件提交必须拒绝迟到旧快照且不能推进已打开深度。
    func testLateOldGenerationPageCommitIsRejectedAtomically() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        let staleItems = try await context.catalog.items(for: .discoveryPage(second))
        let staleGeneration = try XCTUnwrap(staleItems.first?.discoveryGeneration)

        let refreshedGeneration = try await context.storage.commitDiscoveryFeed(
            records: Self.records(prefix: "new-authority", count: 130),
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: nil
        ).generation
        XCTAssertNotEqual(staleGeneration, refreshedGeneration)
        _ = try await context.catalog.preparedItems(for: .workingSet)

        await XCTAssertThrowsErrorAsync(
            try await context.repository.commitScope(
                .discoveryPage(second),
                items: staleItems,
                migratesLegacySearch: false
            )
        ) { error in
            let providerError = error as NSError
            XCTAssertEqual(providerError.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(providerError.code, NSFileProviderError.Code.pageExpired.rawValue)
        }
        let rejectedScope = try await context.storage.providerScopeSnapshot(
            ProviderEnumerationScope.discoveryPage(second).storageKey
        )
        let rejectedOpenedPage = try await context.storage.maximumOpenedProviderDiscoveryPage()
        XCTAssertNil(rejectedScope)
        XCTAssertNil(rejectedOpenedPage)

        let currentItems = try await context.catalog.preparedItems(for: .discoveryPage(second))
        XCTAssertTrue(currentItems.allSatisfy {
            $0.discoveryGeneration == refreshedGeneration
        })
        let currentOpenedPage = try await context.storage.maximumOpenedProviderDiscoveryPage()
        XCTAssertEqual(currentOpenedPage, 2)
    }

    /// 远端在第二个 50 张窗口中结束时，只发布实际剩余图片且不制造空 continuation。
    func testRepositoryTerminalPartialBatchHasNoContinuation() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        _ = try await storage.commitDiscoveryFeed(
            records: Self.records(prefix: "finite", count: 73),
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: nil
        )
        let context = try makeContext(storage: storage)
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))

        let child = try await context.catalog.preparedItems(for: .discoveryPage(second))
        XCTAssertEqual(Self.images(in: child).count, 23)
        XCTAssertTrue(Self.discoveryDirectories(in: child).isEmpty)
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [])
    }

    /// 分页图片只有在所属 scope 已发布时才可回查，不能借逐条缓存伪造 occurrence。
    func testPagedOccurrenceRequiresPublishedMembership() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        let items = try await context.catalog.preparedItems(for: .discoveryPage(second))
        let published = try XCTUnwrap(Self.images(in: items).first)

        let restored = try await context.repository.occurrence(for: published.itemIdentifier)
        XCTAssertEqual(restored?.reference.itemIdentifier, published.itemIdentifier)

        let forged = ProviderIdentifiers.discoveryPageItemIdentifier(
            recordID: "provider:1:0",
            page: second
        )
        let rejected = try await context.repository.occurrence(for: forged)
        XCTAssertNil(rejected)
    }

    /// 旧完整快照仍按底层 20 张边界迁移；Provider 的 50 张只是无损聚合层。
    func testLegacyGenerationMigratesToExactUnderlyingPageSnapshots() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let records = Self.records(page: 1) + Self.records(page: 2)
        let generation = try await storage.commitDiscoveryFeed(
            records: records,
            refreshedAt: Date(),
            source: .network,
            catalogKey: DiscoveryRecommendation.catalogKey,
            queryKey: DiscoveryRecommendation.query,
            nextPage: 3
        ).generation

        let storedFirst = try await storage.readDiscoveryPageSnapshot(
            generation: generation,
            page: 1
        )
        let storedSecond = try await storage.readDiscoveryPageSnapshot(
            generation: generation,
            page: 2
        )
        let first = try XCTUnwrap(storedFirst)
        let second = try XCTUnwrap(storedSecond)

        XCTAssertEqual(first.records.map(\.id), Array(records.prefix(20)).map(\.id))
        XCTAssertEqual(second.records.map(\.id), Array(records.dropFirst(20)).map(\.id))
        XCTAssertEqual(first.nextPage, 2)
        XCTAssertEqual(second.nextPage, 3)
    }

    private func makeContext(storage injectedStorage: AppGroupStorage? = nil) throws -> ProviderTestContext {
        let storage: AppGroupStorage
        if let injectedStorage {
            storage = injectedStorage
        } else {
            storage = try AppGroupStorage(baseURL: temporaryURL)
        }
        let openverse = ProviderPagedOpenverse()
        let diceBear = ProviderRecordingDiceBear()
        let feed = DiscoveryFeedRepository(
            storage: storage,
            service: ImageSearchService(openverse: openverse, diceBear: diceBear),
            diceBear: diceBear
        )
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: feed,
            diceBear: diceBear
        )
        return ProviderTestContext(
            openverse: openverse,
            diceBear: diceBear,
            discoveryFeed: feed,
            storage: storage,
            repository: repository,
            catalog: ProviderCatalog(repository: repository)
        )
    }

    private static func images(in items: [ProviderItem]) -> [ProviderItem] {
        items.filter { $0.contentType == .png }
    }

    private static func discoveryDirectories(in items: [ProviderItem]) -> [ProviderItem] {
        let fixed: Set<NSFileProviderItemIdentifier> = [
            ProviderIdentifiers.avatars,
            ProviderIdentifiers.recent,
            ProviderIdentifiers.favorites,
            ProviderIdentifiers.searchBacking
        ]
        return items.filter { $0.contentType == .folder && !fixed.contains($0.itemIdentifier) }
    }

    fileprivate static func records(
        prefix: String = "provider",
        page: Int
    ) -> [RemoteImageRecord] {
        (0..<DiscoveryRecommendation.pageSize).map { index in
            let url = URL(string: "https://example.com/\(prefix)-\(page)-\(index).png")!
            return RemoteImageRecord(
                id: "\(prefix):\(page):\(index)",
                title: "\(prefix.capitalized) \(page)-\(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
    }

    fileprivate static func records(prefix: String, count: Int) -> [RemoteImageRecord] {
        (0..<count).map { index in
            let url = URL(string: "https://example.com/\(prefix)-\(index).png")!
            return RemoteImageRecord(
                id: "\(prefix):\(index)",
                title: "\(prefix) \(index)",
                source: .openverse,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0
            )
        }
    }
}

private struct ProviderTestContext {
    let openverse: ProviderPagedOpenverse
    let diceBear: ProviderRecordingDiceBear
    let discoveryFeed: DiscoveryFeedRepository
    let storage: AppGroupStorage
    let repository: ProviderRepository
    let catalog: ProviderCatalog
}

private struct ProviderDiceBearRequest: Equatable, Sendable {
    let query: String
    let offset: Int
    let count: Int
}

private actor ProviderRecordingDiceBear: DiceBearProviding {
    private let client = DiceBearClient(styles: [.pixelArt])
    private var recordedRequests: [ProviderDiceBearRequest] = []

    func avatars(query: String, offset: Int, count: Int) async -> [RemoteImageRecord] {
        recordedRequests.append(
            ProviderDiceBearRequest(query: query, offset: offset, count: count)
        )
        return await client.avatars(query: query, offset: offset, count: count)
    }

    func requests() -> [ProviderDiceBearRequest] { recordedRequests }
}

private actor ProviderPagedOpenverse: OpenverseSearching {
    private var pages: [Int] = []
    private var recordPrefix = "provider"

    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        pages.append(page)
        return ImageSearchPage(
            records: ProviderRepositoryPageSnapshotTests.records(prefix: recordPrefix, page: page),
            nextPage: page + 1
        )
    }

    func useRecordPrefix(_ prefix: String) {
        recordPrefix = prefix
    }

    func requestedPages() -> [Int] { pages }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
