import Foundation

/// 将多个 provider 的固定配额页并发读取后稳定交错，不让单源失败拖垮整页。
public struct AggregatedPhotoSearcher: PhotoSearching, Sendable {
    private let sources: [any PhotoSourceSearching]
    private let configurationRevision: UInt64
    private let initialIssues: [PhotoSourceIssue]

    public init(
        sources: [any PhotoSourceSearching],
        configurationRevision: UInt64,
        initialIssues: [PhotoSourceIssue] = []
    ) {
        var seen = Set<PhotoSourceID>()
        self.sources = sources.filter { seen.insert($0.sourceID).inserted }
        self.configurationRevision = configurationRevision
        self.initialIssues = initialIssues
    }

    public func configurationKey() async -> String {
        let ids = sources.map(\.sourceID.rawValue).joined(separator: ",")
        return "sources:\(configurationRevision):\(ids)"
    }

    public func search(query: String, cursor: PhotoSearchCursor?, pageSize: Int) async throws -> PhotoSearchPage {
        let states = try resolvedStates(cursor: cursor, pageSize: pageSize, legacyPage: nil)
        return try await load(query: query, states: states)
    }

    public func search(query: String, page: Int, pageSize: Int) async throws -> PhotoSearchPage {
        guard page >= 1 else { throw PhotoSearchError.invalidCursor }
        let states = try resolvedStates(cursor: nil, pageSize: pageSize, legacyPage: page)
        return try await load(query: query, states: states)
    }

    private func resolvedStates(
        cursor: PhotoSearchCursor?,
        pageSize: Int,
        legacyPage: Int?
    ) throws -> [PhotoSourceCursorState] {
        guard !sources.isEmpty else { throw PhotoSearchError.noEnabledSources }
        guard pageSize > 0, pageSize <= SearchPaginationCursor.maximumPageSize else {
            throw PhotoSearchError.invalidCursor
        }
        if let cursor {
            guard cursor.configurationRevision == configurationRevision else {
                throw PhotoSearchError.configurationChanged
            }
            let cursorIDs = cursor.states.map(\.sourceID)
            let availableIDs = sources.map(\.sourceID).filter { cursorIDs.contains($0) }
            let hasValidStates = cursor.states.allSatisfy { state in
                (1...SearchPaginationCursor.maximumPageSize).contains(state.pageSize)
                    && (!state.exhausted || state.cursor == nil)
            }
            let quota = hasValidStates ? cursor.states.map(\.pageSize).reduce(0, +) : -1
            guard !cursorIDs.isEmpty, Set(cursorIDs).count == cursorIDs.count,
                  cursorIDs == availableIDs,
                  quota == pageSize,
                  hasValidStates else {
                throw PhotoSearchError.invalidCursor
            }
            return cursor.states
        }
        let activeSources = Array(sources.prefix(min(pageSize, sources.count)))
        let quotas = Self.quotas(total: pageSize, count: activeSources.count)
        return zip(activeSources, quotas).map { source, quota in
            let value = legacyPage.flatMap { $0 > 1 ? PhotoSourceCursor(rawValue: String($0)) : nil }
            return PhotoSourceCursorState(
                sourceID: source.sourceID,
                cursor: value,
                pageSize: quota,
                exhausted: false
            )
        }
    }

    private func load(query: String, states: [PhotoSourceCursorState]) async throws -> PhotoSearchPage {
        let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.sourceID, $0) })
        let outcomes = await withTaskGroup(of: SourceOutcome.self, returning: [SourceOutcome].self) { group in
            for state in states where !state.exhausted {
                guard let source = sourceByID[state.sourceID] else { continue }
                group.addTask {
                    do {
                        let page = try await source.search(
                            query: query,
                            cursor: state.cursor,
                            pageSize: state.pageSize
                        )
                        return .success(sourceID: state.sourceID, page: page)
                    } catch is CancellationError {
                        return .cancelled(sourceID: state.sourceID)
                    } catch {
                        return .failure(Self.issue(for: error, sourceID: state.sourceID))
                    }
                }
            }
            var values: [SourceOutcome] = []
            for await value in group { values.append(value) }
            return values
        }
        if outcomes.contains(where: \.isCancelled) { throw CancellationError() }

        let byID = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.sourceID, $0) })
        var pages: [[RemoteImageRecord]] = []
        var nextStates: [PhotoSourceCursorState] = []
        var issues = initialIssues
        var successfulSources = 0
        for state in states {
            guard !state.exhausted, let outcome = byID[state.sourceID] else {
                nextStates.append(state)
                continue
            }
            switch outcome {
            case let .success(_, page):
                guard (page.nextCursor?.rawValue.utf8.count ?? 0) <= 1_024 else {
                    issues.append(PhotoSourceIssue(
                        sourceID: state.sourceID,
                        kind: .invalidResponse,
                        message: "\(PhotoSourceRegistry.descriptor(for: state.sourceID)?.displayName ?? state.sourceID.rawValue) 返回了无效分页位置。"
                    ))
                    nextStates.append(state)
                    continue
                }
                successfulSources += 1
                pages.append(Array(page.records
                    .filter { $0.source.photoSourceID == state.sourceID }
                    .prefix(state.pageSize)))
                nextStates.append(PhotoSourceCursorState(
                    sourceID: state.sourceID,
                    cursor: page.nextCursor,
                    pageSize: state.pageSize,
                    exhausted: page.nextCursor == nil
                ))
            case let .failure(issue):
                issues.append(issue)
                nextStates.append(state)
            case .cancelled:
                throw CancellationError()
            }
        }
        guard successfulSources > 0 else { throw PhotoSearchError.allSourcesFailed(issues) }
        let records = Self.interleaved(pages)
        let next = nextStates.contains { !$0.exhausted }
            ? PhotoSearchCursor(configurationRevision: configurationRevision, states: nextStates)
            : nil
        return PhotoSearchPage(records: records, nextCursor: next, issues: issues)
    }

    private static func quotas(total: Int, count: Int) -> [Int] {
        let activeCount = min(total, count)
        let base = total / activeCount
        let remainder = total % activeCount
        return (0..<activeCount).map { base + ($0 < remainder ? 1 : 0) }
    }

    private static func interleaved(_ pages: [[RemoteImageRecord]]) -> [RemoteImageRecord] {
        var result: [RemoteImageRecord] = []
        var seen = Set<String>()
        let maximum = pages.map(\.count).max() ?? 0
        for index in 0..<maximum {
            for page in pages where page.indices.contains(index) && seen.insert(page[index].id).inserted {
                result.append(page[index])
            }
        }
        return result
    }

    private static func issue(for error: Error, sourceID: PhotoSourceID) -> PhotoSourceIssue {
        guard let failure = error as? any PhotoSourceFailure else {
            return PhotoSourceIssue(
                sourceID: sourceID,
                kind: .unavailable,
                message: "\(PhotoSourceRegistry.descriptor(for: sourceID)?.displayName ?? sourceID.rawValue) 暂时不可用。"
            )
        }
        return PhotoSourceIssue(
            sourceID: failure.sourceID,
            kind: failure.issueKind,
            message: error.localizedDescription,
            retryAt: failure.retryAt
        )
    }
}

private enum SourceOutcome: Sendable {
    case success(sourceID: PhotoSourceID, page: PhotoSourcePage)
    case failure(PhotoSourceIssue)
    case cancelled(sourceID: PhotoSourceID)

    var sourceID: PhotoSourceID {
        switch self {
        case let .success(sourceID, _), let .cancelled(sourceID): return sourceID
        case let .failure(issue): return issue.sourceID
        }
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
