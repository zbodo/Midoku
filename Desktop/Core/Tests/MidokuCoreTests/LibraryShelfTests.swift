import Foundation
import XCTest

@testable import MidokuCore

final class LibraryShelfTests: XCTestCase {
    private func chapter(_ key: String, source: String = "en.test", manga: String = "series") -> ComicBook {
        var book = ComicBook(title: "Series — \(key)", pages: ["0.image", "1.image"], sourceIdentity: key)
        book.online = OnlineChapterReference(sourceKey: source, mangaKey: manga, chapterKey: key,
                                             mangaTitle: "Series", chapterTitle: key, cover: "https://example.org/cover",
                                             mangaData: Data(), chapterData: Data())
        return book
    }

    func testLegacyMigrationPreservesChaptersAndDoesNotFinishSeries() throws {
        var first = chapter("1")
        first.isRead = true
        first.currentPage = 1
        first.pageOffset = 0.6
        var second = chapter("2")
        second.isFavorite = true
        second.collection = "Favorites"
        var snapshot = LibrarySnapshot()
        snapshot.version = 1
        snapshot.books = [first, second]
        let original = snapshot.books
        snapshot.migrateChapterShelf()
        XCTAssertEqual(snapshot.books, original)
        XCTAssertEqual(snapshot.shelfBooks.count, 1)
        let shelf = try XCTUnwrap(snapshot.shelfBooks.first)
        XCTAssertEqual(shelf.title, "Series")
        XCTAssertEqual(shelf.chapterCount, 2)
        XCTAssertTrue(shelf.isFavorite)
        XCTAssertEqual(shelf.collection, "Favorites")
        XCTAssertFalse(shelf.isRead)
        let migrated = snapshot
        snapshot.migrateChapterShelf()
        XCTAssertEqual(snapshot, migrated)
    }

    func testSameTitleAndKeysFromDifferentSourcesStaySeparate() {
        var snapshot = LibrarySnapshot()
        snapshot.version = 1
        let local = ComicBook(title: "Series", pages: ["0.jpg"], sourceIdentity: "local")
        snapshot.books = [chapter("1"), chapter("2"), chapter("1", source: "other"),
                          chapter("1", manga: "other"), local]
        snapshot.migrateChapterShelf()
        XCTAssertEqual(snapshot.shelfBooks.count, 4)
        XCTAssertEqual(snapshot.mangaBooks.count, 3)
        XCTAssertTrue(snapshot.shelfBooks.contains { $0.id == local.id && $0.manga == nil })
        XCTAssertNotEqual(LibraryManga.identity(source: "a:b", manga: "c"),
                          LibraryManga.identity(source: "a", manga: "b:c"))
    }

    func testResumeKeepsLatestChapterPageAndOffsetIncludingCompletedChapter() throws {
        var first = chapter("1")
        first.lastReadAt = Date(timeIntervalSince1970: 20)
        first.currentPage = 1
        first.pageOffset = 0.7
        first.isRead = true
        var second = chapter("2")
        second.lastReadAt = Date(timeIntervalSince1970: 10)
        var snapshot = LibrarySnapshot()
        snapshot.version = 1
        snapshot.books = [first, second]
        snapshot.migrateChapterShelf()
        let shelf = try XCTUnwrap(snapshot.shelfBooks.first)
        XCTAssertEqual(shelf.readingBook?.id, first.id)
        XCTAssertEqual(shelf.readingBook?.currentPage, 1)
        XCTAssertEqual(shelf.readingBook?.pageOffset, 0.7)
        XCTAssertFalse(shelf.isRead)
    }

