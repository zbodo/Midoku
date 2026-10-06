import Foundation

public struct RepositoryAddress: Hashable, Codable, Sendable {
    public let url: URL

    public init(_ input: String) throws {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = URLComponents(string: raw), link.scheme == "aidoku" {
            guard link.host == "add-source-list", let value = link.queryItems?.first(where: { $0.name == "url" })?.value
            else {
                throw RepositoryError.invalidURL
            }
            raw = value
        }
        guard var components = URLComponents(string: raw),
            ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
            components.host != nil, components.user == nil, components.password == nil
        else { throw RepositoryError.invalidURL }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        if !components.path.lowercased().hasSuffix(".json") {
            if !components.path.hasSuffix("/") { components.path += "/" }
            components.path += "index.min.json"
        }
        guard let url = components.url else { throw RepositoryError.invalidURL }
        self.url = url
    }
}

public struct SourceCatalogEntry: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let version: Int
    public let languages: [String]
    public let contentRating: Int?
    public let downloadURL: String
    public let iconURL: String?
    public let sha256: String?

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        version = try values.decode(Int.self, forKey: .version)
        languages = try values.decodeIfPresent([String].self, forKey: .languages) ?? []
        contentRating = try values.decodeIfPresent(Int.self, forKey: .contentRating)
        downloadURL = try values.decode(String.self, forKey: .downloadURL)
        iconURL = try values.decodeIfPresent(String.self, forKey: .iconURL)
        sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
    }

    public func packageURL(relativeTo repository: URL) throws -> URL {
        guard let url = URL(string: downloadURL, relativeTo: repository)?.absoluteURL,
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
            url.user == nil, url.password == nil
        else { throw RepositoryError.invalidURL }
        return url
    }
}

public struct SourceCatalog: Codable, Equatable, Sendable {
    public let name: String
    public let sources: [SourceCatalogEntry]
    public let feedbackURL: String?

    public static func decode(_ data: Data) throws -> Self {
        // The array-shaped 0.6 index and `lang/file/nsfw` source entries are
        // intentionally not accepted. This client supports the modern ABI only.
        guard let catalog = try? JSONDecoder().decode(Self.self, from: data) else {
            throw RepositoryError.unsupportedFormat
        }
        guard !catalog.name.isEmpty, Set(catalog.sources.map(\.id)).count == catalog.sources.count,
            catalog.sources.allSatisfy({ validSourceKey($0.id) && $0.version > 0 && !$0.name.isEmpty })
        else {
            throw RepositoryError.invalidCatalog
        }
        return catalog
    }

    public static func validSourceKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 200 && key != "." && key != ".."
            && key.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
                    .contains($0)
            }
    }
}

public enum RepositoryError: Error, LocalizedError {
    case invalidURL, unsupportedFormat, invalidCatalog
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter an HTTP(S) source repository index URL or an Aidoku add-source-list link."
        case .unsupportedFormat:
            "This repository does not use the modern Aidoku source format. Legacy 0.6 indexes are not supported."
        case .invalidCatalog: "The repository contains invalid or duplicate source identifiers."
        }
    }
}

public struct OnlineChapterReference: Codable, Equatable, Sendable {
    public let sourceKey: String
    public let mangaKey: String
    public let chapterKey: String
    public let mangaTitle: String
    public let chapterTitle: String
    public let cover: String?
    public let mangaData: Data
    public let chapterData: Data

    public init(
        sourceKey: String, mangaKey: String, chapterKey: String, mangaTitle: String,
        chapterTitle: String, cover: String?, mangaData: Data, chapterData: Data
    ) {
        self.sourceKey = sourceKey
        self.mangaKey = mangaKey
        self.chapterKey = chapterKey
        self.mangaTitle = mangaTitle
        self.chapterTitle = chapterTitle
        self.cover = cover
        self.mangaData = mangaData
        self.chapterData = chapterData
    }
    public var identity: String {
        // Length-prefixed keys cannot collide when manga/chapter keys include separators.
        [sourceKey, mangaKey, chapterKey].map { "\($0.utf8.count):\($0)" }.joined()
    }
}
