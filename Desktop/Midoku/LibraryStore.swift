import AidokuRunner
import AppKit
import MidokuCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    @Published var pendingAidokuBackup: AidokuBackupPreview?
    @Published private(set) var aidokuBackup: AidokuBackupState?
    private(set) var loadFailed = false
    let root: URL
    private let importer = ComicImporter()
    private var aidokuHistoryIndex: [[String]: AidokuBackupHistory] = [:]
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Midoku", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            snapshot = try LibraryPersistence.load(from: indexURL)
            if let file = snapshot.aidokuBackupFile {
                aidokuBackup = try AidokuBackupPersistence.load(from: self.root.appendingPathComponent(file))
                aidokuHistoryIndex = aidokuBackup?.backup.historyByIdentifier ?? [:]
            }
        } catch {
            loadFailed = true  // Never replace an unreadable library with an empty one.
            errorMessage = error.localizedDescription
        }
    }

    var books: [ComicBook] { snapshot.books }
    var shelfBooks: [ShelfBook] {
        snapshot.shelfBooks.map { book in
            var value = book
            if let manga = book.manga {
                value.downloadedCount = books.filter {
                    $0.online?.sourceKey == manga.sourceKey && $0.online?.mangaKey == manga.mangaKey && isDownloaded($0)
                }.count
            } else if let local = book.readingBook, isDownloaded(local) { value.downloadedCount = 1 }
            return value
        }
    }
    func isDownloaded(_ book: ComicBook) -> Bool {
        !book.pages.isEmpty && book.pages.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(book.id.uuidString).appendingPathComponent($0).path)
        }
    }
    func mangaRecord(source: String, key: String) -> LibraryManga? { snapshot.mangaRecord(source: source, key: key) }
    func storedManga(source: String, key: String) -> AidokuRunner.Manga? {
        guard let data = mangaRecord(source: source, key: key)?.mangaData else { return nil }
        return try? JSONDecoder().decode(AidokuRunner.Manga.self, from: data)
    }
    func shelfBook(_ id: UUID) -> ShelfBook? { shelfBooks.first { $0.id == id } }
    func updateShelfBook(_ id: UUID, _ update: (inout ShelfBook) -> Void) {
        commit { $0.updateShelfBook(id, update) }
    }
    func mangaOnShelf(source: String, key: String) -> LibraryManga? {
        snapshot.mangaBooks.first { $0.sourceKey == source && $0.mangaKey == key }
    }
    func addManga(source: String, key: String, title: String, cover: String?) {
        commit { snapshot in
            if let index = snapshot.mangaBooks.firstIndex(where: { $0.sourceKey == source && $0.mangaKey == key }) {
                snapshot.mangaBooks[index].cover = cover
            } else {
                var record = snapshot.mangaRecord(source: source, key: key)
                    ?? LibraryManga(sourceKey: source, mangaKey: key, title: title, cover: cover)
                record.cover = cover
                snapshot.retainedManga?.removeAll { $0.sourceKey == source && $0.mangaKey == key }
                snapshot.mangaBooks.append(record)
            }
        }
    }

    /// Store a complete catalog independently of fetched pages and preserve chapter progress on refresh.
    func synchronizeManga(_ manga: AidokuRunner.Manga, source: String) {
        var record = mangaRecord(source: source, key: manga.key)
            ?? LibraryManga(sourceKey: source, mangaKey: manga.key, title: manga.title, cover: manga.cover)
        record.cover = manga.cover; record.authors = (manga.authors ?? []).joined(separator: ", ")
        record.publishingCompleted = manga.status == .completed
        if let chapters = manga.chapters {
            let incoming = chapters.map { chapter in
                let book = books.first { $0.online?.sourceKey == source && $0.online?.mangaKey == manga.key
                    && $0.online?.chapterKey == chapter.key }
                let history = aidokuHistory(source: source, manga: manga.key, chapter: chapter.key)
                return LibraryChapter(key: chapter.key, title: chapter.displayTitle, locked: chapter.locked,
                    data: try? JSONEncoder().encode(chapter), isRead: book?.isRead ?? history?.completed ?? false,
                    lastReadAt: book?.lastReadAt ?? history?.dateRead, currentPage: book?.currentPage,
                    pageOffset: book?.pageOffset)
            }
            record.refreshCatalog(incoming)
            record.latestChapterAt = chapters.compactMap(\.dateUploaded).max()
        }
        record.mangaData = try? JSONEncoder().encode(manga)
        commit { snapshot in
            if snapshot.mangaRecord(source: source, key: manga.key) == nil {
                var retained = snapshot.retainedManga ?? []; retained.append(record); snapshot.retainedManga = retained
            } else {
                snapshot.updateMangaRecord(source: source, key: manga.key) { $0 = record }
            }
        }
    }

    func mangaOpened(_ manga: LibraryManga) {
        commit { snapshot in
            snapshot.updateMangaRecord(source: manga.sourceKey, key: manga.mangaKey) {
                $0.lastOpenedAt = Date(); $0.hasUpdates = false
            }
        }
    }

    func continuation(source: String, manga: String, resumeLastOpened: Bool) -> LibraryChapter? {
        guard let record = mangaRecord(source: source, key: manga), let catalog = record.chapters else { return nil }
        let downloaded = Set(books.filter { $0.online?.sourceKey == source && $0.online?.mangaKey == manga
            && isDownloaded($0) }.compactMap { $0.online?.chapterKey })
        // Sources return newest first. Reading starts with the oldest unread chapter.
        return ChapterContinuation.next(in: Array(catalog.reversed()), downloadedKeys: downloaded,
                                        resumeLastOpened: resumeLastOpened)
    }

    func markChapters(_ ids: Set<UUID>, read: Bool) { commit { $0.markChapters(ids, read: read) } }
    func setChapterRead(source: String, manga: String, chapter: String, read: Bool) {
        commit { snapshot in
            snapshot.updateMangaRecord(source: source, key: manga) { record in
                record.updateChapter(chapter) {
                    $0.isRead = read
                    $0.lastReadAt = read ? Date() : nil
                    $0.currentPage = read ? nil : 0
                    $0.pageOffset = nil
                }
            }
            for index in snapshot.books.indices where snapshot.books[index].online?.sourceKey == source
                && snapshot.books[index].online?.mangaKey == manga && snapshot.books[index].online?.chapterKey == chapter {
                snapshot.books[index].isRead = read; snapshot.books[index].lastReadAt = read ? Date() : nil
                snapshot.books[index].currentPage = read ? max(0, snapshot.books[index].pages.count - 1) : 0
                snapshot.books[index].pageOffset = nil
            }
        }
    }

    func pageURL(for book: ShelfBook, at index: Int) -> URL? {
        guard let chapter = book.readingBook else { return nil }
        return pageURL(for: chapter, at: index)
    }
    func book(_ id: UUID) -> ComicBook? { books.first { $0.id == id } }
    func pageURL(for book: ComicBook, at index: Int) -> URL? {
        guard book.pages.indices.contains(index) else { return nil }
        return root.appendingPathComponent(book.id.uuidString, isDirectory: true).appendingPathComponent(
            book.pages[index])
    }

    func commit(_ update: (inout LibrarySnapshot) -> Void) {
        guard !loadFailed else {
            errorMessage =
                "The library could not be loaded. Its files have been preserved. Restart after repairing or restoring library.json."
            return
        }
        var next = snapshot
        update(&next)
        do {
            try LibraryPersistence.save(next, to: indexURL)
            snapshot = next
        } catch { errorMessage = error.localizedDescription }
    }

    func updateBook(_ id: UUID, _ update: (inout ComicBook) -> Void) {
        commit { snapshot in
            guard let index = snapshot.books.firstIndex(where: { $0.id == id }) else { return }
            update(&snapshot.books[index])
            let book = snapshot.books[index]
            if let reference = book.online {
                snapshot.updateMangaRecord(source: reference.sourceKey, key: reference.mangaKey) { record in
                    if record.chapterRecord(reference.chapterKey) == nil {
                        var history = record.chapterHistory ?? []
                        history.append(LibraryChapter(key: reference.chapterKey, title: reference.chapterTitle,
                                                      data: reference.chapterData))
                        record.chapterHistory = history
                    }
                    record.updateChapter(reference.chapterKey) {
                        $0.isRead = book.isRead
                        $0.lastReadAt = book.lastReadAt
                        $0.currentPage = book.currentPage
                        $0.pageOffset = book.pageOffset
                    }
                }
            }
        }
    }

    func saveProgress(_ id: UUID, page: Int, finished: Bool = false, offset: Double = 0) {
        updateBook(id) {
            $0.currentPage = min(max(0, page), max(0, $0.pages.count - 1))
            $0.pageOffset = min(1, max(0, offset))
            $0.lastReadAt = Date()
            $0.isRead = $0.isRead || finished
        }
    }

    func remove(_ ids: Set<UUID>, deleteDownloads: Bool = false) {
        let previous = snapshot
        let targets = shelfBooks.filter { ids.contains($0.id) }
        commit { _ = $0.removeShelfBooks(ids) }
        guard snapshot != previous, targets.allSatisfy({ shelfBook($0.id) == nil }) else { return }
        if deleteDownloads { deleteStoredPages(for: targets) }
    }

    func deleteDownloads(_ ids: Set<UUID>) {
        // Local files are the only copy held by the reader; this action applies to online chapters.
        deleteStoredPages(for: shelfBooks.filter { ids.contains($0.id) && $0.manga != nil })
    }

    private func deleteStoredPages(for targets: [ShelfBook]) {
        let identities = Set(targets.compactMap { $0.manga?.identity })
        let localIDs = Set(targets.filter { $0.manga == nil }.map(\.id))
        let chapters = books.filter { book in
            book.online.map { identities.contains(LibraryManga.identity(source: $0.sourceKey, manga: $0.mangaKey)) }
                ?? localIDs.contains(book.id)
        }
        Task {
            for book in chapters {
                await RemotePageCache.shared.forget(book: book, root: root)
                let directory = root.appendingPathComponent(book.id.uuidString)
                do {
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                } catch { errorMessage = error.localizedDescription }
            }
            // Publish updated downloaded badges without changing reading history.
            objectWillChange.send()
        }
    }

    func importPanel() {
        guard !isImporting, !loadFailed else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Import comic archives, PDFs, or folders of images")
        panel.allowedContentTypes = [.folder, .image, .pdf, .zip, UTType(filenameExtension: "cbz") ?? .data,
                                     UTType(filenameExtension: "aib") ?? .data, .json, .propertyList]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importFiles(_ urls: [URL]) {
        guard !isImporting, !loadFailed else { return }
        if let backupURL = urls.first(where: { ["aib", "json", "plist"].contains($0.pathExtension.lowercased()) }) {
            guard urls.count == 1 else {
                errorMessage = "Import an Aidoku backup separately from comic files."
                return
            }
            previewAidokuBackup(backupURL)
            return
        }
        isImporting = true
        Task {
            defer { isImporting = false }
            var failures: [String] = []
            for url in urls {
                let identity = url.standardizedFileURL.resolvingSymlinksInPath().path
                if let existing = books.first(where: { $0.sourceIdentity == identity && isDownloaded($0) }) {
                    updateBook(existing.id) { $0.isOnShelf = true }
                    continue
                }
                do {
                    let book = try await importer.importBook(from: url, into: root)
                    commit { $0.books.append(book) }
                    if self.book(book.id) == nil {
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(book.id.uuidString))
                    }
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    func aidokuImportPanel() {
        guard !isImporting, !loadFailed else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "aib") ?? .data, .json, .propertyList]
        panel.message = "Choose a backup exported by Aidoku v0.9"
        if panel.runModal() == .OK, let url = panel.url { previewAidokuBackup(url) }
    }

    private func previewAidokuBackup(_ url: URL) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                pendingAidokuBackup = try await Task.detached { try AidokuBackupPreview.load(url) }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Write the entire library atomically before applying preferences or fetching sources.
    /// A copy of the previous library remains available even when no library file existed yet.
    func restoreAidokuBackup(_ preview: AidokuBackupPreview, settings: Bool) throws {
        guard !loadFailed, !isImporting else { throw CocoaError(.fileWriteUnknown) }
        var next = snapshot
        let archive = aidokuBackup?.merging(
            backup: preview.backup, data: preview.data, filename: preview.filename,
            restoreSourceSettings: settings)
            ?? AidokuBackupState(backup: preview.backup, data: preview.data,
                                 filename: preview.filename, restoreSourceSettings: settings)
        for title in preview.backup.categoryTitles where !next.collections.contains(title) {
            next.collections.append(title)
        }
        let histories = archive.backup.historyByIdentifier
        for index in next.books.indices {
            if let reference = next.books[index].online {
                applyHistory(to: &next.books[index], history: histories[[reference.sourceKey, reference.mangaKey, reference.chapterKey]])
            }
        }
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LibraryPersistence.save(snapshot, to: directory.appendingPathComponent("before-aidoku-\(UUID()).json"))
        let archiveDirectory = root.appendingPathComponent("AidokuBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archiveFile = "AidokuBackups/\(UUID()).json"
        let archiveURL = root.appendingPathComponent(archiveFile)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: archiveURL) } }
        try AidokuBackupPersistence.save(archive, to: archiveURL)
        next.aidokuBackupFile = archiveFile
        try LibraryPersistence.save(next, to: indexURL)
        committed = true
        snapshot = next
        aidokuBackup = archive
        aidokuHistoryIndex = histories
        if settings {
            for (key, value) in preview.backup.desktopSettings {
                UserDefaults.standard.set(value.rawValue, forKey: key)
            }
        }
    }

    func aidokuHistory(source: String, manga: String, chapter: String) -> AidokuBackupHistory? {
        aidokuHistoryIndex[[source, manga, chapter]]
    }

    func applyImportedHistory(to book: inout ComicBook) {
        guard let reference = book.online else { return }
        if let chapter = mangaRecord(source: reference.sourceKey, key: reference.mangaKey)?.chapterRecord(reference.chapterKey) {
            book.isRead = chapter.isRead; book.lastReadAt = chapter.lastReadAt
            book.currentPage = min(max(0, chapter.currentPage ?? book.currentPage), max(0, book.pages.count - 1))
            book.pageOffset = chapter.pageOffset
            return
        }
        applyHistory(to: &book, history: aidokuHistory(source: reference.sourceKey, manga: reference.mangaKey,
                                                    chapter: reference.chapterKey))
    }

    private func applyHistory(to book: inout ComicBook, history: AidokuBackupHistory?) {
        guard let history,
            book.lastReadAt == nil || history.dateRead > book.lastReadAt!
        else { return }
        book.currentPage = history.pageIndex(pageCount: book.pages.count)
        book.isRead = history.completed
        book.lastReadAt = history.dateRead
        book.pageOffset = nil // Aidoku v0.9 exports page progress, but no within-page scroll offset.
    }

    func applyAidokuSourceSettings(_ key: String, force: Bool = false) {
        guard let state = aidokuBackup, state.restoreSourceSettings else { return }
        let revision = state.originals.last?.id.uuidString ?? ""
        let marker = "midoku.aidoku.settingsRevision." + key
        guard force || UserDefaults.standard.string(forKey: marker) != revision else { return }
        for (setting, value) in state.backup.sourceSettings(for: key) {
            UserDefaults.standard.set(value.rawValue, forKey: setting)
        }
        UserDefaults.standard.set(revision, forKey: marker)
    }
}