    func testWholeBookMetadataDoesNotChangeChapterProgress() throws {
        var snapshot = LibrarySnapshot()
        snapshot.version = 1
        snapshot.books = [chapter("1"), chapter("2")]
        snapshot.migrateChapterShelf()
        let id = try XCTUnwrap(snapshot.shelfBooks.first?.id)
        let chapters = snapshot.books
        snapshot.updateShelfBook(id) {
            $0.title = "Custom title"
            $0.isFavorite = true
            $0.collection = "Comics"
        }
        XCTAssertEqual(snapshot.books, chapters)
        XCTAssertEqual(snapshot.shelfBooks.first?.title, "Custom title")
        XCTAssertFalse(snapshot.shelfBooks.first?.isRead ?? true)
        snapshot.books.append(chapter("3"))
        snapshot.migrateChapterShelf()
        XCTAssertEqual(snapshot.shelfBooks.count, 1)
        XCTAssertEqual(snapshot.shelfBooks.first?.chapterCount, 3)
        XCTAssertEqual(snapshot.shelfBooks.first?.collection, "Comics")
    }

    func testRemovingWholeBookRetainsHistoryAndDoesNotReappearAfterMigration() throws {
        var snapshot = LibrarySnapshot()
        snapshot.version = 1
        let first = chapter("1"), second = chapter("2"), other = chapter("1", source: "other")
        snapshot.books = [first, second, other]
        snapshot.migrateChapterShelf()
        let id = try XCTUnwrap(snapshot.mangaBooks.first { $0.sourceKey == "en.test" }?.id)
        XCTAssertTrue(snapshot.removeShelfBooks([id]).isEmpty)
        snapshot.migrateChapterShelf()
        XCTAssertEqual(snapshot.books, [first, second, other])
        XCTAssertEqual(snapshot.retainedManga?.first?.id, id)
        XCTAssertEqual(snapshot.shelfBooks.count, 1)
    }

    func testAddingBookWithoutOpeningAChapterPersists() throws {
        var snapshot = LibrarySnapshot()
        snapshot.version = 2
        snapshot.mangaBooks = [LibraryManga(sourceKey: "en.test", mangaKey: "series", title: "Series", cover: nil)]
        XCTAssertEqual(snapshot.shelfBooks.count, 1)
        XCTAssertNil(snapshot.shelfBooks.first?.readingBook)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertEqual(try LibraryPersistence.load(from: file), snapshot)
        XCTAssertTrue(snapshot.removeShelfBooks([snapshot.mangaBooks[0].id]).isEmpty)
        XCTAssertTrue(snapshot.shelfBooks.isEmpty)
    }

