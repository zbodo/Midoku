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
    private weak var library: LibraryStore?
    let root: URL

    init(root: URL, library: LibraryStore? = nil) {
        self.root = root
        self.library = library
        do { service = try SourceService(root: root) } catch {
            service = nil
            errorMessage = error.localizedDescription
        }
        Task { if let service { snapshot = await service.state() } }
    }

    func source(_ key: String) async throws -> AidokuRunner.Source {
        guard let service else { throw SourceFailure.noSource(key) }
        library?.applyAidokuSourceSettings(key)
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
        library?.applyAidokuSourceSettings(entry.id)
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
        library.synchronizeManga(manga, source: source.key)
        let pages = try await source.getPageList(manga: manga, chapter: chapter)
        try Task.checkCancellation()
        guard !pages.isEmpty else { throw SourceFailure.noPages }
        guard pages.count <= 10_000 else { throw SourceFailure.tooLarge }
        var storedManga = manga
        library.applyAidokuMangaOverrides(to: &storedManga, source: source.key)
        storedManga.chapters = nil  // Avoid duplicating a full series chapter list in every library record.
        let reference = OnlineChapterReference(
            sourceKey: source.key, mangaKey: manga.key, chapterKey: chapter.key,
            mangaTitle: storedManga.title, chapterTitle: chapter.displayTitle, cover: storedManga.cover,
            mangaData: try JSONEncoder().encode(storedManga), chapterData: try JSONEncoder().encode(chapter))
        let existing = library.books.first { $0.online?.identity == reference.identity }
        var book =
            existing
            ?? ComicBook(
                title: "\(storedManga.title) — \(chapter.displayTitle)", pages: [],
                sourceIdentity: "online:" + reference.identity)
        book.online = reference
        book.pages = pages.indices.map { "\($0).image" }
        book.currentPage = min(book.currentPage, pages.count - 1)
        library.applyImportedHistory(to: &book)
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

    func refreshManga(_ record: LibraryManga, library: LibraryStore) async throws {
        let runtime = try await source(record.sourceKey)
        let initial = library.storedManga(source: record.sourceKey, key: record.mangaKey)
            ?? library.aidokuManga(source: record.sourceKey, key: record.mangaKey)
            ?? .init(sourceKey: record.sourceKey, key: record.mangaKey, title: record.title, cover: record.cover)
        var manga = try await runtime.getMangaUpdate(manga: initial, needsDetails: true, needsChapters: true)
        library.applyAidokuMangaOverrides(to: &manga, source: record.sourceKey)
        library.synchronizeManga(manga, source: record.sourceKey)
    }

    func continueManga(_ record: LibraryManga, library: LibraryStore, resumeLastOpened: Bool) async throws -> UUID? {
        if library.mangaRecord(source: record.sourceKey, key: record.mangaKey)?.chapters == nil {
            try await refreshManga(record, library: library)
        }
        guard let chapter = library.continuation(source: record.sourceKey, manga: record.mangaKey,
                                                resumeLastOpened: resumeLastOpened) else { return nil }
        if let book = library.books.first(where: {
            $0.online?.sourceKey == record.sourceKey && $0.online?.mangaKey == record.mangaKey
                && $0.online?.chapterKey == chapter.key
        }) {
            try await prepare(book, library: library)
            return book.id
        }
        guard let data = chapter.data, let manga = library.storedManga(source: record.sourceKey, key: record.mangaKey)
        else { throw SourceFailure.noPages }
        let runtime = try await source(record.sourceKey)
        let value = try JSONDecoder().decode(AidokuRunner.Chapter.self, from: data)
        return try await openChapter(source: runtime, manga: manga, chapter: value, library: library)
    }

    /// Repository and package failures are reported after the local backup has been saved.
    /// Existing installed sources are retained; custom/legacy sources remain in the backup.
    func restoreAidokuSources(_ backup: AidokuBackup) async -> [String] {
        guard !busy, let service else { return ["Sources are busy or unavailable. Retry source restoration later."] }
        busy = true
        defer { busy = false }
        var failures: [String] = []
        for raw in Set(backup.sourceLists ?? []).sorted() {
            do { try await service.addRepository(RepositoryAddress(raw)) }
            catch { failures.append("\(raw): \(error.localizedDescription)") }
        }
        snapshot = await service.state()
        let customKeys = Set((backup.sources ?? []).filter { $0.config != nil }.map(\.id))
        for key in backup.sourceKeys.sorted() {
            if customKeys.contains(key) {
                failures.append("\(key): Custom source configuration is preserved but not supported by the desktop runtime.")
                continue
            }
            guard SourceCatalog.validSourceKey(key) else {
                failures.append("\(key): This source identifier is not supported by the desktop runtime.")
                continue
            }
            library?.applyAidokuSourceSettings(key, force: true)
            if snapshot.installed.contains(where: { $0.id == key }) { continue }
            guard let repository = snapshot.repositories.first(where: { $0.catalog.sources.contains { $0.id == key } }),
                  let entry = repository.catalog.sources.first(where: { $0.id == key }) else {
                failures.append("\(key): Source not found in the available repositories. Its library data is preserved.")
                continue
            }
            do {
                try await service.install(entry, repository: repository.url)
                await RemotePageCache.shared.unregister(sourceKey: key)
                snapshot = await service.state()
            } catch { failures.append("\(key): \(error.localizedDescription)") }
        }
        return failures
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
