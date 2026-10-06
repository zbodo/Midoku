import AidokuRunner
import Foundation
import MidokuCore
import SwiftUI

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var snapshot = SourceSnapshot()
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    private let service: SourceService?
    let root: URL

    init(root: URL) {
        self.root = root
        do { service = try SourceService(root: root) } catch {
            service = nil
            errorMessage = error.localizedDescription
        }
        Task { if let service { snapshot = await service.state() } }
    }

    func source(_ key: String) async throws -> AidokuRunner.Source {
        guard let service else { throw SourceFailure.noSource(key) }
        return try await service.source(key)
    }

    func operation(_ work: @escaping (SourceService) async throws -> Void) {
        guard !busy, let service else { return }
        busy = true
        errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await work(service)
                snapshot = await service.state()
            } catch {
                errorMessage = error.localizedDescription
                snapshot = await service.state()
            }
        }
    }
    func add(_ input: String) {
        do {
            let address = try RepositoryAddress(input)
            operation { try await $0.addRepository(address) }
        } catch { errorMessage = error.localizedDescription }
    }
    func install(_ entry: SourceCatalogEntry, repository: URL) {
        operation { service in
            try await service.install(entry, repository: repository)
            await RemotePageCache.shared.unregister(sourceKey: entry.id)
        }
    }
    func uninstall(_ key: String) {
        operation { service in
            try await service.uninstall(key)
            await RemotePageCache.shared.unregister(sourceKey: key)
        }
    }
    func remove(_ url: URL) { operation { try await $0.removeRepository(url) } }
    func refresh(_ url: URL) { operation { try await $0.addRepository(RepositoryAddress(url.absoluteString)) } }

    func openChapter(
        source: AidokuRunner.Source, manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter,
        library: LibraryStore
    ) async throws -> UUID {
        let pages = try await source.getPageList(manga: manga, chapter: chapter)
        try Task.checkCancellation()
        guard !pages.isEmpty else { throw SourceFailure.noPages }
        guard pages.count <= 10_000 else { throw SourceFailure.tooLarge }
        var storedManga = manga
        storedManga.chapters = nil  // Avoid duplicating a full series chapter list in every library record.
        let reference = OnlineChapterReference(
            sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key,
            mangaTitle: manga.title, chapterTitle: chapter.displayTitle, cover: manga.cover,
            mangaData: try JSONEncoder().encode(storedManga), chapterData: try JSONEncoder().encode(chapter))
        let existing = library.books.first { $0.online?.identity == reference.identity }
        var book =
            existing
            ?? ComicBook(
                title: "\(manga.title) — \(chapter.displayTitle)", pages: [],
                sourceIdentity: "online:" + reference.identity)
        book.online = reference
        book.pages = pages.indices.map { "\($0).image" }
        book.currentPage = min(book.currentPage, pages.count - 1)
        try FileManager.default.createDirectory(
            at: library.root.appendingPathComponent(book.id.uuidString), withIntermediateDirectories: true)
        library.commit { snapshot in
            if let index = snapshot.books.firstIndex(where: { $0.id == book.id }) {
                snapshot.books[index] = book
            } else {
                snapshot.books.append(book)
            }
        }
        guard library.book(book.id) == book else { throw CocoaError(.fileWriteUnknown) }
        await RemotePageCache.shared.register(book: book, source: source, pages: pages, root: library.root)
        return book.id
    }

    func prepare(_ book: ComicBook, library: LibraryStore) async throws {
        guard let reference = book.online else { return }
        if await RemotePageCache.shared.isRegistered(book: book, root: library.root) { return }
        if book.pages.allSatisfy({
            FileManager.default.fileExists(
                atPath: library.root.appendingPathComponent(book.id.uuidString).appendingPathComponent($0).path)
        }) {
            return
        }
        let source = try await self.source(reference.sourceKey)
        let manga = try JSONDecoder().decode(AidokuRunner.Manga.self, from: reference.mangaData)
        let chapter = try JSONDecoder().decode(AidokuRunner.Chapter.self, from: reference.chapterData)
        _ = try await openChapter(source: source, manga: manga, chapter: chapter, library: library)
    }
}

extension AidokuRunner.Chapter {
    var displayTitle: String {
        var parts: [String] = []
        if let volumeNumber { parts.append("Vol. \(volumeNumber.formatted())") }
        if let chapterNumber { parts.append("Ch. \(chapterNumber.formatted())") }
        if let title, !title.isEmpty { parts.append(title) }
        return parts.isEmpty ? key : parts.joined(separator: " · ")
    }
}
