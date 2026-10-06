import Foundation

// Aidoku v0.9 backup schema. Names and optional fields match upstream exports.
// https://github.com/Aidoku/Aidoku/tree/v0.9/Aidoku/Core/Backup/Models

public struct AidokuBackupManga: Codable, Hashable, Sendable {
    public var id: String
    public var sourceId: String
    public var title: String
    public var author: String?
    public var artist: String?
    public var desc: String?
    public var tags: [String]?
    public var cover: String?
    public var url: String?
    public var status: Int
    public var nsfw: Int
    public var viewer: Int
    public var neverUpdate: Bool?
    public var nextUpdateTime: Date?
    public var chapterFlags: Int?
    public var langFilter: String?
    public var scanlatorFilter: [String]?
    public var editedKeys: Int?
}

public struct AidokuBackupLibraryManga: Codable, Hashable, Sendable {
    public var lastOpened: Date
    public var lastUpdated: Date
    public var lastUpdatedChapters: Date?
    public var lastChapter: Date?
    public var lastRead: Date?
    public var dateAdded: Date
    public var categories: [String]?
    public var mangaId: String
    public var sourceId: String
}

public struct AidokuBackupHistory: Codable, Hashable, Sendable {
    public var dateRead: Date
    public var sourceId: String
    public var chapterId: String
    public var mangaId: String
    public var progress: Int?
    public var total: Int?
    public var completed: Bool
}

public struct AidokuBackupChapter: Codable, Hashable, Sendable {
    public var sourceId: String
    public var mangaId: String
    public var id: String
    public var title: String?
    public var scanlator: String?
    public var url: String?
    public var lang: String
    public var chapter: Float?
    public var volume: Float?
    public var dateUploaded: Date?
    public var thumbnail: String?
    public var locked: Bool?
    public var sourceOrder: Int
}

public struct AidokuBackupTrackItem: Codable, Hashable, Sendable {
    public var id: String
    public var trackerId: String
    public var mangaId: String
    public var sourceId: String
    public var title: String?
    public var chapterOffset: Int?
}

public struct AidokuBackupReadingSession: Codable, Hashable, Sendable {
    public var pagesRead: Int
    public var startDate: Date
    public var endDate: Date
    public var sourceId: String
    public var mangaId: String
    public var chapterId: String
}

public struct AidokuBackupVocabEntry: Codable, Hashable, Sendable {
    public var sourceId: String
    public var mangaId: String
    public var chapterId: String
    public var word: String
    public var reading: String?
    public var sentence: String?
    public var clozeOffset: Int?
    public var clozeText: String?
    public var page: Int
    public var createdDate: Date
}

public struct AidokuBackupUpdate: Codable, Hashable, Sendable {
    public var date: Date
    public var viewed: Bool
    public var sourceId: String
    public var mangaId: String
    public var chapterId: String
}

public struct AidokuBackupCategory: Codable, Hashable, Sendable {
    public let title: String?
    public let sort: Int?
    public let group: Bool?
    public let data: Data?
}

extension AidokuBackupCategory {
    public init(from decoder: any Decoder) throws {
        // try decoding just as a string
        let container = try decoder.singleValueContainer()
        if let title = try? container.decode(String.self) {
            self.title = title
            self.sort = nil
            self.group = nil
            self.data = nil
            return
        }
        // otherwise, assume object
        let objectContainer = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try? objectContainer.decodeIfPresent(String.self, forKey: .title)
        self.sort = try? objectContainer.decodeIfPresent(Int.self, forKey: .sort)
        self.group = try? objectContainer.decodeIfPresent(Bool.self, forKey: .group)
        self.data = try? objectContainer.decodeIfPresent(Data.self, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case sort
        case group
        case data
    }
}

public struct AidokuBackupSource: Codable, Hashable, Sendable {
    public let id: String
    public let apiVersion: String?
    public let config: Data?
}

extension AidokuBackupSource {
    public init(from decoder: any Decoder) throws {
        // try decoding just as a string
        let container = try decoder.singleValueContainer()
        if let id = try? container.decode(String.self) {
            self.id = id
            self.apiVersion = nil
            self.config = nil
            return
        }
        // otherwise, assume object
        let objectContainer = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try objectContainer.decode(String.self, forKey: .id)
        self.apiVersion = try? objectContainer.decodeIfPresent(String.self, forKey: .apiVersion)
        self.config = try? objectContainer.decodeIfPresent(Data.self, forKey: .config)
    }

    public func encode(to encoder: any Encoder) throws {
        if let config {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(apiVersion, forKey: .apiVersion)
            try container.encode(config, forKey: .config)
        } else {
            var container = encoder.singleValueContainer()
            try container.encode(id)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case apiVersion
        case config
    }
}
