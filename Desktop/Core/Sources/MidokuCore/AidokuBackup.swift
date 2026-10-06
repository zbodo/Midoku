import Foundation

/// The complete v0.9 export envelope. All sections are optional, except `date`.
public struct AidokuBackup: Codable, Equatable, Sendable {
    public var library: [AidokuBackupLibraryManga]?
    public var history: [AidokuBackupHistory]?
    public var manga: [AidokuBackupManga]?
    public var chapters: [AidokuBackupChapter]?
    public var trackItems: [AidokuBackupTrackItem]?
    public var readingSessions: [AidokuBackupReadingSession]?
    public var vocabulary: [AidokuBackupVocabEntry]?
    public var updates: [AidokuBackupUpdate]?
    public var categories: [AidokuBackupCategory]?
    public var sources: [AidokuBackupSource]?
    public var sourceLists: [String]?
    public var settings: [String: AidokuSettingValue]?
    public var date: Date
    public var name: String?
    public var automatic: Bool?
    public var version: String?

    public static let maximumFileSize = 64 * 1024 * 1024

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileSize else { throw AidokuBackupError.tooLarge }
        let backup: Self
        if data.starts(with: Data("bplist".utf8)) || data.starts(with: Data("<?xml".utf8)) {
            backup = try PropertyListDecoder().decode(Self.self, from: data)
        } else if let plist = try? PropertyListDecoder().decode(Self.self, from: data) {
            backup = plist
        } else {
            // Aidoku's JSON backups use Unix timestamps, not Foundation's reference date.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            backup = try decoder.decode(Self.self, from: data)
        }
        guard backup.date.timeIntervalSince1970.isFinite else { throw AidokuBackupError.invalidDate }
        return backup
    }

    public func history(source: String, manga: String, chapter: String) -> AidokuBackupHistory? {
        history?.filter { $0.sourceId == source && $0.mangaId == manga && $0.chapterId == chapter }
            .max { $0.dateRead < $1.dateRead }
    }

    public var categoryTitles: [String] {
        var seen: Set<String> = []
        let explicit = (categories ?? []).sorted { ($0.sort ?? 0) < ($1.sort ?? 0) }.compactMap(\.title)
        return (explicit + (library ?? []).flatMap { $0.categories ?? [] })
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public var historyByIdentifier: [[String]: AidokuBackupHistory] {
        var index: [[String]: AidokuBackupHistory] = [:]
        for entry in history ?? [] {
            let key = [entry.sourceId, entry.mangaId, entry.chapterId]
            if let existing = index[key], existing.dateRead > entry.dateRead { continue }
            index[key] = entry
        }
        return index
    }

    public var sourceKeys: Set<String> {
        var keys = Set((sources ?? []).map(\.id))
        for item in library ?? [] { keys.insert(item.sourceId) }
        for item in manga ?? [] { keys.insert(item.sourceId) }
        for item in chapters ?? [] { keys.insert(item.sourceId) }
        for item in history ?? [] { keys.insert(item.sourceId) }
        return keys
    }

    /// Apply only source namespaces; desktop application preferences need explicit mappings.
    public func sourceSettings(for source: String) -> [String: AidokuSettingValue] {
        guard SourceCatalog.validSourceKey(source) else { return [:] }
        return (settings ?? [:]).filter { $0.key.hasPrefix(source + ".") }
    }

    public var desktopSettings: [String: AidokuSettingValue] {
        var result: [String: AidokuSettingValue] = [:]
        if case .string(let mode) = settings?["Reader.readingMode"] {
            switch mode {
            case "rtl": result["desktop.direction"] = .string("rightToLeft")
            case "ltr": result["desktop.direction"] = .string("leftToRight")
            case "vertical", "scroll", "webtoon", "continuous": result["desktop.layout"] = .string("continuous")
            default: break
            }
        }
        if case .bool(let value) = settings?["Reader.invertTapZones"] {
            result["reader.swapClickSides"] = .bool(value)
        }
        return result
    }

    /// Per-manga preferences precede the global mode, as in Aidoku's reader.
    public func readingMode(source: String, manga: String) -> String? {
        if case .string(let mode) = settings?["Reader.readingMode.\(source).\(manga)"], mode != "default" {
            return mode
        }
        if case .string(let mode) = settings?["Reader.readingMode"], mode != "default" { return mode }
        return nil
    }

    /// Merge by upstream identifiers, preserving newer reading history and all optional sections.
    public func merging(_ incoming: Self) -> Self {
        var result = incoming
        result.library = merge(
            library, incoming.library, key: { [$0.sourceId, $0.mangaId] },
            choose: { old, new in
                var entry = new
                // Aidoku omits membership when categories were excluded from the export.
                if entry.categories == nil { entry.categories = old.categories }
                return entry
            })
        result.manga = merge(manga, incoming.manga, key: { [$0.sourceId, $0.id] })
        result.chapters = merge(chapters, incoming.chapters, key: { [$0.sourceId, $0.mangaId, $0.id] })
        result.history = merge(
            history, incoming.history,
            key: { [$0.sourceId, $0.mangaId, $0.chapterId] },
            choose: { $0.dateRead > $1.dateRead ? $0 : $1 })
        result.trackItems = merge(
            trackItems, incoming.trackItems,
            key: { [$0.sourceId, $0.mangaId, $0.trackerId, $0.id] })
        result.readingSessions = merge(
            readingSessions, incoming.readingSessions,
            key: {
                [
                    $0.sourceId, $0.mangaId, $0.chapterId,
                    String($0.startDate.timeIntervalSince1970),
                    String($0.endDate.timeIntervalSince1970),
                ]
            })
        result.vocabulary = merge(
            vocabulary, incoming.vocabulary,
            key: {
                [
                    $0.sourceId, $0.mangaId, $0.chapterId, $0.word,
                    String($0.page), String($0.createdDate.timeIntervalSince1970),
                ]
            })
        result.updates = merge(
            updates, incoming.updates,
            key: { [$0.sourceId, $0.mangaId, $0.chapterId] })
        result.categories = merge(
            categories, incoming.categories,
            key: {
                if let title = $0.title { return ["title", title] }
                return [
                    "unnamed", String($0.sort ?? 0), String($0.group ?? false), $0.data?.base64EncodedString() ?? "",
                ]
            },
            choose: { old, new in
                .init(
                    title: new.title, sort: new.sort ?? old.sort, group: new.group ?? old.group,
                    data: new.data ?? old.data)
            })
        result.sources = merge(sources, incoming.sources, key: { [$0.id] })
        result.sourceLists = merge(sourceLists, incoming.sourceLists, key: { [$0] })
        if settings != nil || incoming.settings != nil {
            result.settings = (settings ?? [:]).merging(incoming.settings ?? [:]) { _, new in new }
        }
        return result
    }
}

