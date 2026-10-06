import Foundation

public struct ComicBook: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var pages: [String]
    public var online: OnlineChapterReference?
    public let sourceIdentity: String
    public let importedAt: Date
    public var lastReadAt: Date?
    public var currentPage: Int
    public var pageOffset: Double?
    public var isRead: Bool
    public var isFavorite: Bool
    public var collection: String?
    public var isOnShelf: Bool?
    public var categoryMemberships: [String]?
    public var categories: [String] {
        get { categoryMemberships ?? collection.map { [$0] } ?? [] }
        set { categoryMemberships = Array(Set(newValue)).sorted(); collection = categoryMemberships?.first }
    }

    public init(id: UUID = UUID(), title: String, pages: [String], sourceIdentity: String) {
        self.id = id
        self.title = title
        self.pages = pages
        self.sourceIdentity = sourceIdentity
        importedAt = Date()
        currentPage = 0
        isRead = false
        isFavorite = false
    }

    public var progress: Double {
        isRead ? 1 : Double(currentPage) / Double(max(1, pages.count))
    }
}

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var version: Int = 2
    public var books: [ComicBook] = []
    public var collections: [String] = []
    public var mangaBooks: [LibraryManga] = []
    public var retainedManga: [LibraryManga]?
    public var aidokuBackupFile: String?
    public init() {}

    private enum CodingKeys: String, CodingKey { case version, books, collections, mangaBooks, retainedManga, aidokuBackupFile }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        books = try values.decode([ComicBook].self, forKey: .books)
        collections = try values.decode([String].self, forKey: .collections)
        mangaBooks = try values.decodeIfPresent([LibraryManga].self, forKey: .mangaBooks) ?? []
        retainedManga = try values.decodeIfPresent([LibraryManga].self, forKey: .retainedManga)
        aidokuBackupFile = try values.decodeIfPresent(String.self, forKey: .aidokuBackupFile)
    }
}

public enum LibraryError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case invalidPagePath

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unsupported library format: \(version)."
        case .invalidPagePath: "The library contains an invalid page path."
        }
    }
}

public enum LibraryPersistence {
    public static func load(from url: URL) throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return LibrarySnapshot() }
        var snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: url))
        guard (1...2).contains(snapshot.version) else { throw LibraryError.unsupportedVersion(snapshot.version) }
        let records = snapshot.mangaBooks + (snapshot.retainedManga ?? [])
        guard Set(records.map(\.identity)).count == records.count,
            records.allSatisfy({ record in
                let chapters = record.chapters ?? []
                return Set(chapters.map(\.key)).count == chapters.count
                    && (chapters + (record.chapterHistory ?? [])).allSatisfy {
                        ($0.currentPage.map { $0 >= 0 } ?? true)
                            && ($0.pageOffset.map { $0.isFinite && (0...1).contains($0) } ?? true)
                    }
            }),
            Set(snapshot.books.map(\.id)).count == snapshot.books.count,
            Set(snapshot.mangaBooks.map(\.id)).count == snapshot.mangaBooks.count,
            Set(snapshot.mangaBooks.map(\.identity)).count == snapshot.mangaBooks.count,
            Set(snapshot.books.filter { $0.online == nil }.map(\.id)).isDisjoint(with: snapshot.mangaBooks.map(\.id)),
            snapshot.aidokuBackupFile.map(PageCatalog.isSafeRelativePath) ?? true,
            snapshot.books.allSatisfy({ book in
                !book.pages.isEmpty && book.currentPage >= 0 && book.currentPage < book.pages.count
                    && (book.pageOffset.map { $0.isFinite && (0...1).contains($0) } ?? true)
                    && book.pages.allSatisfy { PageCatalog.isSafeRelativePath($0) }
            })
        else { throw LibraryError.invalidPagePath }
        snapshot.migrateChapterShelf()
        return snapshot
    }

    public static func save(_ snapshot: LibrarySnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}

