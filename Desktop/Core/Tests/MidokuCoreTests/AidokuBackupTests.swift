import Foundation
import XCTest

@testable import MidokuCore

final class AidokuBackupTests: XCTestCase {
    // Constructed independently with the keys/types emitted by Aidoku v0.9's
    // BackupManager and Backup* models. This is not encoded by our import model.
    private let fixture = #"""
        {
          "date": 1791270000, "name": "Aidoku 0.9", "version": "0.9", "automatic": false,
          "library": [{"sourceId":"en.test","mangaId":"/manga/1","dateAdded":1700000000,
                       "lastOpened":1791260000,"lastUpdated":1791261000,
                       "lastRead":1791262000,"categories":["Favorites","Reading"]}],
          "manga": [{"sourceId":"en.test","id":"/manga/1","title":"Test Comic",
                     "author":"Author","artist":"Artist","desc":"Description","cover":"https://example.org/cover",
                     "status":1,"nsfw":0,"viewer":1,"chapterFlags":3,"editedKeys":7,
                     "langFilter":"en","scanlatorFilter":["Group"],"neverUpdate":true}],
          "chapters": [{"sourceId":"en.test","mangaId":"/manga/1","id":"chapter:1",
                        "lang":"en","sourceOrder":0,"chapter":1.5,"volume":2,
                        "dateUploaded":1700000000,"locked":false}],
          "history": [{"sourceId":"en.test","mangaId":"/manga/1","chapterId":"chapter:1",
                       "dateRead":1791262000,"progress":7,"total":20,"completed":false}],
          "categories": ["Favorites",{"title":"Reading","sort":2,"group":false,"data":"AQID"}],
          "sources": ["en.test",{"id":"custom","apiVersion":"custom","config":"BAUG"}],
          "sourceLists": ["https://example.org/sources/"],
          "settings": {"Reader.readingMode":"rtl","Reader.invertTapZones":true,
                       "en.test.enabled":true,"en.test.count":4,"en.test.rate":1.25,
                       "en.test.values":["a","b"],"en.test.numbers":[1,2],
                       "en.test.child":{"enabled":false},"en.testing.ignored":true},
          "trackItems": [{"id":"42","trackerId":"tracker","sourceId":"en.test","mangaId":"/manga/1","chapterOffset":2}],
          "readingSessions": [{"sourceId":"en.test","mangaId":"/manga/1","chapterId":"chapter:1",
                               "pagesRead":6,"startDate":1791260000,"endDate":1791262000}],
          "vocabulary": [{"sourceId":"en.test","mangaId":"/manga/1","chapterId":"chapter:1",
                          "word":"test","page":7,"createdDate":1791262000,"clozeOffset":2}],
          "updates": [{"sourceId":"en.test","mangaId":"/manga/1","chapterId":"chapter:1","date":1791260000,"viewed":true}],
          "futureField": {"preserve": "verbatim"}
        }
        """#

    private var json: Data { Data(fixture.utf8) }

    private func binaryPlist() throws -> Data {
        let dates: Set<String> = [
            "date", "dateAdded", "lastOpened", "lastUpdated", "lastRead",
            "dateUploaded", "dateRead", "startDate", "endDate", "createdDate",
        ]
        func convert(_ raw: Any, key: String = "") -> Any {
            if dates.contains(key), let time = raw as? Double { return Date(timeIntervalSince1970: time) }
            if ["data", "config"].contains(key), let encoded = raw as? String { return Data(base64Encoded: encoded)! }
            if let map = raw as? [String: Any] {
                return map.reduce(into: [String: Any]()) {
                    $0[$1.key] = convert($1.value, key: $1.key)
                }
            }
            if let array = raw as? [Any] { return array.map { convert($0) } }
            return raw
        }
        let root = try JSONSerialization.jsonObject(with: json)
        return try PropertyListSerialization.data(fromPropertyList: convert(root), format: .binary, options: 0)
    }

    func testAllSectionsFromJSONAndUnixTimestamps() throws {
        let backup = try AidokuBackup.decode(json)
        XCTAssertEqual(backup.date, Date(timeIntervalSince1970: 1_791_270_000))
        XCTAssertEqual(backup.library?.first?.categories, ["Favorites", "Reading"])
        XCTAssertEqual(backup.manga?.first?.viewer, 1)
        XCTAssertEqual(backup.manga?.first?.editedKeys, 7)
        XCTAssertEqual(backup.chapters?.first?.chapter, 1.5)
        XCTAssertEqual(backup.history?.first?.pageIndex(pageCount: 20), 6)
        XCTAssertEqual(backup.trackItems?.first?.chapterOffset, 2)
        XCTAssertEqual(backup.readingSessions?.first?.pagesRead, 6)
        XCTAssertEqual(backup.vocabulary?.first?.word, "test")
        XCTAssertEqual(backup.updates?.first?.viewed, true)
        XCTAssertEqual(backup.categoryTitles, ["Favorites", "Reading"])
    }

    func testBinaryPlistMatchesJSONIncludingDatesAndOpaqueData() throws {
        let backup = try AidokuBackup.decode(binaryPlist())
        XCTAssertEqual(backup, try AidokuBackup.decode(json))
        XCTAssertEqual(backup.categories?[1].data, Data([1, 2, 3]))
        XCTAssertEqual(backup.sources?[1].config, Data([4, 5, 6]))
        XCTAssertEqual(backup.sources?[1].apiVersion, "custom")
    }

    func testTypedSettingsAndExactSourceNamespace() throws {
        let backup = try AidokuBackup.decode(json)
        let values = backup.sourceSettings(for: "en.test")
        XCTAssertEqual(values["en.test.enabled"], .bool(true))
        XCTAssertEqual(values["en.test.count"], .integer(4))
        XCTAssertEqual(values["en.test.rate"], .double(1.25))
        XCTAssertEqual(values["en.test.numbers"], .array([.integer(1), .integer(2)]))
        XCTAssertNil(values["en.testing.ignored"])
        XCTAssertTrue(backup.sourceSettings(for: "../test").isEmpty)
        XCTAssertEqual(backup.desktopSettings["desktop.direction"], .string("rightToLeft"))
        XCTAssertEqual(backup.desktopSettings["reader.swapClickSides"], .bool(true))
    }

    func testPerMangaReadingPreferencePrecedesGlobalAndDefaultInherits() throws {
        var backup = try AidokuBackup.decode(json)
        XCTAssertEqual(backup.readingMode(source: "en.test", manga: "/manga/1"), "rtl")
        backup.settings?["Reader.readingMode.en.test./manga/1"] = .string("ltr")
        XCTAssertEqual(backup.readingMode(source: "en.test", manga: "/manga/1"), "ltr")
        backup.settings?["Reader.readingMode.en.test./manga/1"] = .string("default")
        XCTAssertEqual(backup.readingMode(source: "en.test", manga: "/manga/1"), "rtl")
        backup.settings?["Reader.readingMode.en.test./manga/1"] = .string("auto")
        XCTAssertEqual(backup.readingMode(source: "en.test", manga: "/manga/1"), "auto")
    }

    func testPartialAndOldStringSectionsDecode() throws {
        let backup = try AidokuBackup.decode(
            Data(#"{"date":1700000000,"sources":["en.test"],"categories":["Reading"]}"#.utf8))
        XCTAssertNil(backup.history)
        XCTAssertNil(backup.sources?.first?.config)
        XCTAssertEqual(backup.categories?.first?.title, "Reading")
        XCTAssertNoThrow(try AidokuBackup.decode(Data(#"{"date":1700000000}"#.utf8)))
    }

    func testPartialBackupPreservesMembershipAndStringSourceMeansExternalSource() throws {
        let initial = try AidokuBackup.decode(json)
        var partial = initial
        partial.library?[0].categories = nil
        partial.categories = try AidokuBackup.decode(Data(#"{"date":1700000000,"categories":["Reading"]}"#.utf8))
            .categories
        partial.sources = try AidokuBackup.decode(Data(#"{"date":1700000000,"sources":["custom"]}"#.utf8)).sources
        let merged = initial.merging(partial)
        XCTAssertEqual(merged.library?.first?.categories, ["Favorites", "Reading"])
        XCTAssertEqual(merged.categories?.first(where: { $0.title == "Reading" })?.data, Data([1, 2, 3]))
        // v0.9 intentionally encodes external sources as strings, not config objects.
        XCTAssertNil(merged.sources?.first(where: { $0.id == "custom" })?.config)
    }

    func testMergeIsIdempotentAndKeepsNewerProgressAndOmittedSections() throws {
        let initial = try AidokuBackup.decode(json)
        var older = initial
        older.history?[0].dateRead = Date(timeIntervalSince1970: 1_600_000_000)
        older.history?[0].progress = 2
        older.vocabulary = nil
        older.trackItems = nil
        let merged = initial.merging(older)
        XCTAssertEqual(merged.history?.first?.progress, 7)
        XCTAssertEqual(merged.vocabulary, initial.vocabulary)
        XCTAssertEqual(merged.trackItems, initial.trackItems)
        XCTAssertEqual(merged.merging(merged), merged)
    }

    func testSourceAndMangaIdentityDoesNotCollideAcrossSeparators() throws {
        var backup = try AidokuBackup.decode(json)
        let first = backup.history![0]
        var second = first
        backup.history?[0].sourceId = "a:b"
        backup.history?[0].mangaId = "c"
        second.sourceId = "a"
        second.mangaId = "b:c"
        backup.history?.append(second)
        XCTAssertEqual(backup.merging(backup).history?.count, 2)
    }

    func testProgressSentinelsAndChangedPageCounts() throws {
        var history = try XCTUnwrap(AidokuBackup.decode(json).history?.first)
        history.progress = -1
        XCTAssertEqual(history.pageIndex(pageCount: 20), 0)
        history.progress = nil
        XCTAssertEqual(history.pageIndex(pageCount: 20), 0)
        history.progress = 1
        XCTAssertEqual(history.pageIndex(pageCount: 20), 0)
        history.progress = Int.max
        XCTAssertEqual(history.pageIndex(pageCount: 20), 19)
        XCTAssertEqual(history.pageIndex(pageCount: 0), 0)
    }

    func testCompleteOriginalAndEverySectionSurviveLibraryPersistence() throws {
        let data = try binaryPlist()
        let backup = try AidokuBackup.decode(data)
        var library = LibrarySnapshot()
        let state = AidokuBackupState(backup: backup, data: data, filename: "export.aib", restoreSourceSettings: true)
        library.aidokuBackupFile = "archive.json"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        try AidokuBackupPersistence.save(state, to: directory.appendingPathComponent("archive.json"))
        try LibraryPersistence.save(library, to: url)
        let index = try LibraryPersistence.load(from: url)
        let restored = try AidokuBackupPersistence.load(from: directory.appendingPathComponent(index.aidokuBackupFile!))
        XCTAssertEqual(restored.backup, backup)
        XCTAssertEqual(restored.originals.first?.data, data)
        let raw =
            try PropertyListSerialization.propertyList(from: restored.originals[0].data, format: nil) as! [String: Any]
        XCTAssertNotNil(raw["futureField"])
        let merged = restored.merging(backup: backup, data: data, filename: "again.aib", restoreSourceSettings: true)
        XCTAssertEqual(merged.originals.count, 1)
    }

    func testMalformedBackupsFailInsteadOfImportingPartialData() {
        XCTAssertThrowsError(try AidokuBackup.decode(Data("not a backup".utf8)))
        XCTAssertThrowsError(try AidokuBackup.decode(Data(#"{"library":[]}"#.utf8)))
        XCTAssertThrowsError(
            try AidokuBackup.decode(
                Data(fixture.replacingOccurrences(of: "\"completed\":false", with: "\"completed\":\"bad\"").utf8)))
    }
}
