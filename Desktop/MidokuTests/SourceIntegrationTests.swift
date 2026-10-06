import AidokuRunner
import AppKit
import MidokuCore
import XCTest
import ZIPFoundation

@testable import Midoku

private struct ComicFixtureRunner: AidokuRunner.Runner {
    let image: AidokuRunner.PlatformImage
    let features = AidokuRunner.SourceFeatures()
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws
        -> AidokuRunner.MangaPageResult
    {
        .init(entries: [.init(sourceKey: "", key: "manga", title: query ?? "Example")], hasNextPage: false)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws
        -> AidokuRunner.Manga
    {
        var manga = manga
        manga.viewer = .leftToRight
        manga.chapters = [.init(key: "chapter", chapterNumber: 1)]
        return manga
    }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        [.init(content: .image(image)), .init(content: .image(image))]
    }
}

final class SourceIntegrationTests: XCTestCase {
    @MainActor func testSearchDetailsChapterCacheAndResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(AidokuRunner.PlatformImage(data: bytes))
        let source = AidokuRunner.Source(
            key: "en.fixture", name: "Fixture", version: 1, languages: ["en"], contentRating: .safe,
            runner: ComicFixtureRunner(image: image))
        let found = try await source.getSearchMangaList(query: "Example", page: 1, filters: [])
        XCTAssertEqual(found.entries.first?.sourceKey, source.key)
        let manga = try await source.getMangaUpdate(
            manga: XCTUnwrap(found.entries.first), needsDetails: true, needsChapters: true)
        let chapter = try XCTUnwrap(manga.chapters?.first)
        let library = LibraryStore(root: root)
        let sources = SourceStore(root: root.appendingPathComponent("Sources"))
        let id = try await sources.openChapter(source: source, manga: manga, chapter: chapter, library: library)
        XCTAssertTrue(library.shelfBooks.isEmpty, "Opening a chapter must not automatically add the manga")
        library.addManga(source: source.key, key: manga.key, title: manga.title, cover: manga.cover)
        let book = try XCTUnwrap(library.book(id))
        for index in book.pages.indices {
            let url = try XCTUnwrap(library.pageURL(for: book, at: index))
            let preview = try await PageImages.shared.preview(for: url)
            XCTAssertEqual(preview.width, 8)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let reader = ReaderSession(book: book, library: library)
        XCTAssertEqual(reader.direction, .leftToRight)
        reader.seek(1)
        let again = try await sources.openChapter(source: source, manga: manga, chapter: chapter, library: library)
        XCTAssertEqual(id, again)
        XCTAssertEqual(library.books.count, 1)
        let restored = LibraryStore(root: root)
        XCTAssertEqual(restored.book(id)?.currentPage, 1)
        let restoredBook = try XCTUnwrap(restored.book(id))
        try await sources.prepare(restoredBook, library: restored)
        XCTAssertEqual(restoredBook.online?.chapterKey, chapter.key)
        let shelf = try XCTUnwrap(restored.shelfBooks.first)
        XCTAssertEqual(shelf.title, manga.title)
        XCTAssertEqual(shelf.readingBook?.id, id)
        restored.updateShelfBook(shelf.id) { $0.isFavorite = true; $0.collection = "Comics" }
        let secondID = try await sources.openChapter(
            source: source, manga: manga, chapter: .init(key: "chapter-2", chapterNumber: 2), library: restored)
        restored.saveProgress(secondID, page: 1, finished: true, offset: 0.5)
        var fullManga = manga
        fullManga.chapters = [.init(key: "chapter-3", chapterNumber: 3),
                              .init(key: "chapter-2", chapterNumber: 2), chapter]
        restored.synchronizeManga(fullManga, source: source.key)
        XCTAssertEqual(restored.mangaRecord(source: source.key, key: manga.key)?.chapterRecord("chapter-2")?.pageOffset, 0.5)
        XCTAssertEqual(restored.books.count, 2)
        XCTAssertEqual(restored.shelfBooks.count, 1)
        XCTAssertEqual(restored.shelfBooks.first?.id, shelf.id)
        XCTAssertEqual(restored.shelfBooks.first?.readingBook?.id, secondID)
        XCTAssertEqual(restored.shelfBooks.first?.readingBook?.pageOffset, 0.5)
        XCTAssertFalse(restored.shelfBooks.first?.isRead ?? true)
        let reopened = LibraryStore(root: root)
        XCTAssertTrue(reopened.shelfBooks.first?.isFavorite ?? false)
        XCTAssertEqual(reopened.shelfBooks.first?.collection, "Comics")
        reopened.remove([shelf.id])
        XCTAssertEqual(reopened.books.count, 2)
        XCTAssertTrue(reopened.shelfBooks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(secondID.uuidString).path))
        reopened.addManga(source: source.key, key: manga.key, title: manga.title, cover: manga.cover)
        XCTAssertEqual(reopened.shelfBooks.first?.id, shelf.id)
        XCTAssertEqual(reopened.shelfBooks.first?.unreadCount, 1)
        XCTAssertTrue(reopened.shelfBooks.first?.isFavorite ?? false)
        XCTAssertEqual(reopened.shelfBooks.first?.categories, ["Comics"])
        XCTAssertEqual(reopened.continuation(source: source.key, manga: manga.key, resumeLastOpened: false)?.key, "chapter-3")
        reopened.markChapters([shelf.id], read: false)
        XCTAssertEqual(reopened.shelfBooks.first?.unreadCount, 3)
        XCTAssertFalse(reopened.book(secondID)?.isRead ?? true)
    }

    func testModernPackageExtractionRejectsTraversalAndLegacyLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, path) in ["Payload/../escape", "Payload/main.wasm", "main.wasm"].enumerated() {
            let url = root.appendingPathComponent("\(index).aix")
            let archive = try Archive(url: url, accessMode: .create)
            let data = Data([1, 2, 3])
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { start, count in
                data.subdata(in: Int(start)..<(Int(start) + count))
            }
            XCTAssertThrowsError(
                try SourceService.extractPackage(url, into: root.appendingPathComponent("out\(index)")))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }
}

