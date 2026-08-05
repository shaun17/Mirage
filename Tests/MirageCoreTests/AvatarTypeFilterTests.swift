import Foundation
import MirageCore
import XCTest

@MainActor
final class AvatarTypeFilterTests: XCTestCase {
    func testAppSelectionAdaptersPersistOneSharedFinderSnapshot() {
        let suiteName = "MirageCoreTests.DiscoveryFilterPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let shared = DiscoveryFilterPreferencesStore(userDefaults: defaults)
        let avatarStore = AvatarTypeSelectionStore(defaults: defaults)
        let giphyStore = GiphyContentTypeSelectionStore(defaults: defaults)
        let photoStore = PhotoSourceFilterSelectionStore(defaults: defaults)

        avatarStore.save(AvatarTypeSelection(types: [.animal, .monster]))
        giphyStore.save(GiphyContentTypeSelection(types: [.gif]))
        photoStore.save(.source(.pexels))

        let snapshot = shared.snapshot()
        XCTAssertEqual(snapshot.avatarTypes, [.animal, .monster])
        XCTAssertEqual(snapshot.giphyContentTypes, [.gif])
        XCTAssertEqual(snapshot.photoSourceID, .pexels)
        XCTAssertEqual(avatarStore.load().types, snapshot.avatarTypes)
        XCTAssertEqual(giphyStore.load().types, snapshot.giphyContentTypes)
        XCTAssertEqual(photoStore.load(), .source(.pexels))
        XCTAssertGreaterThan(snapshot.revision, 1)
    }

    func testSelectionDefaultsToAllTypesAndPersistsSubset() {
        let suiteName = "MirageCoreTests.AvatarTypeSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AvatarTypeSelectionStore(defaults: defaults)

        XCTAssertEqual(store.load(), .all)

        let subset = AvatarTypeSelection(types: [.anime, .monster, .animal])
        store.save(subset)

        XCTAssertEqual(store.load(), subset)
        XCTAssertEqual(store.load().persistedValues, ["anime", "monster", "animal"])
    }

    func testSelectionNeverRemovesItsLastType() {
        let animeOnly = AvatarTypeSelection(types: [.anime])

        XCTAssertEqual(animeOnly.toggling(.anime), animeOnly)
        XCTAssertEqual(
            AvatarTypeSelection(types: []).types,
            Set(AvatarType.allCases)
        )
    }