private func merge<T>(
    _ old: [T]?, _ new: [T]?, key: (T) -> [String],
    choose: (T, T) -> T = { _, new in new }
) -> [T]? {
    guard old != nil || new != nil else { return nil }
    var values: [T] = []
    var indices: [[String]: Int] = [:]
    for item in (old ?? []) + (new ?? []) {
        let identity = key(item)
        if let index = indices[identity] {
            values[index] = choose(values[index], item)
        } else {
            indices[identity] = values.count
            values.append(item)
        }
    }
    return values
}

/// Keeps the exact source bytes as well as the merged, usable records.
/// Unknown future fields and custom source configuration remain recoverable.
public struct AidokuBackupState: Codable, Equatable, Sendable {
    public var backup: AidokuBackup
    public var originals: [AidokuBackupOriginal]
    public var restoreSourceSettings: Bool

    public init(backup: AidokuBackup, data: Data, filename: String, restoreSourceSettings: Bool) {
        self.backup = backup.merging(backup)
        originals = [.init(data: data, filename: filename)]
        self.restoreSourceSettings = restoreSourceSettings
    }

    public func merging(
        backup: AidokuBackup, data: Data, filename: String,
        restoreSourceSettings: Bool
    ) -> Self {
        var next = self
        next.backup = self.backup.merging(backup)
        if !originals.contains(where: { $0.data == data }) {
            next.originals.append(.init(data: data, filename: filename))
        }
        next.restoreSourceSettings = restoreSourceSettings
        return next
    }
}

public struct AidokuBackupOriginal: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let data: Data
    public let filename: String
    public let importedAt: Date
    public init(data: Data, filename: String) {
        id = UUID()
        self.data = data
        self.filename = filename
        importedAt = Date()
    }
}

public enum AidokuBackupPersistence {
    public static func load(from url: URL) throws -> AidokuBackupState {
        try JSONDecoder().decode(AidokuBackupState.self, from: Data(contentsOf: url))
    }
    public static func save(_ state: AidokuBackupState, to url: URL) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

extension AidokuBackupHistory {
    /// Aidoku stores the current page starting at 1. Desktop indices start at 0.
    public func pageIndex(pageCount: Int) -> Int {
        min(max(0, (progress ?? 1) > 0 ? (progress ?? 1) - 1 : 0), max(0, pageCount - 1))
    }
}

public enum AidokuSettingValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case array([AidokuSettingValue])
    case object([String: AidokuSettingValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let v = try? value.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? value.decode(Int.self) {
            self = .integer(v)
        } else if let v = try? value.decode(Double.self) {
            self = .double(v)
        } else if let v = try? value.decode(String.self) {
            self = .string(v)
        } else if let v = try? value.decode([AidokuSettingValue].self) {
            self = .array(v)
        } else {
            self = .object(try value.decode([String: AidokuSettingValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .double(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        }
    }

    public var rawValue: Any? {
        switch self {
        case .null: nil
        case .bool(let v): v
        case .integer(let v): v
        case .double(let v): v
        case .string(let v): v
        case .array(let v): v.compactMap(\.rawValue)
        case .object(let v): v.compactMapValues(\.rawValue)
        }
    }
}

public enum AidokuBackupError: Error, LocalizedError {
    case tooLarge, invalidDate
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The Aidoku backup exceeds the 64 MB import limit."
        case .invalidDate: "The Aidoku backup contains an invalid date."
        }
    }
}