public enum PageCatalog {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "heic", "avif", "tif", "tiff", "bmp",
    ]

    public static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == ".." || $0 == "." || $0.isEmpty
            })
    }

    public static func isImage(_ path: String) -> Bool {
        isSafeRelativePath(path)
            && !path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" })
            && imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    public static func sorted(_ paths: [String]) -> [String] {
        paths.filter(isImage).sorted {
            $0.compare($1, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                == .orderedAscending
        }
    }
}


/// Chapter metadata is stored even before pages are fetched. Progress remains chapter scoped.
public struct LibraryChapter: Identifiable, Codable, Equatable, Sendable {
    public var id: String { key }
    public let key: String
    public var title: String
    public var locked: Bool
    public var data: Data?
    public var isRead: Bool
    public var lastReadAt: Date?
    public var currentPage: Int?
    public var pageOffset: Double?

    public init(key: String, title: String, locked: Bool = false, data: Data? = nil, isRead: Bool = false,
                lastReadAt: Date? = nil, currentPage: Int? = nil, pageOffset: Double? = nil) {
        self.key = key; self.title = title; self.locked = locked; self.data = data
        self.isRead = isRead; self.lastReadAt = lastReadAt; self.currentPage = currentPage; self.pageOffset = pageOffset
    }
}

public struct LibraryManga: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceKey: String
    public let mangaKey: String
    public var title: String
    public var cover: String?
    public var importedAt: Date
    public var isFavorite = false
    // Retained to decode older files. Shelf completion is now derived from chapters.
    public var isRead = false
    public var collection: String?
    public var categoryMemberships: [String]?
    public var categories: [String] {
        get { categoryMemberships ?? collection.map { [$0] } ?? [] }
        set { categoryMemberships = Array(Set(newValue)).sorted(); collection = categoryMemberships?.first }
    }
    // A nil catalog means only locally opened chapters are known; never assume the series is complete.
    public var chapters: [LibraryChapter]?
    public var chapterHistory: [LibraryChapter]?
    public var mangaData: Data?
    public var authors: String?
    public var publishingCompleted: Bool?
    public var lastOpenedAt: Date?
    public var lastUpdatedAt: Date?
    public var latestChapterAt: Date?
    public var hasUpdates: Bool?

    public init(id: UUID = UUID(), sourceKey: String, mangaKey: String, title: String, cover: String?) {
        self.id = id; self.sourceKey = sourceKey; self.mangaKey = mangaKey
        self.title = title; self.cover = cover; importedAt = Date()
    }
    /// Refresh source metadata without overwriting read/unread edits or page progress.
    public mutating func refreshCatalog(_ incoming: [LibraryChapter], at date: Date = Date()) {
        let oldKeys = chapters.map { Set($0.map(\.key)) }
        let old = Dictionary(((chapters ?? []) + (chapterHistory ?? [])).map { ($0.key, $0) },
                             uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        chapters = incoming.filter { seen.insert($0.key).inserted }.map { metadata in
            var state = old[metadata.key] ?? metadata
            state.title = metadata.title; state.locked = metadata.locked; state.data = metadata.data
            return state
        }
        let keys = Set(incoming.map(\.key))
        chapterHistory = old.values.filter { !keys.contains($0.key) }.sorted { $0.key < $1.key }
        if oldKeys == nil { lastUpdatedAt = date }
        if let oldKeys, !keys.subtracting(oldKeys).isEmpty { lastUpdatedAt = date; hasUpdates = true }
    }

    public func chapterRecord(_ key: String) -> LibraryChapter? {
        ((chapters ?? []) + (chapterHistory ?? [])).first { $0.key == key }
    }

    public mutating func updateChapter(_ key: String, _ update: (inout LibraryChapter) -> Void) {
        if let index = chapters?.firstIndex(where: { $0.key == key }) {
            var chapter = chapters![index]
            update(&chapter)
            chapters?[index] = chapter
        } else if let index = chapterHistory?.firstIndex(where: { $0.key == key }) {
            var chapter = chapterHistory![index]
            update(&chapter)
            chapterHistory?[index] = chapter
        }
    }

    public var identity: String { Self.identity(source: sourceKey, manga: mangaKey) }
    public static func identity(source: String, manga: String) -> String {
        [source, manga].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public struct ShelfBook: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var isFavorite: Bool
    public var isRead: Bool
    public var categories: [String]
    public var collection: String? {
        get { categories.first }
        set { categories = newValue.map { [$0] } ?? [] }
    }
    public let importedAt: Date
    public let manga: LibraryManga?
    public let readingBook: ComicBook?
    public let chapterCount: Int
    public let unreadCount: Int
    public var downloadedCount = 0
    public let lastReadAt: Date?
    public var currentPage: Int { readingBook?.currentPage ?? 0 }
    public var progress: Double { readingBook?.progress ?? 0 }
    public var pages: [String] { readingBook?.pages ?? [] }

    public init(local: ComicBook) {
        id = local.id; title = local.title; isFavorite = local.isFavorite; isRead = local.isRead
        categories = local.categories; importedAt = local.importedAt
        manga = nil; readingBook = local; chapterCount = 1; unreadCount = local.isRead ? 0 : 1
        lastReadAt = local.lastReadAt
    }
    public init(manga: LibraryManga, chapters: [ComicBook]) {
        id = manga.id; title = manga.title; isFavorite = manga.isFavorite
        categories = manga.categories; importedAt = manga.importedAt; self.manga = manga
        let records = manga.chapters ?? chapters.compactMap { book in
            book.online.map { LibraryChapter(key: $0.chapterKey, title: $0.chapterTitle, isRead: book.isRead,
                                             lastReadAt: book.lastReadAt) }
        }
        chapterCount = records.count; unreadCount = records.filter { !$0.isRead }.count
        isRead = manga.chapters != nil && chapterCount > 0 && unreadCount == 0
        lastReadAt = records.compactMap(\.lastReadAt).max() ?? chapters.compactMap(\.lastReadAt).max()
        readingBook = chapters.filter { $0.lastReadAt != nil }.max {
            ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast)
        } ?? chapters.first
    }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case title, lastRead, lastOpened, lastUpdated, dateAdded, latestChapter, unreadChapters, totalChapters
}
public enum LibraryPin: String, CaseIterable, Sendable { case none, unread, updatedChapters }
public enum LibraryFilterState: String, CaseIterable, Sendable { case any, include, exclude }

public struct LibraryQuery: Sendable {
    public var text = ""
    public var category: String?
    public var sort: LibrarySort = .lastOpened
    public var ascending = false
    public var pin: LibraryPin = .none
    public var unread: LibraryFilterState = .any
    public var downloaded: LibraryFilterState = .any
    public var started: LibraryFilterState = .any
    public var completed: LibraryFilterState = .any
    public var source: String?
    public init() {}

    public func apply(to books: [ShelfBook]) -> [ShelfBook] {
        func accepts(_ state: LibraryFilterState, _ value: Bool) -> Bool {
            state == .any || (state == .include ? value : !value)
        }
        func pinned(_ book: ShelfBook) -> Bool {
            switch pin {
            case .none: false
            case .unread: book.unreadCount > 0
            case .updatedChapters: book.manga?.hasUpdates == true
            }
        }
        func date(_ book: ShelfBook) -> Date {
            switch sort {
            case .lastRead: book.lastReadAt ?? .distantPast
            case .lastOpened: book.manga?.lastOpenedAt ?? book.lastReadAt ?? .distantPast
            case .lastUpdated: book.manga?.lastUpdatedAt ?? .distantPast
            case .latestChapter: book.manga?.latestChapterAt ?? .distantPast
            default: book.importedAt
            }
        }
        return books.filter { book in
            (category == nil || (category == "" ? book.categories.isEmpty : book.categories.contains(category!)))
            && (source == nil || book.manga?.sourceKey == source)
            && (text.isEmpty || book.title.localizedCaseInsensitiveContains(text)
                || (book.manga?.authors?.localizedCaseInsensitiveContains(text) ?? false))
            && accepts(unread, book.unreadCount > 0)
            && accepts(downloaded, book.downloadedCount > 0)
            && accepts(started, book.lastReadAt != nil)
            && accepts(completed, book.manga?.publishingCompleted ?? book.isRead)
        }.sorted { lhs, rhs in
            if pinned(lhs) != pinned(rhs) { return pinned(lhs) }
            if sort == .title {
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
            } else if sort == .unreadChapters || sort == .totalChapters {
                let left = sort == .unreadChapters ? lhs.unreadCount : lhs.chapterCount
                let right = sort == .unreadChapters ? rhs.unreadCount : rhs.chapterCount
                if left != right { return ascending ? left < right : left > right }
            } else if date(lhs) != date(rhs) {
                return ascending ? date(lhs) < date(rhs) : date(lhs) > date(rhs)
            }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }
}

/// Match Aidoku: resume the most recently read unfinished chapter, then the first unread in reading order.
public enum ChapterContinuation {
    public static func next(in chapters: [LibraryChapter], downloadedKeys: Set<String> = [],
                            resumeLastOpened: Bool = false) -> LibraryChapter? {
        let available = chapters.filter { !$0.locked || downloadedKeys.contains($0.key) }
        if let recent = available.filter({ $0.lastReadAt != nil && (resumeLastOpened || !$0.isRead) })
            .max(by: { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }) { return recent }
        return available.first { !$0.isRead }
    }
}

extension LibrarySnapshot {
    public func mangaRecord(source: String, key: String) -> LibraryManga? {
        (mangaBooks + (retainedManga ?? [])).first { $0.sourceKey == source && $0.mangaKey == key }
    }

    public mutating func updateMangaRecord(source: String, key: String, _ update: (inout LibraryManga) -> Void) {
        if let index = mangaBooks.firstIndex(where: { $0.sourceKey == source && $0.mangaKey == key }) {
            update(&mangaBooks[index])
        } else if let index = retainedManga?.firstIndex(where: { $0.sourceKey == source && $0.mangaKey == key }) {
            var record = retainedManga![index]
            update(&record)
            retainedManga?[index] = record
        }
    }

    public mutating func migrateChapterShelf() {
        guard version == 1 else { return }
        var known = Set(mangaBooks.map(\.identity))
        let groups = Dictionary(grouping: books.filter { $0.online != nil }) {
            LibraryManga.identity(source: $0.online!.sourceKey, manga: $0.online!.mangaKey)
        }
        for book in books {
            guard let reference = book.online else { continue }
            let key = LibraryManga.identity(source: reference.sourceKey, manga: reference.mangaKey)
            guard known.insert(key).inserted, let chapters = groups[key] else { continue }
            var manga = LibraryManga(id: book.id, sourceKey: reference.sourceKey, mangaKey: reference.mangaKey,
                                     title: reference.mangaTitle, cover: reference.cover)
            manga.importedAt = chapters.map(\.importedAt).min() ?? book.importedAt
            manga.isFavorite = chapters.contains { $0.isFavorite }
            manga.categories = chapters.flatMap(\.categories)
            mangaBooks.append(manga)
        }
        version = 2
    }

    public var shelfBooks: [ShelfBook] {
        let groups = Dictionary(grouping: books.filter { $0.online != nil }) {
            LibraryManga.identity(source: $0.online!.sourceKey, manga: $0.online!.mangaKey)
        }
        return books.filter { $0.online == nil && $0.isOnShelf != false }.map(ShelfBook.init(local:))
            + mangaBooks.map { ShelfBook(manga: $0, chapters: groups[$0.identity] ?? []) }
    }

    public mutating func updateShelfBook(_ id: UUID, _ update: (inout ShelfBook) -> Void) {
        guard var value = shelfBooks.first(where: { $0.id == id }) else { return }
        let originalRead = value.isRead
        update(&value)
        if let index = mangaBooks.firstIndex(where: { $0.id == id }) {
            mangaBooks[index].title = value.title; mangaBooks[index].isFavorite = value.isFavorite
            mangaBooks[index].categories = value.categories
            if originalRead != value.isRead { markChapters([id], read: value.isRead) }
        } else if let index = books.firstIndex(where: { $0.id == id && $0.online == nil }) {
            books[index].title = value.title; books[index].isFavorite = value.isFavorite
            books[index].isRead = value.isRead; books[index].categories = value.categories
        }
    }

    public mutating func markChapters(_ ids: Set<UUID>, read: Bool, date: Date = Date()) {
        let identities = Set(mangaBooks.filter { ids.contains($0.id) }.map(\.identity))
        for index in mangaBooks.indices where ids.contains(mangaBooks[index].id) {
            let keys = ((mangaBooks[index].chapters ?? []) + (mangaBooks[index].chapterHistory ?? [])).map(\.key)
            for key in keys {
                mangaBooks[index].updateChapter(key) {
                    $0.isRead = read
                    $0.lastReadAt = read ? date : nil
                    $0.currentPage = read ? nil : 0
                    $0.pageOffset = nil
                }
            }
        }
        for index in books.indices {
            let book = books[index]
            let matches = book.online.map { identities.contains(LibraryManga.identity(source: $0.sourceKey, manga: $0.mangaKey)) }
                ?? ids.contains(book.id)
            guard matches else { continue }
            books[index].isRead = read; books[index].lastReadAt = read ? date : nil
            books[index].currentPage = read ? max(0, book.pages.count - 1) : 0
            books[index].pageOffset = nil
        }
    }

    /// Remove membership only. Chapter history and page files remain available independently.
    public mutating func removeShelfBooks(_ ids: Set<UUID>) -> Set<UUID> {
        for index in books.indices where books[index].online == nil && ids.contains(books[index].id) {
            books[index].isOnShelf = false
        }
        var retained = retainedManga ?? []
        for manga in mangaBooks where ids.contains(manga.id) {
            retained.removeAll { $0.identity == manga.identity }
            retained.append(manga)
        }
        retainedManga = retained.isEmpty ? nil : retained
        mangaBooks.removeAll { ids.contains($0.id) }
        return []
    }
}
