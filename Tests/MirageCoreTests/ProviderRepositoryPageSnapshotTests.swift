import FileProvider
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MirageCore

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

    /// 根目录一次固定发布 40 张及唯一“更多图片”，而不是在同一目录动态追加。
    func testPreparedRootPublishesFixedFortyAndOneContinuation() async throws {
        let context = try makeContext()

        let root = try await context.catalog.preparedItems(for: .root)
        let images = Self.images(in: root)
        let continuations = Self.discoveryDirectories(in: root)

        XCTAssertEqual(images.count, 40)
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
        XCTAssertEqual(requestedPages, [1, 2])
    }

    /// 同一根目录反复枚举只恢复冻结缓存，成员和远端请求数都不增长。
    func testRepeatedRootEnumerationKeepsTheSameFixedSnapshot() async throws {
        let context = try makeContext()

        let first = try await context.catalog.preparedItems(for: .root)
        let second = try await context.catalog.preparedItems(for: .root)

        XCTAssertEqual(first.map(\.itemIdentifier), second.map(\.itemIdentifier))
        XCTAssertEqual(Self.images(in: second).count, 40)
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2])
    }

    /// Finder 严格跟随 App 图片来源筛选，所有普通图片来源都可显示，头像和 GIF 不得混入。
    func testRootTracksSharedPhotoSourceSelectionAndExcludesNonPhotoRecords() async throws {
        let suiteName = "MirageProviderPageTests.PhotoFilters.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let filters = DiscoveryFilterPreferencesStore(userDefaults: defaults)
        filters.setPhotoSourceID(.pexels)

        let openverse = Self.record(id: "openverse", source: .openverse)
        let metMuseum = Self.record(id: "met", source: .metMuseum)
        let nasa = Self.record(id: "nasa", source: .nasa)
        let pexels = Self.record(id: "pexels", source: .pexels)
        let pixabay = Self.record(id: "pixabay", source: .pixabay)
        let avatar = RemoteImageRecord(
            id: "db:v13:2025-08-03:avatar",
            title: "Avatar",
            source: .diceBear,
            avatarType: .cartoonCharacter,
            imageURL: URL(string: "https://example.com/avatar.png")!,
            thumbnailURL: URL(string: "https://example.com/avatar.png")!,
            license: .cc0
        )
        let giphy = Self.record(id: "giphy", source: .giphy)
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderStaticDiscoveryFeed(
                records: [openverse, metMuseum, nasa, pexels, pixabay, avatar, giphy]
            ),
            filterPreferences: filters
        )

        let root = try await ProviderCatalog(repository: repository)
            .preparedItems(for: .root)
        let visible = Self.images(in: root)

        XCTAssertEqual(
            visible.compactMap {
                ProviderIdentifiers.recordReference(from: $0.itemIdentifier)?.recordID
            },
            [pexels.id]
        )
        XCTAssertTrue(visible.allSatisfy { $0.parentItemIdentifier == .rootContainer })
        for item in visible {
            let occurrence = try await repository.occurrence(for: item.itemIdentifier)
            XCTAssertEqual(occurrence?.record.source, .pexels)
        }

        filters.setPhotoSourceID(nil)
        let allSourcesRoot = try await ProviderCatalog(repository: repository)
            .preparedItems(for: .root)
        XCTAssertEqual(
            Self.images(in: allSourcesRoot).compactMap {
                ProviderIdentifiers.recordReference(from: $0.itemIdentifier)?.recordID
            },
            [openverse.id, metMuseum.id, nasa.id, pexels.id, pixabay.id]
        )

        let recordsBySourceID: [PhotoSourceID: RemoteImageRecord] = [
            .metMuseum: metMuseum,
            .nasa: nasa,
            .pixabay: pixabay,
        ]
        for sourceID in [PhotoSourceID.metMuseum, .nasa, .pixabay] {
            filters.setPhotoSourceID(sourceID)
            let selectedSourceRoot = try await ProviderCatalog(repository: repository)
                .preparedItems(for: .root)
            XCTAssertEqual(
                Self.images(in: selectedSourceRoot).compactMap {
                    ProviderIdentifiers.recordReference(from: $0.itemIdentifier)?.recordID
                },
                [recordsBySourceID[sourceID]?.id].compactMap { $0 }
            )
            let workingSet = try await ProviderCatalog(repository: repository)
                .preparedItems(for: .workingSet)
            XCTAssertEqual(
                Self.images(in: workingSet).compactMap {
                    ProviderIdentifiers.recordReference(from: $0.itemIdentifier)?.recordID
                },
                [recordsBySourceID[sourceID]?.id].compactMap { $0 }
            )
        }
    }

    /// 无结果的纯图片快照仍必须发布根目录固定入口，不能将整个域误报为过期页。
    func testEmptyPhotoSnapshotKeepsRootDirectoriesAvailable() async throws {
        let suiteName = "MirageProviderPageTests.EmptyPhotoFilter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderEmptyDiscoveryFeed(),
            filterPreferences: DiscoveryFilterPreferencesStore(userDefaults: defaults)
        )
        let catalog = ProviderCatalog(repository: repository)

        let root = try await catalog.preparedItems(for: .root)
        let workingSet = try await catalog.preparedItems(for: .workingSet)

        XCTAssertTrue(Self.images(in: root).isEmpty)
        XCTAssertEqual(root.count, 4)
        XCTAssertEqual(Set(root.map(\.discoveryGeneration)), [1])
        XCTAssertEqual(Set(workingSet.map(\.itemIdentifier)), Set(root.map(\.itemIdentifier)))
    }

    /// 已发布照片遇到瞬时读取失败时必须返回错误让系统重试，不能把有效根快照覆盖成空目录。
    func testTransientRootFailurePreservesPreviouslyPublishedSnapshot() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let initialRepository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderStaticDiscoveryFeed(
                records: [Self.record(id: "retained", source: .openverse)]
            )
        )
        _ = try await ProviderCatalog(repository: initialRepository)
            .preparedItems(for: .root)
        let before = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.root.storageKey
        )

        let failingRepository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderFailingDiscoveryFeed()
        )
        await XCTAssertThrowsErrorAsync(
            try await ProviderCatalog(repository: failingRepository)
                .preparedItems(for: .root)
        )

        let after = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.root.storageKey
        )
        XCTAssertEqual(after, before)
        XCTAssertEqual(after?.filter { $0.identifier.hasPrefix("discover:") }.count, 1)
    }

    /// 系统可能先提交 working set；即使 root 尚未包含照片，瞬时失败也不能回退为空根目录。
    func testTransientRootFailurePreservesWorkingSetOnlyPublication() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        _ = try await storage.commitProviderScope(
            ProviderEnumerationScope.workingSet.storageKey,
            items: [
                ProviderStoredItemState(
                    identifier: "discover:retained-working-set",
                    fingerprint: "v1"
                ),
            ]
        )

        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderFailingDiscoveryFeed()
        )
        await XCTAssertThrowsErrorAsync(
            try await ProviderCatalog(repository: repository)
                .preparedItems(for: .root)
        )
        let rootSnapshot = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.root.storageKey
        )
        XCTAssertNil(rootSnapshot)
        let workingSetSnapshot = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.workingSet.storageKey
        )
        XCTAssertEqual(
            workingSetSnapshot?.map(\.identifier),
            ["discover:retained-working-set"]
        )
    }

    /// “头像”首页生成 40 个稳定 occurrence，并在末尾发布唯一“加载更多”目录。
    func testAvatarFolderPublishesFirstFortyAndLoadMoreWithoutOpenverse() async throws {
        let context = try makeContext()

        let first = try await context.catalog.preparedItems(for: .avatars)
        let images = Self.images(in: first)
        let directories = first.filter { $0.contentType == .folder }
        XCTAssertEqual(first.count, 41)
        XCTAssertEqual(images.count, 40)
        XCTAssertEqual(Set(images.map(\.itemIdentifier)).count, 40)
        XCTAssertTrue(images.allSatisfy {
            $0.parentItemIdentifier == ProviderIdentifiers.avatars
                && $0.itemIdentifier.rawValue.hasPrefix("avatar:db:v13:")
        })
        let continuation = try XCTUnwrap(directories.only)
        XCTAssertEqual(continuation.filename, "加载更多")
        XCTAssertEqual(continuation.itemIdentifier.rawValue, "avatar-page:v2:2")
        XCTAssertEqual(continuation.parentItemIdentifier, ProviderIdentifiers.avatars)
        XCTAssertEqual(first.last?.itemIdentifier, continuation.itemIdentifier)
        let initialOpenverseRequests = await context.openverse.requestedPages()
        XCTAssertEqual(initialOpenverseRequests, [])
        let diceBearRequests = await context.diceBear.requests()
        XCTAssertEqual(
            diceBearRequests,
            [
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 0, count: 20),
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 20, count: 20)
            ]
        )
        let generationDays = await context.diceBear.generationDays()
        XCTAssertEqual(Set(generationDays.map(\.identifier)), [Self.avatarSeedDay1.identifier])

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

    /// 生产头像目录在 Finder 中必须同时接受三家来源，并能按统一生成日恢复持久缓存。
    func testAvatarFolderPublishesAndRestoresAllProductionProviders() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        // 这里验证确定性供应商混排；动态人像源在独立测试中使用临时存储。
        let avatars = Self.deterministicAvatarCatalog(now: { Self.avatarSeedDate1 })
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderEmptyDiscoveryFeed(),
            diceBear: avatars
        )
        let catalog = ProviderCatalog(repository: repository)

        let first = try await catalog.preparedItems(for: .avatars)
        let imageItems = Self.images(in: first)
        var sources = Set<ImageSource>()
        for item in imageItems {
            let occurrence = try await repository.occurrence(for: item.itemIdentifier)
            if let source = occurrence?.record.source { sources.insert(source) }
        }

        XCTAssertEqual(imageItems.count, 40)
        XCTAssertEqual(sources, [.diceBear, .gravatar, .robohash])
        XCTAssertTrue(imageItems.allSatisfy { $0.itemIdentifier.rawValue.hasPrefix("avatar:") })

        let restoredRepository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderEmptyDiscoveryFeed(),
            diceBear: Self.deterministicAvatarCatalog(now: { Self.avatarSeedDate1Later })
        )
        let restored = try await ProviderCatalog(repository: restoredRepository)
            .preparedItems(for: .avatars)
        XCTAssertEqual(first.map(\.itemIdentifier), restored.map(\.itemIdentifier))
    }

    /// Finder 在支持的类型间切换时必须从生成源头筛选，并让旧 occurrence 同步失效。
    func testAvatarFolderTracksSharedTypeSelectionAndInvalidatesCachedScope() async throws {
        let suiteName = "MirageProviderPageTests.Filters.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let filters = DiscoveryFilterPreferencesStore(userDefaults: defaults)
        filters.setAvatarTypes([.cartoonCharacter])

        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let avatars = Self.deterministicAvatarCatalog(now: { Self.avatarSeedDate1 })
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderEmptyDiscoveryFeed(),
            diceBear: avatars,
            filterPreferences: filters
        )
        let catalog = ProviderCatalog(repository: repository)

        let first = try await catalog.preparedItems(for: .avatars)
        let oldIdentifier = try XCTUnwrap(Self.images(in: first).first?.itemIdentifier)
        XCTAssertEqual(Self.images(in: first).count, 40)
        for item in Self.images(in: first) {
            let occurrence = try await repository.occurrence(for: item.itemIdentifier)
            XCTAssertEqual(occurrence?.record.avatarType, .cartoonCharacter)
        }

        filters.setAvatarTypes([.monster])
        let filtered = try await catalog.preparedItems(for: .avatars)
        let removedOccurrence = try await repository.occurrence(for: oldIdentifier)

        XCTAssertEqual(Self.images(in: filtered).count, 40)
        XCTAssertEqual(filtered.last?.filename, "加载更多")
        for item in Self.images(in: filtered) {
            let occurrence = try await repository.occurrence(for: item.itemIdentifier)
            XCTAssertEqual(occurrence?.record.avatarType, .monster)
        }
        XCTAssertNil(removedOccurrence)
    }

    /// Finder 必须按共享筛选发布二次元与 AI 肖像，且枚举出的 Picrew 条目能够被 occurrence 回查。
    func testFinderPublishesSelectedAnimeAndAIAvatarTypesAcrossPages() async throws {
        let suiteName = "MirageProviderPageTests.AnimeAndAIFilters.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let filters = DiscoveryFilterPreferencesStore(userDefaults: defaults)
        filters.setAvatarTypes([.anime, .aiRealistic])
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderEmptyDiscoveryFeed(),
            diceBear: Self.filteredAvatarCatalog(now: { Self.avatarSeedDate1 }),
            filterPreferences: filters
        )
        let catalog = ProviderCatalog(repository: repository)
        let secondPage = try XCTUnwrap(AvatarPageReference(page: 2))

        let items = try await catalog.preparedItems(for: .avatars)
        let images = Self.images(in: items)
        let moreItems = try await catalog.preparedItems(for: .avatarPage(secondPage))
        let moreImages = Self.images(in: moreItems)
        var resolvedRecords: [RemoteImageRecord] = []

        XCTAssertEqual(images.count, 40)
        XCTAssertEqual(items.last?.filename, "加载更多")
        XCTAssertEqual(moreImages.count, 40)
        XCTAssertEqual(moreItems.last?.filename, "加载更多")
        for item in images + moreImages {
            let resolved = try await repository.occurrence(for: item.itemIdentifier)
            resolvedRecords.append(try XCTUnwrap(resolved).record)
        }
        XCTAssertEqual(Set(resolvedRecords.compactMap(\.avatarType)), [.anime, .aiRealistic])
        XCTAssertEqual(Set(resolvedRecords.map(\.source)), [.picrew, .diceBear])
    }

    /// AI 动态来源按低频配额返回不足 40 条时，Finder 仍发布已有图片和下一页入口。
    func testAIRealisticOnlyPublishesAvailablePartialAvatarBatch() async throws {
        let suiteName = "MirageProviderPageTests.AIOnlyFilter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let filters = DiscoveryFilterPreferencesStore(userDefaults: defaults)
        filters.setAvatarTypes([.aiRealistic])
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderEmptyDiscoveryFeed(),
            diceBear: Self.filteredAvatarCatalog(now: { Self.avatarSeedDate1 }),
            filterPreferences: filters
        )
        let catalog = ProviderCatalog(repository: repository)

        let items = try await catalog.preparedItems(for: .avatars)
        let images = Self.images(in: items)

        XCTAssertEqual(images.count, 10)
        XCTAssertEqual(items.last?.filename, "加载更多")
        for item in images {
            let resolved = try await repository.occurrence(for: item.itemIdentifier)
            XCTAssertEqual(resolved?.record.avatarType, .aiRealistic)
        }
    }

    /// working set 刷新必须重建已发布头像 scope，系统才能把筛选差异投影到 Finder 目录。
    func testWorkingSetRebuildsPublishedAvatarScopeAfterFilterChange() async throws {
        let suiteName = "MirageProviderPageTests.WorkingSetAvatarFilter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let filters = DiscoveryFilterPreferencesStore(userDefaults: defaults)
        filters.setAvatarTypes([.anime, .aiRealistic])
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderEmptyDiscoveryFeed(),
            diceBear: Self.filteredAvatarCatalog(now: { Self.avatarSeedDate1 }),
            filterPreferences: filters
        )
        let catalog = ProviderCatalog(repository: repository)

        let initial = try await catalog.preparedItems(for: .avatars)
        var removedIdentifier: NSFileProviderItemIdentifier?
        for item in Self.images(in: initial) {
            let occurrence = try await repository.occurrence(for: item.itemIdentifier)
            if occurrence?.record.avatarType == .aiRealistic {
                removedIdentifier = item.itemIdentifier
                break
            }
        }
        let oldAIIdentifier = try XCTUnwrap(removedIdentifier)
        let anchorBeforeFilterChange = try await repository.currentAnchor()

        filters.setAvatarTypes([.anime])
        let workingSet = try await catalog.preparedItems(for: .workingSet)
        let avatarImages = workingSet.filter {
            $0.parentItemIdentifier == ProviderIdentifiers.avatars && $0.contentType == .png
        }
        let storedAvatarIdentifiers = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.avatars.storageKey
        )?.map(\.identifier)

        XCTAssertEqual(avatarImages.count, 40)
        XCTAssertEqual(Set(storedAvatarIdentifiers ?? []), Set(
            workingSet
                .filter { $0.parentItemIdentifier == ProviderIdentifiers.avatars }
                .map { $0.itemIdentifier.rawValue }
        ))
        for item in avatarImages {
            let occurrence = try await repository.occurrence(for: item.itemIdentifier)
            XCTAssertEqual(occurrence?.record.avatarType, .anime)
        }
        let removedOccurrence = try await repository.occurrence(for: oldAIIdentifier)
        let workingSetChanges = try await repository.changes(
            in: ProviderEnumerationScope.workingSet.storageKey,
            after: anchorBeforeFilterChange
        )
        XCTAssertNil(removedOccurrence)
        XCTAssertTrue(workingSetChanges.deletedIdentifiers.contains(oldAIIdentifier.rawValue))
    }

    /// 打开头像第 2 层只生成 offsets 40...79，并发布指向第 3 层的稳定入口。
    func testOpeningSecondAvatarPageLoadsNextFortyAndPublishesThirdPage() async throws {
        let context = try makeContext()
        let first = try await context.catalog.preparedItems(for: .avatars)
        let firstImages = Self.images(in: first)
        let second = try XCTUnwrap(AvatarPageReference(page: 2))
        let third = try XCTUnwrap(AvatarPageReference(page: 3))

        let lookedUpSecond = try await context.catalog.item(for: second.itemIdentifier)
        XCTAssertEqual(lookedUpSecond?.filename, "加载更多")
        XCTAssertEqual(lookedUpSecond?.parentItemIdentifier, ProviderIdentifiers.avatars)
        var requests = await context.diceBear.requests()
        XCTAssertEqual(requests.count, 2)

        let unpublishedThird = try await context.catalog.item(for: third.itemIdentifier)
        XCTAssertNil(unpublishedThird)
        await XCTAssertThrowsErrorAsync(
            try await context.repository.avatarItems(for: third)
        ) { error in
            let providerError = error as NSError
            XCTAssertEqual(providerError.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(providerError.code, NSFileProviderError.Code.noSuchItem.rawValue)
        }
        requests = await context.diceBear.requests()
        XCTAssertEqual(requests.count, 2)

        let page = try await context.catalog.preparedItems(for: .avatarPage(second))
        let images = Self.images(in: page)
        XCTAssertEqual(page.count, 41)
        XCTAssertEqual(images.count, 40)
        XCTAssertEqual(Set(images.map(\.itemIdentifier)).count, 40)
        XCTAssertTrue(Set(images.map(\.itemIdentifier)).isDisjoint(
            with: Set(firstImages.map(\.itemIdentifier))
        ))
        XCTAssertTrue(images.allSatisfy {
            $0.parentItemIdentifier == second.itemIdentifier
                && $0.itemIdentifier.rawValue.hasPrefix("avatar-page-item:v2:2:db:v13:")
        })
        let continuation = try XCTUnwrap(page.last)
        XCTAssertEqual(continuation.filename, "加载更多")
        XCTAssertEqual(continuation.itemIdentifier, third.itemIdentifier)
        XCTAssertEqual(continuation.parentItemIdentifier, second.itemIdentifier)
        XCTAssertEqual(page.filter { $0.contentType == .folder }.count, 1)

        requests = await context.diceBear.requests()
        XCTAssertEqual(
            requests,
            [
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 0, count: 20),
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 20, count: 20),
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 40, count: 20),
                ProviderDiceBearRequest(query: DiscoveryRecommendation.query, offset: 60, count: 20)
            ]
        )
        let openverseRequests = await context.openverse.requestedPages()
        XCTAssertEqual(openverseRequests, [])

        let repeated = try await context.catalog.preparedItems(for: .avatarPage(second))
        XCTAssertEqual(page.map(\.itemIdentifier), repeated.map(\.itemIdentifier))
        let repeatedRequests = await context.diceBear.requests()
        XCTAssertEqual(repeatedRequests, requests)

        let restoredRepository = ProviderRepository(
            manager: nil,
            storage: context.storage,
            discoveryFeed: context.discoveryFeed,
            diceBear: context.diceBear
        )
        let firstPageIdentifier = try XCTUnwrap(images.first?.itemIdentifier)
        let restored = try await restoredRepository.occurrence(for: firstPageIdentifier)
        XCTAssertEqual(restored?.reference.avatarPage, second)
        XCTAssertEqual(restored?.record.source, .diceBear)

        let forged = ProviderIdentifiers.avatarPageItemIdentifier(
            recordID: "db:v10:forged",
            page: second
        )
        let forgedOccurrence = try await restoredRepository.occurrence(for: forged)
        XCTAssertNil(forgedOccurrence)
    }

    /// 后台索引即使主动枚举每个入口，也只能得到 5 批头像，working set 和状态文件保持有界。
    func testAvatarTreeStopsAtFifthPageAndKeepsWorkingSetBounded() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .avatars)
        var lastPageItems: [ProviderItem] = []
        for page in 2...AvatarPageReference.maximumPage {
            let reference = try XCTUnwrap(AvatarPageReference(page: page))
            lastPageItems = try await context.catalog.preparedItems(for: .avatarPage(reference))
        }

        let workingSet = try await context.catalog.preparedItems(for: .workingSet)
        let avatarImages = workingSet.filter { item in
            ProviderIdentifiers.recordReference(from: item.itemIdentifier)?.view == .avatar
        }
        let providerStateURL = temporaryURL.appendingPathComponent("provider-sync-state.json")
        let providerStateBytes = try providerStateURL.resourceValues(forKeys: [.fileSizeKey])
            .fileSize

        XCTAssertEqual(AvatarPageReference.maximumPage, 5)
        XCTAssertEqual(Self.images(in: lastPageItems).count, 40)
        XCTAssertTrue(lastPageItems.allSatisfy { $0.contentType != .folder })
        XCTAssertNil(AvatarPageReference(page: AvatarPageReference.maximumPage + 1))
        XCTAssertEqual(avatarImages.count, 200)
        XCTAssertLessThan(try XCTUnwrap(providerStateBytes), 1_000_000)
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
        XCTAssertEqual(regeneratedRequests.count, 4)

        let cachedAgain = try await context.catalog.preparedItems(for: .avatars)
        XCTAssertEqual(regenerated.map(\.itemIdentifier), cachedAgain.map(\.itemIdentifier))
        let cachedRequests = await context.diceBear.requests()
        XCTAssertEqual(cachedRequests.count, 4)
    }

    /// 同一天跨进程继续命中缓存；进入下一 UTC 日期后必须替换整批头像而非复用昨日记录。
    func testAvatarFolderRotatesPersistedSnapshotAcrossUTCDateBoundary() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let firstContext = try makeContext(storage: storage, now: { Self.avatarSeedDate1 })
        let first = try await firstContext.catalog.preparedItems(for: .avatars)
        let firstIDs = Set(Self.images(in: first).map(\.itemIdentifier))
        XCTAssertEqual(firstIDs.count, 40)

        let restoredSameDay = try makeContext(storage: storage, now: { Self.avatarSeedDate1Later })
        let repeated = try await restoredSameDay.catalog.preparedItems(for: .avatars)
        XCTAssertEqual(Set(Self.images(in: repeated).map(\.itemIdentifier)), firstIDs)
        let sameDayRequests = await restoredSameDay.diceBear.requests()
        XCTAssertEqual(sameDayRequests, [])

        let nextDay = try makeContext(storage: storage, now: { Self.avatarSeedDate2 })
        let rotated = try await nextDay.catalog.preparedItems(for: .avatars)
        let rotatedIDs = Set(Self.images(in: rotated).map(\.itemIdentifier))
        XCTAssertEqual(rotatedIDs.count, 40)
        XCTAssertTrue(firstIDs.isDisjoint(with: rotatedIDs))
        let nextDayRequests = await nextDay.diceBear.requests()
        XCTAssertEqual(nextDayRequests.count, 2)
        let nextDayGenerationDays = await nextDay.diceBear.generationDays()
        XCTAssertEqual(Set(nextDayGenerationDays.map(\.identifier)), [Self.avatarSeedDay2.identifier])
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
        XCTAssertEqual(Self.images(in: child).count, 40)
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

    /// 打开“更多图片”才加载下一固定 40 张，并只在该子目录发布下一层入口。
    func testOpeningSecondPageLoadsNextFortyAndPublishesThirdPage() async throws {
        let context = try makeContext()
        let root = try await context.catalog.preparedItems(for: .root)
        let page = try XCTUnwrap(DiscoveryPageReference(page: 2))

        let child = try await context.catalog.preparedItems(for: .discoveryPage(page))
        let images = Self.images(in: child)
        let continuation = try XCTUnwrap(Self.discoveryDirectories(in: child).only)

        XCTAssertEqual(images.count, 40)
        XCTAssertTrue(images.allSatisfy { $0.parentItemIdentifier == page.itemIdentifier })
        XCTAssertEqual(images.first?.itemIdentifier.rawValue, "discover-page-item:v3:2:provider:3:0")
        XCTAssertTrue(images.last?.itemIdentifier.rawValue.contains(":db:v13:") == true)
        XCTAssertEqual(continuation.itemIdentifier.rawValue, "discover-page:v3:3")
        XCTAssertEqual(continuation.parentItemIdentifier, page.itemIdentifier)
        XCTAssertEqual(continuation.filename, "更多图片")
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2, 3, 4])

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

    /// 第 2 层发布第 3 层后，递归打开继续得到独立的 40 张固定快照。
    func testOpeningThirdPageContinuesRecursively() async throws {
        let context = try makeContext()
        _ = try await context.catalog.preparedItems(for: .root)
        let second = try XCTUnwrap(DiscoveryPageReference(page: 2))
        _ = try await context.catalog.preparedItems(for: .discoveryPage(second))
        let third = try XCTUnwrap(DiscoveryPageReference(page: 3))

        let items = try await context.catalog.preparedItems(for: .discoveryPage(third))
        let images = Self.images(in: items)
        let continuation = try XCTUnwrap(Self.discoveryDirectories(in: items).only)

        XCTAssertEqual(images.count, 40)
        XCTAssertTrue(images.allSatisfy { $0.parentItemIdentifier == third.itemIdentifier })
        XCTAssertEqual(images.first?.itemIdentifier.rawValue, "discover-page-item:v3:3:provider:5:0")
        XCTAssertTrue(images.last?.itemIdentifier.rawValue.contains(":db:v13:") == true)
        XCTAssertEqual(continuation.itemIdentifier.rawValue, "discover-page:v3:4")
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, Array(1...6))
    }

    /// 第 4 批之后仍可打开第 5 批，但必须在产品上限停止递归目录。
    func testOpeningFourthPagePublishesFifthPageAndStopsAtBound() async throws {
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
        XCTAssertEqual(fifthImages.count, 40)
        XCTAssertEqual(
            fifthImages.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:5:provider:9:0"
        )
        XCTAssertTrue(fifthImages.last?.itemIdentifier.rawValue.contains(":db:v13:") == true)
        XCTAssertTrue(Self.discoveryDirectories(in: fifthItems).isEmpty)
        XCTAssertNil(DiscoveryPageReference(page: 6))
        let maximumOpenedPage = try await context.storage.maximumOpenedProviderDiscoveryPage()
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(maximumOpenedPage, 5)
        XCTAssertEqual(requestedPages, Array(1...10))
    }

    /// 残缺旧状态恢复后必须能从当前根重新建立 lineage，并在第 5 批停止。
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
        let maximumOpenedPage = try await context.storage.maximumOpenedProviderDiscoveryPage()

        XCTAssertEqual(fifthDirectory?.itemIdentifier, fifth.itemIdentifier)
        XCTAssertEqual(Self.images(in: fifthItems).count, 40)
        XCTAssertTrue(Self.discoveryDirectories(in: fifthItems).isEmpty)
        XCTAssertNil(DiscoveryPageReference(page: 6))
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
        XCTAssertEqual(images.count, 40)
        XCTAssertTrue(images.allSatisfy { $0.discoveryGeneration == publishedGeneration })
        XCTAssertEqual(images.first?.itemIdentifier.rawValue, "discover-page-item:v3:2:provider:3:0")
        XCTAssertTrue(images.last?.itemIdentifier.rawValue.contains(":db:v13:") == true)
        XCTAssertFalse(images.contains { $0.itemIdentifier.rawValue.contains("refreshed") })
        let requestedPages = await context.openverse.requestedPages()
        XCTAssertEqual(requestedPages, [1, 2, 3, 4])
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
        XCTAssertEqual(rebuiltChildren.count, 40)
        XCTAssertTrue(rebuiltChildren.allSatisfy {
            $0.discoveryGeneration == refreshedGeneration
        })
        XCTAssertEqual(
            rebuiltChildren.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:2:refreshed:40"
        )
        XCTAssertEqual(
            rebuiltChildren.last?.itemIdentifier.rawValue,
            "discover-page-item:v3:2:refreshed:79"
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
        XCTAssertEqual(requestsBeforeRefresh, Array(1...6))
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
        XCTAssertEqual(rebuiltSecond.count, 40)
        XCTAssertEqual(rebuiltThird.count, 40)
        XCTAssertTrue((rebuiltSecond + rebuiltThird).allSatisfy {
            $0.discoveryGeneration == refreshedGeneration
        })
        XCTAssertEqual(
            rebuiltSecond.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:2:refreshed:3:0"
        )
        XCTAssertTrue(rebuiltSecond.last?.itemIdentifier.rawValue.contains(":db:v13:") == true)
        XCTAssertEqual(
            rebuiltThird.first?.itemIdentifier.rawValue,
            "discover-page-item:v3:3:refreshed:5:0"
        )
        XCTAssertTrue(rebuiltThird.last?.itemIdentifier.rawValue.contains(":db:v13:") == true)
        // 自动推荐每页固定补入 4 个稳定头像；换代后远端照片必须替换，头像 ID 则允许复用。
        let oldRemoteChildIDs = Set(oldChildIDs.filter { !$0.rawValue.contains(":db:") })
        let refreshedRemoteChildIDs = Set(refreshedWorkingSet
            .map(\.itemIdentifier)
            .filter { !$0.rawValue.contains(":db:") })
        XCTAssertTrue(oldRemoteChildIDs.isDisjoint(with: refreshedRemoteChildIDs))

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
        XCTAssertEqual(persistedSecond.count, 41)
        XCTAssertEqual(persistedThird.count, 41)
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
            Array(2...6)
        )
    }

    /// 同步锚点只读取持久边界，不得联网、创建 scope 或推进 generation。
    func testCurrentAnchorIsPureRead() async throws {
        let storage = try AppGroupStorage(baseURL: temporaryURL)
        let repository = ProviderRepository(
            manager: nil,
            storage: storage,
            discoveryFeed: ProviderFailingDiscoveryFeed()
        )
        let catalog = ProviderCatalog(repository: repository)
        let before = try await storage.currentProviderAnchor()

        let anchor = try await catalog.currentAnchor()
        let after = try await storage.currentProviderAnchor()
        let workingSet = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.workingSet.storageKey
        )
        let root = try await storage.providerScopeSnapshot(
            ProviderEnumerationScope.root.storageKey
        )

        XCTAssertEqual(anchor, before)
        XCTAssertEqual(after, before)
        XCTAssertNil(workingSet)
        XCTAssertNil(root)
    }

    /// Repository 必须把域重建后迟到的 root/working-set 发布统一映射为 File Provider 页过期。
    func testRepositoryMapsStalePublicationEpochToPageExpired() async throws {
        let context = try makeContext()
        let staleEpoch = try await context.repository.currentPublicationEpoch()
        let rootItems = try await context.catalog.items(for: .root)
        let rootGeneration = try XCTUnwrap(rootItems.compactMap(\.discoveryGeneration).first)
        _ = try await context.storage.resetProviderPublicationState()

        await XCTAssertThrowsErrorAsync(
            try await context.repository.commitScope(
                .root,
                items: rootItems,
                expectedPublicationEpoch: staleEpoch
            )
        ) { error in
            let providerError = error as NSError
            XCTAssertEqual(providerError.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(providerError.code, NSFileProviderError.Code.pageExpired.rawValue)
        }
        await XCTAssertThrowsErrorAsync(
            try await context.repository.commitWorkingSet(
                items: rootItems,
                recursiveScopes: [],
                rootGeneration: rootGeneration,
                expectedPublicationEpoch: staleEpoch
            )
        ) { error in
            let providerError = error as NSError
            XCTAssertEqual(providerError.domain, NSFileProviderErrorDomain)
            XCTAssertEqual(providerError.code, NSFileProviderError.Code.pageExpired.rawValue)
        }
        let rejectedRoot = try await context.storage.providerScopeSnapshot(
            ProviderEnumerationScope.root.storageKey
        )
        let rejectedWorkingSet = try await context.storage.providerScopeSnapshot(
            ProviderEnumerationScope.workingSet.storageKey
        )
        XCTAssertNil(rejectedRoot)
        XCTAssertNil(rejectedWorkingSet)

        let currentEpoch = try await context.repository.currentPublicationEpoch()
        _ = try await context.repository.commitScope(
            .root,
            items: rootItems,
            expectedPublicationEpoch: currentEpoch
        )
        _ = try await context.repository.commitWorkingSet(
            items: rootItems,
            recursiveScopes: [],
            rootGeneration: rootGeneration,
            expectedPublicationEpoch: currentEpoch
        )
        let committedRoot = try await context.storage.providerScopeSnapshot(
            ProviderEnumerationScope.root.storageKey
        )
        let committedWorkingSet = try await context.storage.providerScopeSnapshot(
            ProviderEnumerationScope.workingSet.storageKey
        )
        XCTAssertNotNil(committedRoot)
        XCTAssertNotNil(committedWorkingSet)
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
        let publicationEpoch = try await context.repository.currentPublicationEpoch()

        await XCTAssertThrowsErrorAsync(
            try await context.repository.commitScope(
                .discoveryPage(second),
                items: staleItems,
                expectedPublicationEpoch: publicationEpoch
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

    /// 远端在第二个 40 张窗口中结束时，只发布实际剩余图片且不制造空 continuation。
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
        XCTAssertEqual(Self.images(in: child).count, 33)
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

    /// 旧完整快照仍按底层 20 张边界迁移；Provider 的 40 张只是无损聚合层。
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

    private func makeContext(
        storage injectedStorage: AppGroupStorage? = nil,
        now: @escaping @Sendable () -> Date = {
            ProviderRepositoryPageSnapshotTests.avatarSeedDate1
        }
    ) throws -> ProviderTestContext {
        let storage: AppGroupStorage
        if let injectedStorage {
            storage = injectedStorage
        } else {
            storage = try AppGroupStorage(baseURL: temporaryURL)
        }
        let openverse = ProviderPagedOpenverse()
        let diceBear = ProviderRecordingDiceBear(now: now)
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

    private static let avatarSeedDate1 = Date(timeIntervalSince1970: 1_754_092_801)
    private static let avatarSeedDate1Later = Date(timeIntervalSince1970: 1_754_179_199)
    private static let avatarSeedDate2 = Date(timeIntervalSince1970: 1_754_179_200)
    private static let avatarSeedDay1 = DiceBearGenerationDay(date: avatarSeedDate1)
    private static let avatarSeedDay2 = DiceBearGenerationDay(date: avatarSeedDate2)

    private static func deterministicAvatarCatalog(
        now: @escaping @Sendable () -> Date
    ) -> AvatarCatalogClient {
        AvatarCatalogClient(
            providers: [
                DiceBearClient(now: now),
                GravatarClient(now: now),
                RobohashClient(now: now),
            ],
            now: now
        )
    }

    private static func filteredAvatarCatalog(
        now: @escaping @Sendable () -> Date
    ) -> AvatarCatalogClient {
        AvatarCatalogClient(
            providers: [
                ProviderAvatarTypeGenerator(type: .anime, source: .picrew),
                ProviderAvatarTypeGenerator(
                    type: .aiRealistic,
                    source: .diceBear,
                    eligibilityDivisor: 4
                ),
            ],
            now: now
        )
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

    private static func record(id: String, source: ImageSource) -> RemoteImageRecord {
        let url = URL(string: "https://example.com/\(id).png")!
        return RemoteImageRecord(
            id: id,
            title: id.capitalized,
            source: source,
            imageURL: url,
            thumbnailURL: url,
            license: source == .giphy ? .giphy : .cc0,
            mimeType: source == .giphy ? "image/gif" : "image/png"
        )
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

private struct ProviderEmptyDiscoveryFeed: DiscoveryFeedProviding {
    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        DiscoveryFeedPage(
            generation: generation ?? 1,
            records: [],
            nextPage: nil,
            didMutateSnapshot: false
        )
    }
}

private enum ProviderDiscoveryFeedFixtureError: Error {
    case unavailable
}

private struct ProviderFailingDiscoveryFeed: DiscoveryFeedProviding {
    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        throw ProviderDiscoveryFeedFixtureError.unavailable
    }
}

private struct ProviderStaticDiscoveryFeed: DiscoveryFeedProviding {
    let records: [RemoteImageRecord]

    func page(generation: UInt64?, page: Int, pageSize: Int) async throws -> DiscoveryFeedPage {
        DiscoveryFeedPage(
            generation: generation ?? 1,
            records: page == 1 ? Array(records.prefix(pageSize)) : [],
            nextPage: nil,
            didMutateSnapshot: false
        )
    }
}

private struct ProviderAvatarTypeGenerator: AvatarSourceGenerating {
    let type: AvatarType
    let source: ImageSource
    let eligibilityDivisor: UInt64

    init(
        type: AvatarType,
        source: ImageSource,
        eligibilityDivisor: UInt64 = 1
    ) {
        self.type = type
        self.source = source
        self.eligibilityDivisor = eligibilityDivisor
    }

    var avatarCatalogIdentifier: String { "provider-fixture-\(type.rawValue)" }
    var avatarCatalogEligibilityDivisor: UInt64 { eligibilityDivisor }
    var supportedAvatarTypes: Set<AvatarType> { [type] }

    func avatar(
        seedMaterial: String,
        generationDay: AvatarGenerationDay
    ) async -> RemoteImageRecord? {
        guard let index = AvatarSeed.absoluteIndex(from: seedMaterial) else { return nil }
        let id: String
        let url: URL
        let license: LicenseInfo
        if source == .picrew {
            let path = "shareImg/thumb/202608/provider-\(index).png"
            id = StableImageID.picrewDiscovery(
                makerID: String(2_000_000 + index),
                thumbnailPath: path
            )
            guard let value = URL(string: "https://cdn.picrew.me/\(path)") else { return nil }
            url = value
            license = .picrewUsage
        } else {
            id = StableImageID.dailyDiceBear(
                style: "provider-fixture",
                generationDay: generationDay,
                seedMaterial: seedMaterial
            )
            guard let value = URL(string: "https://example.com/avatar/\(index).png") else {
                return nil
            }
            url = value
            license = .cc0
        }
        return RemoteImageRecord(
            id: id,
            title: type.displayName,
            source: source,
            avatarType: type,
            imageURL: url,
            thumbnailURL: url,
            license: license,
            mimeType: "image/png"
        )
    }
}

private actor ProviderRecordingDiceBear: DiceBearProviding {
    private let client: DiceBearClient
    private var recordedRequests: [ProviderDiceBearRequest] = []
    private var recordedGenerationDays: [DiceBearGenerationDay] = []

    init(now: @escaping @Sendable () -> Date) {
        client = DiceBearClient(styles: [.pixelArt], now: now)
    }

    func currentGenerationDay() async -> DiceBearGenerationDay {
        await client.currentGenerationDay()
    }

    func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: DiceBearGenerationDay
    ) async -> [RemoteImageRecord] {
        recordedRequests.append(
            ProviderDiceBearRequest(query: query, offset: offset, count: count)
        )
        recordedGenerationDays.append(generationDay)
        return await client.avatars(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay
        )
    }

    func requests() -> [ProviderDiceBearRequest] { recordedRequests }
    func generationDays() -> [DiceBearGenerationDay] { recordedGenerationDays }
}

private actor ProviderPagedOpenverse: OpenverseSearching {
    private var pages: [Int] = []
    private var recordPrefix = "provider"

    func search(query: String, page: Int, pageSize: Int) async throws -> ImageSearchPage {
        pages.append(page)
        return ImageSearchPage(
            records: Array(
                ProviderRepositoryPageSnapshotTests.records(prefix: recordPrefix, page: page)
                    .prefix(pageSize)
            ),
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