    func testLegacyFileWithoutMangaFieldMigratesAndSavesWithoutLosingProgress() throws {
        var snapshot = LibrarySnapshot()
        snapshot.version = 1
        snapshot.books = [chapter("1"), chapter("2")]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "mangaBooks")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let loaded = try LibraryPersistence.load(from: file)
        XCTAssertEqual(loaded.books, snapshot.books)
        XCTAssertEqual(loaded.shelfBooks.count, 1)
        XCTAssertEqual(try LibraryPersistence.load(from: file), loaded)
        try LibraryPersistence.save(loaded, to: file)
        XCTAssertEqual(try LibraryPersistence.load(from: file), loaded)
    }

    func testDuplicateMangaIdentitiesAreRejected() throws {
        var snapshot = LibrarySnapshot()
        snapshot.version = 1
        snapshot.mangaBooks = [LibraryManga(sourceKey: "a", mangaKey: "b", title: "One", cover: nil),
                               LibraryManga(sourceKey: "a", mangaKey: "b", title: "Two", cover: nil)]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertThrowsError(try LibraryPersistence.load(from: file))
    }
    func testCatalogRefreshRestoresLatestProgressOfRemovedChapter() throws {
        var manga = LibraryManga(sourceKey: "source", mangaKey: "series", title: "Series", cover: nil)
        manga.refreshCatalog([LibraryChapter(key: "1", title: "Old")])
        manga.refreshCatalog([])
        manga.updateChapter("1") {
            $0.currentPage = 4; $0.pageOffset = 0.75; $0.isRead = true
        }
        manga.refreshCatalog([LibraryChapter(key: "1", title: "New")])
        let restored = try XCTUnwrap(manga.chapters?.first)
        XCTAssertEqual(restored.title, "New")
        XCTAssertEqual(restored.currentPage, 4)
        XCTAssertEqual(restored.pageOffset, 0.75)
        XCTAssertTrue(restored.isRead)
        XCTAssertTrue(manga.chapterHistory?.isEmpty ?? false)
    }

    func testCatalogRefreshPreservesUnreadEditsAndFlagsNewChapters() throws {
        var manga = LibraryManga(sourceKey: "source", mangaKey: "series", title: "Series", cover: nil)
        let firstDate = Date(timeIntervalSince1970: 10)
        manga.refreshCatalog([LibraryChapter(key: "1", title: "One", isRead: true)], at: firstDate)
        manga.updateChapter("1") { $0.isRead = false; $0.currentPage = 0 }
        let nextDate = Date(timeIntervalSince1970: 20)
        manga.refreshCatalog([LibraryChapter(key: "2", title: "Two"),
                              LibraryChapter(key: "1", title: "Updated", isRead: true)], at: nextDate)
        XCTAssertFalse(try XCTUnwrap(manga.chapterRecord("1")).isRead)
        XCTAssertEqual(manga.lastUpdatedAt, nextDate)
        XCTAssertEqual(manga.hasUpdates, true)
    }

    func testBatchUnreadIncludesRemovedChapters() throws {
        var manga = LibraryManga(sourceKey: "source", mangaKey: "series", title: "Series", cover: nil)
        manga.refreshCatalog([LibraryChapter(key: "1", title: "One", isRead: true)])
        manga.refreshCatalog([])
        var snapshot = LibrarySnapshot()
        snapshot.mangaBooks = [manga]
        snapshot.markChapters([manga.id], read: false)
        manga = try XCTUnwrap(snapshot.mangaBooks.first)
        manga.refreshCatalog([LibraryChapter(key: "1", title: "One", isRead: true)])
        XCTAssertFalse(try XCTUnwrap(manga.chapters?.first).isRead)
    }

    func testContinuationPrefersUnfinishedAndSkipsLockedUnlessDownloaded() {
        let chapters = [LibraryChapter(key: "locked", title: "Locked", locked: true),
                        LibraryChapter(key: "unread", title: "Unread"),
                        LibraryChapter(key: "partial", title: "Partial", lastReadAt: Date(timeIntervalSince1970: 10)),
                        LibraryChapter(key: "finished", title: "Finished", isRead: true,
                                       lastReadAt: Date(timeIntervalSince1970: 20))]
        XCTAssertEqual(ChapterContinuation.next(in: chapters)?.key, "partial")
        XCTAssertEqual(ChapterContinuation.next(in: chapters, resumeLastOpened: true)?.key, "finished")
        XCTAssertEqual(ChapterContinuation.next(in: Array(chapters.prefix(2)))?.key, "unread")
        XCTAssertEqual(ChapterContinuation.next(in: Array(chapters.prefix(2)), downloadedKeys: ["locked"])?.key, "locked")
        XCTAssertNil(ChapterContinuation.next(in: [chapters[3]]))
    }

    func testMultipleCategoriesAndQueryPinning() {
        var first = ComicBook(title: "Alpha", pages: ["0.jpg"], sourceIdentity: "a")
        first.categories = ["One", "Two", "One"]
        var second = ComicBook(title: "Beta", pages: ["0.jpg"], sourceIdentity: "b")
        second.isRead = true
        XCTAssertEqual(first.categories, ["One", "Two"])
        var query = LibraryQuery()
        query.category = "Two"
        XCTAssertEqual(query.apply(to: [ShelfBook(local: first), ShelfBook(local: second)]).map(\.id), [first.id])
        query.category = nil; query.sort = .title; query.ascending = false; query.pin = .unread
        XCTAssertEqual(query.apply(to: [ShelfBook(local: second), ShelfBook(local: first)]).map(\.id), [first.id, second.id])
        query.unread = .exclude
        XCTAssertEqual(query.apply(to: [ShelfBook(local: first), ShelfBook(local: second)]).map(\.id), [second.id])
    }

}