private actor RequestFixtureRunner: AidokuRunner.Runner {
    nonisolated let features = AidokuRunner.SourceFeatures(processesPages: true, providesImageRequests: true)
    let image: AidokuRunner.PlatformImage
    var removed: [Int32] = []
    var processedContext: AidokuRunner.PageContext?
    init(image: AidokuRunner.PlatformImage) { self.image = image }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws
        -> AidokuRunner.MangaPageResult
    { .init(entries: [], hasNextPage: false) }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws
        -> AidokuRunner.Manga
    { manga }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        []
    }
    func getImageRequest(url: String, context: AidokuRunner.PageContext?) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Fixture token", forHTTPHeaderField: "Authorization")
        request.setValue(context?["page"], forHTTPHeaderField: "X-Page")
        return request
    }
    func processPageImage(response: AidokuRunner.Response, context: AidokuRunner.PageContext?) async throws
        -> AidokuRunner.PlatformImage?
    {
        processedContext = context
        return image
    }
    func store<T: Sendable>(value: T) async throws -> Int32 { 7 }
    func remove(value: Int32) async throws { removed.append(value) }
}

extension SourceIntegrationTests {
    @MainActor func testCustomImageRequestContextAndProcessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = try XCTUnwrap(
            AidokuRunner.PlatformImage(data: XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
        let runner = RequestFixtureRunner(image: image)
        let source = AidokuRunner.Source(
            key: "en.requests", name: "Requests", version: 1, contentRating: .safe, runner: runner)
        let cache = RemotePageCache(fetch: { request, key in
            XCTAssertEqual(key, "en.requests")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Fixture token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Page"), "1")
            return (
                Data("encoded-image".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            )
        })
        let book = ComicBook(title: "Processed", pages: ["0.image"], sourceIdentity: "test")
        await cache.register(
            book: book, source: source,
            pages: [.init(content: .url(url: URL(string: "https://example.org/image")!, context: ["page": "1"]))],
            root: root)
        let url = root.appendingPathComponent(book.id.uuidString).appendingPathComponent("0.image")
        try await cache.ensureFile(at: url)
        XCTAssertNotNil(NSImage(contentsOf: url))
        let removed = await runner.removed
        let context = await runner.processedContext
        XCTAssertEqual(removed, [7])
        XCTAssertEqual(context, ["page": "1"])
        try await cache.ensureFile(at: url)  // Cached pages do not invoke processing again.
        let finalRemoved = await runner.removed
        XCTAssertEqual(finalRemoved, [7])
    }
}

extension SourceIntegrationTests {
    @MainActor func testPinnedWasmPackageLoadsThroughNativeHost() async throws {
        // Use the test module already present in the pinned dependency checkout;
        // no network requests or copied third-party binaries are needed here.
        var derivedData = Bundle.main.bundleURL
        for _ in 0..<4 { derivedData.deleteLastPathComponent() }
        let checkouts = derivedData.appendingPathComponent("SourcePackages/checkouts")
        guard
            let runnerCheckout = try? FileManager.default.contentsOfDirectory(
                at: checkouts, includingPropertiesForKeys: nil
            )
            .first(where: { $0.lastPathComponent.lowercased() == "aidokurunner" })
        else {
            throw XCTSkip("Run with -derivedDataPath build/Desktop so the pinned dependency fixture is available.")
        }
        let payload = runnerCheckout.appendingPathComponent("Tests/AidokuRunnerTests/Resources/Payload")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.aix")
        let archive = try Archive(url: file, accessMode: .create)
        for name in ["source.json", "main.wasm"] {
            let data = try Data(contentsOf: payload.appendingPathComponent(name))
            try archive.addEntry(with: "Payload/" + name, type: .file, uncompressedSize: Int64(data.count)) {
                start, count in
                data.subdata(in: Int(start)..<(Int(start) + count))
            }
        }
        let folder = UUID()
        let destination = root.appendingPathComponent(folder.uuidString)
        try SourceService.extractPackage(file, into: destination)
        var snapshot = SourceSnapshot()
        snapshot.installed = [
            .init(
                id: "test", name: "Test", version: 1, languages: ["en"], folder: folder,
                repository: URL(string: "https://example.org/index.json")!)
        ]
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent("sources.json"), options: .atomic)
        let service = try SourceService(root: root)
        async let first = service.source("test")
        async let second = service.source("test")
        let (source, duplicate) = try await (first, second)
        XCTAssertTrue(source === duplicate, "Concurrent reader windows must share one source runtime")
        XCTAssertEqual(source.apiVersion, "0.7")
        XCTAssertEqual(source.name, "Test")
        XCTAssertEqual(source.version, 1)
        _ = try await source.getHome()
    }
}

extension SourceIntegrationTests {
    func testCookiesRespectHostPathAndSecureScope() throws {
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "session", .value: "fixture", .domain: "example.org", .path: "/account", .secure: "TRUE",
            ]))
        var valid = URLRequest(url: URL(string: "https://example.org/account/pages")!)
        SourceHTTP.addCookies([cookie], to: &valid)
        XCTAssertEqual(valid.value(forHTTPHeaderField: "Cookie"), "session=fixture")
        valid.setValue("session=explicit", forHTTPHeaderField: "Cookie")
        SourceHTTP.addCookies([cookie], to: &valid)
        XCTAssertEqual(valid.value(forHTTPHeaderField: "Cookie"), "session=explicit")
        for raw in [
            "https://example.org/accounts", "https://other.org/account", "https://cdn.example.org/account",
            "http://example.org/account",
        ] {
            var request = URLRequest(url: URL(string: raw)!)
            SourceHTTP.addCookies([cookie], to: &request)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
    }
}
