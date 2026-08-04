import Foundation
import XCTest
@testable import MirageCore

final class PhotoSourceCredentialStoreTests: XCTestCase {
    func testAppAndFinderInstancesSharePersistentCredentialFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appStore = AppGroupPhotoSourceCredentialStore(baseURL: root)
        let finderStore = AppGroupPhotoSourceCredentialStore(baseURL: root)

        try await appStore.store("  saved-key  ", for: .pexels)

        let sharedValue = try await finderStore.credential(for: .pexels)
        XCTAssertEqual(sharedValue, "saved-key")
        let fileURL = root.appendingPathComponent("photo-source-credentials-v1.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o600)

        try await finderStore.removeCredential(for: .pexels)
        let removedValue = try await appStore.credential(for: .pexels)
        XCTAssertNil(removedValue)
    }

    func testCorruptOrOversizedCredentialFileIsRejected() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("photo-source-credentials-v1.json")
        try Data(repeating: 0x41, count: 64 * 1_024 + 1).write(to: fileURL)
        let store = AppGroupPhotoSourceCredentialStore(baseURL: root)

        do {
            _ = try await store.credential(for: .pexels)
            XCTFail("超限持久文件应被拒绝")
        } catch let error as PhotoSourceCredentialError {
            XCTAssertEqual(error, .corruptStorage)
        }
    }

    func testPixabayAndPexelsCredentialsCoexistAndRemoveIndependently() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppGroupPhotoSourceCredentialStore(baseURL: root)

        try await store.store("pexels-key", for: .pexels)
        try await store.store("pixabay-key", for: .pixabay)

        let savedPexels = try await store.credential(for: .pexels)
        let savedPixabay = try await store.credential(for: .pixabay)
        XCTAssertEqual(savedPexels, "pexels-key")
        XCTAssertEqual(savedPixabay, "pixabay-key")

        try await store.removeCredential(for: .pixabay)

        let retainedPexels = try await store.credential(for: .pexels)
        let removedPixabay = try await store.credential(for: .pixabay)
        XCTAssertEqual(retainedPexels, "pexels-key")
        XCTAssertNil(removedPixabay)
    }

    func testMissingAppGroupEntitlementFailsBeforeCredentialFileAccess() async {
        let store = AppGroupPhotoSourceCredentialStore(
            baseURL: nil,
            hasRequiredAppGroupEntitlement: false
        )

        do {
            _ = try await store.credential(for: .giphy)
            XCTFail("缺少 App Group 权限时应立即失败")
        } catch let error as PhotoSourceCredentialError {
            XCTAssertEqual(error, .missingAppGroupEntitlement)
        } catch {
            XCTFail("错误分类不正确：\(error)")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MiragePhotoSourceCredentialTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
