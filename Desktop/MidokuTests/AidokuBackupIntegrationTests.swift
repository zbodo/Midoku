import AidokuRunner
import Foundation
import MidokuCore
import XCTest

@testable import Midoku

final class AidokuBackupIntegrationTests: XCTestCase {
    private func fixture(viewer: Int = 1, rating: Int = 0, edits: Int = 0, mode: String = "auto") throws
        -> AidokuBackupPreview
    {
        let json = """
            {"date":1791270000,"library":[{"sourceId":"en.backup","mangaId":"manga",
             "dateAdded":1700000000,"lastOpened":1700000000,"lastUpdated":1700000000,"categories":["A","B"]}],
             "manga":[{"id":"manga","sourceId":"en.backup","title":"Imported","status":1,
             "nsfw":\(rating),"viewer":\(viewer),"editedKeys":\(edits)}],
             "chapters":[{"sourceId":"en.backup","mangaId":"manga","id":"chapter","lang":"en","sourceOrder":0}],
             "history":[{"sourceId":"en.backup","mangaId":"manga","chapterId":"chapter",
             "dateRead":1791262000,"progress":7,"total":20,"completed":true}],
             "settings":{"en.backup.value":"imported","en.backup.extra":true,
             "Reader.readingMode.en.backup.manga":"\(mode)"}}
            """
        let data = Data(json.utf8)
        return .init(filename: "fixture.aib", data: data, backup: try AidokuBackup.decode(data))
    }

    @MainActor func testLegacyViewerAndRatingMapByMeaning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        try library.restoreAidokuBackup(fixture(), settings: false)
        let manga = try XCTUnwrap(library.aidokuManga(source: "en.backup", key: "manga"))
        XCTAssertEqual(manga.viewer, .rightToLeft)  // Legacy 1 means RTL; Runner 1 means LTR.
        XCTAssertEqual(manga.contentRating, .safe)  // Legacy 0 means safe; Runner 0 means unknown.
        XCTAssertEqual(manga.chapters?.first?.key, "chapter")
        XCTAssertEqual(library.snapshot.collections, ["A", "B"])
        try library.restoreAidokuBackup(fixture(viewer: 2, rating: 2), settings: false)
        let updated = try XCTUnwrap(library.aidokuManga(source: "en.backup", key: "manga"))
        XCTAssertEqual(updated.viewer, .leftToRight)
        XCTAssertEqual(updated.contentRating, .nsfw)
    }

    @MainActor func testChapterResumeAndNewerLocalHistoryWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        try library.restoreAidokuBackup(fixture(), settings: false)
        var book = ComicBook(title: "Chapter", pages: (0..<20).map { "\($0).image" }, sourceIdentity: "online")
        book.online = .init(
            sourceKey: "en.backup", mangaKey: "manga", chapterKey: "chapter",
            mangaTitle: "Imported", chapterTitle: "Chapter", cover: nil,
            mangaData: Data(), chapterData: Data())
        library.applyImportedHistory(to: &book)
        XCTAssertEqual(book.currentPage, 6)
        XCTAssertTrue(book.isRead)
        book.currentPage = 10
        book.lastReadAt = Date(timeIntervalSince1970: 1_791_270_000)
        book.isRead = false
        library.applyImportedHistory(to: &book)
        XCTAssertEqual(book.currentPage, 10)
        XCTAssertFalse(book.isRead)
    }

    @MainActor func testEditedMetadataAndPerMangaReadingModeSurviveSourceRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        try library.restoreAidokuBackup(fixture(edits: 1, mode: "ltr"), settings: true)
        var refreshed = AidokuRunner.Manga(
            sourceKey: "en.backup", key: "manga", title: "Source title", viewer: .rightToLeft)
        library.applyAidokuMangaOverrides(to: &refreshed, source: "en.backup")
        XCTAssertEqual(refreshed.title, "Imported")
        XCTAssertEqual(refreshed.viewer, .leftToRight)
    }

    @MainActor func testRestoredSettingsDoNotOverwriteLaterUserChangesOnEverySourceLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsKey = "en.backup.value"
        let marker = "midoku.aidoku.settingsRevision.en.backup"
        let oldValue = UserDefaults.standard.object(forKey: settingsKey)
        let oldExtra = UserDefaults.standard.object(forKey: "en.backup.extra")
        let oldMarker = UserDefaults.standard.object(forKey: marker)
        defer {
            UserDefaults.standard.set(oldValue, forKey: settingsKey)
            UserDefaults.standard.set(oldExtra, forKey: "en.backup.extra")
            UserDefaults.standard.set(oldMarker, forKey: marker)
        }
        let library = LibraryStore(root: root)
        try library.restoreAidokuBackup(fixture(), settings: true)
        library.applyAidokuSourceSettings("en.backup", force: true)
        XCTAssertEqual(UserDefaults.standard.string(forKey: settingsKey), "imported")
        UserDefaults.standard.set("customized", forKey: settingsKey)
        library.applyAidokuSourceSettings("en.backup")
        XCTAssertEqual(UserDefaults.standard.string(forKey: settingsKey), "customized")
        let reopened = LibraryStore(root: root)
        reopened.applyAidokuSourceSettings("en.backup")
        XCTAssertEqual(UserDefaults.standard.string(forKey: settingsKey), "customized")
    }

    @MainActor func testPersistenceFailureDoesNotApplyBackupOrPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        // A directory at the destination prevents the atomic library write.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try library.restoreAidokuBackup(fixture(), settings: true))
        XCTAssertNil(library.aidokuBackup)
        let backups = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertNil(try LibraryPersistence.load(from: backups[0]).aidokuBackupFile)
    }
}
