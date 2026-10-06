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
    public var version: Int = 1
    public var books: [ComicBook] = []
    public var collections: [String] = []
    public var aidokuBackupFile: String?
    public init() {}
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
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else { throw LibraryError.unsupportedVersion(snapshot.version) }
        guard Set(snapshot.books.map(\.id)).count == snapshot.books.count,
            snapshot.aidokuBackupFile.map(PageCatalog.isSafeRelativePath) ?? true,
            snapshot.books.allSatisfy({ book in
                !book.pages.isEmpty && book.currentPage >= 0 && book.currentPage < book.pages.count
                    && (book.pageOffset.map { $0.isFinite && (0...1).contains($0) } ?? true)
                    && book.pages.allSatisfy { PageCatalog.isSafeRelativePath($0) }
            })
        else { throw LibraryError.invalidPagePath }
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