    func testLegacyAvatarWithoutTypeRemainsVisibleForDefaultSelection() throws {
        let data = Data(#"""
        {
          "id": "legacy-avatar",
          "title": "Legacy avatar",
          "source": "dice_bear",
          "imageURL": "https://example.com/legacy.png",
          "thumbnailURL": "https://example.com/legacy.png",
          "license": { "identifier": "cc0", "displayName": "CC0 1.0" }
        }
        """#.utf8)

        let record = try JSONDecoder().decode(RemoteImageRecord.self, from: data)

        XCTAssertNil(record.avatarType)
        XCTAssertTrue(record.matchesAvatarTypes(Set(AvatarType.allCases)))
        XCTAssertFalse(record.matchesAvatarTypes([.anime]))
    }

    func testSearchModelFiltersByAvatarTypeAndKeepsSelectionAcrossTabs() async {
        let selected = AvatarTypeSelection(types: [.anime, .monster])
        var persistedSelections: [AvatarTypeSelection] = []
        let model = SearchModel(
            service: ImageSearchService(diceBear: AvatarTypeFixtureProvider()),
            initialAvatarTypeSelection: selected,
            avatarTypeSelectionDidChange: { persistedSelections.append($0) }
        )

        model.setActive(true)
        let loadedSelectedTypes = await waitUntil {
            Set(model.results.compactMap(\.avatarType)) == [.anime, .monster]
        }
        XCTAssertTrue(loadedSelectedTypes)

        model.filter = .photos
        model.filter = .avatars
        XCTAssertEqual(model.avatarTypeSelection, selected)

        model.toggleAvatarType(.anime)
        let loadedMonsterOnly = await waitUntil {
            model.results.map(\.avatarType) == [.monster]
        }
        XCTAssertTrue(loadedMonsterOnly)
        XCTAssertEqual(model.avatarTypeSelection.types, [.monster])
        XCTAssertEqual(persistedSelections.map(\.types), [[.monster]])

        model.toggleAvatarType(.monster)
        XCTAssertEqual(model.avatarTypeSelection.types, [.monster])
        XCTAssertEqual(persistedSelections.map(\.types), [[.monster]])
        XCTAssertEqual(model.accessibilityEvent?.message, "至少保留一种头像类型")
    }

    /// 二次元和 AI 真人筛选必须传到生成服务，首批与触底续页都不能依赖混合结果后的稀疏过滤。
    func testSearchModelPaginatesAnimeAndAIRealisticFromTypedSource() async {
        for type in [AvatarType.anime, .aiRealistic] {
            let model = SearchModel(
                service: ImageSearchService(diceBear: SourceFilteredAvatarProvider()),
                initialAvatarTypeSelection: AvatarTypeSelection(types: [type])
            )
            model.setActive(true)

            let loadedFirstPage = await waitUntil {
                model.results.count == 20
                    && model.results.allSatisfy { $0.avatarType == type }
                    && model.paginationState == .ready
            }
            XCTAssertTrue(loadedFirstPage, "\(type.rawValue) 首批未按类型生成")

            model.loadNextPage()
            let loadedSecondPage = await waitUntil {
                model.results.count == 40
                    && model.results.allSatisfy { $0.avatarType == type }
                    && model.paginationState == .ready
            }
            XCTAssertTrue(loadedSecondPage, "\(type.rawValue) 没有触底续页")
            XCTAssertEqual(Set(model.results.map(\.id)).count, 40)
            model.setActive(false)
        }
    }

    func testGiphySelectionDefaultsToAllTypesAndPersistsSubset() {
        let suiteName = "MirageCoreTests.GiphyContentTypeSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GiphyContentTypeSelectionStore(defaults: defaults)

        XCTAssertEqual(store.load(), .all)

        let subset = GiphyContentTypeSelection(types: [.gif, .sticker])
        store.save(subset)

        XCTAssertEqual(store.load(), subset)
        XCTAssertEqual(store.load().persistedValues, ["gif", "sticker"])
    }

    func testGiphySelectionNeverRemovesItsLastType() {
        let gifOnly = GiphyContentTypeSelection(types: [.gif])

        XCTAssertEqual(gifOnly.toggling(.gif), gifOnly)
        XCTAssertEqual(
            GiphyContentTypeSelection(types: []).types,
            Set(GiphyContentType.allCases)
        )
    }

    func testLegacyGiphyRecordWithoutContentTypeStillDecodes() throws {
        let data = Data(#"""
        {
          "id": "legacy-giphy",
          "title": "Legacy GIF",
          "source": "giphy",
          "imageURL": "https://media1.giphy.com/media/legacy/giphy.gif",
          "thumbnailURL": "https://media1.giphy.com/media/legacy/200w.gif",
          "license": { "identifier": "giphy-api", "displayName": "GIPHY API Terms" }
        }
        """#.utf8)

        let record = try JSONDecoder().decode(RemoteImageRecord.self, from: data)

        XCTAssertNil(record.giphyContentType)
    }

    func testSearchModelFiltersGiphyAtSourceAndKeepsSelectionAcrossTabs() async {
        let selected = GiphyContentTypeSelection(types: [.emoji, .sticker])
        var persistedSelections: [GiphyContentTypeSelection] = []
        let model = SearchModel(
            service: ImageSearchService(giphy: GiphyContentTypeFixtureClient()),
            initialGiphyContentTypeSelection: selected,
            giphyContentTypeSelectionDidChange: { persistedSelections.append($0) }
        )

        model.filter = .gif
        model.setActive(true)
        let loadedSelectedTypes = await waitUntil {
            Set(model.results.compactMap(\.giphyContentType)) == [.emoji, .sticker]
        }
        XCTAssertTrue(loadedSelectedTypes)

        model.filter = .avatars
        model.filter = .gif
        XCTAssertEqual(model.giphyContentTypeSelection, selected)

        model.toggleGiphyContentType(.emoji)
        let loadedStickerOnly = await waitUntil {
            model.results.map(\.giphyContentType) == [.sticker]
        }
        XCTAssertTrue(loadedStickerOnly)
        XCTAssertEqual(model.giphyContentTypeSelection.types, [.sticker])
        XCTAssertEqual(persistedSelections.map(\.types), [[.sticker]])

        model.toggleGiphyContentType(.sticker)
        XCTAssertEqual(model.giphyContentTypeSelection.types, [.sticker])
        XCTAssertEqual(persistedSelections.map(\.types), [[.sticker]])
        XCTAssertEqual(model.accessibilityEvent?.message, "至少保留一种 GIF 类型")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private struct GiphyContentTypeFixtureClient: GiphyCatalogSearching {
    let sourceID = PhotoSourceID.giphy

    func search(
        query: String,
        cursor: PhotoSourceCursor?,
        pageSize: Int
    ) async throws -> PhotoSourcePage {
        try await search(
            query: query,
            cursor: cursor,
            pageSize: pageSize,
            contentTypes: Set(GiphyContentType.allCases)
        )
    }

    func search(
        query _: String,
        cursor _: PhotoSourceCursor?,
        pageSize: Int,
        contentTypes: Set<GiphyContentType>
    ) async throws -> PhotoSourcePage {
        let records = GiphyContentType.allCases
            .filter(contentTypes.contains)
            .prefix(max(pageSize, 0))
            .map { type in
                let url = URL(
                    string: "https://media1.giphy.com/media/fixture-\(type.rawValue)/giphy.gif"
                )!
                return RemoteImageRecord(
                    id: "giphy-type-\(type.rawValue)",
                    title: type.displayName,
                    source: .giphy,
                    giphyContentType: type,
                    giphyID: "fixture-\(type.rawValue)",
                    imageURL: url,
                    thumbnailURL: url,
                    license: .giphy,
                    mimeType: "image/gif"
                )
            }
        return PhotoSourcePage(records: records, nextCursor: nil)
    }
}

private struct AvatarTypeFixtureProvider: AvatarProviding {
    private let records = AvatarType.allCases.map { type in
        let url = URL(string: "https://example.com/\(type.rawValue).png")!
        return RemoteImageRecord(
            id: "avatar-type-\(type.rawValue)",
            title: type.displayName,
            source: .diceBear,
            avatarType: type,
            imageURL: url,
            thumbnailURL: url,
            license: .cc0,
            mimeType: "image/png"
        )
    }

    func currentGenerationDay() async -> AvatarGenerationDay {
        AvatarGenerationDay(date: Date(timeIntervalSince1970: 0))
    }

    func avatars(
        query _: String,
        offset: Int,
        count: Int,
        generationDay _: AvatarGenerationDay
    ) async -> [RemoteImageRecord] {
        guard offset >= 0, count > 0, offset < records.count else { return [] }
        return Array(records.dropFirst(offset).prefix(count))
    }
}

private struct SourceFilteredAvatarProvider: AvatarProviding {
    func currentGenerationDay() async -> AvatarGenerationDay {
        AvatarGenerationDay(date: Date(timeIntervalSince1970: 0))
    }

    func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay
    ) async -> [RemoteImageRecord] {
        records(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay,
            type: .cartoonCharacter
        )
    }

    func avatars(
        query: String,
        offset: Int,
        count: Int,
        generationDay: AvatarGenerationDay,
        allowedTypes: Set<AvatarType>
    ) async -> [RemoteImageRecord] {
        guard let type = AvatarType.allCases.first(where: allowedTypes.contains) else { return [] }
        return records(
            query: query,
            offset: offset,
            count: count,
            generationDay: generationDay,
            type: type
        )
    }

    private func records(
        query _: String,
        offset: Int,
        count: Int,
        generationDay _: AvatarGenerationDay,
        type: AvatarType
    ) -> [RemoteImageRecord] {
        guard offset >= 0, count > 0 else { return [] }
        return (offset..<(offset + count)).compactMap { index in
            guard let url = URL(
                string: "https://example.com/typed/\(type.rawValue)/\(index).png"
            ) else { return nil }
            return RemoteImageRecord(
                id: "typed-\(type.rawValue)-\(index)",
                title: type.displayName,
                source: .diceBear,
                avatarType: type,
                imageURL: url,
                thumbnailURL: url,
                license: .cc0,
                mimeType: "image/png"
            )
        }
    }
}
