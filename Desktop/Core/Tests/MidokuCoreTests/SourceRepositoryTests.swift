import Foundation
import XCTest

@testable import MidokuCore

final class SourceRepositoryTests: XCTestCase {
    private let modern =
        #"{"name":"Example","sources":[{"id":"en.example","name":"Example","version":3,"languages":["en"],"downloadURL":"sources/example.aix","contentRating":0}]}"#
    func testModernRepositoryAndRelativeDownloadURL() throws {
        let catalog = try SourceCatalog.decode(Data(modern.utf8))
        let address = try RepositoryAddress(" https://example.org/repo/ ")
        XCTAssertEqual(address.url.absoluteString, "https://example.org/repo/index.min.json")
        XCTAssertEqual(
            try catalog.sources[0].packageURL(relativeTo: address.url).absoluteString,
            "https://example.org/repo/sources/example.aix")
        XCTAssertEqual(catalog.sources[0].languages, ["en"])
    }
    func testModernIndexCanOmitDisplayMetadata() throws {
        let json =
            #"{"name":"Example","sources":[{"id":"en.example","name":"Example","version":1,"downloadURL":"sources/example.aix"}]}"#
        XCTAssertEqual(try SourceCatalog.decode(Data(json.utf8)).sources[0].languages, [])
        XCTAssertEqual(
            try RepositoryAddress("https://example.org/repo").url.absoluteString,
            "https://example.org/repo/index.min.json")
    }
    func testAidokuRepositoryDeepLink() throws {
        let address = try RepositoryAddress("aidoku://add-source-list?url=https%3A%2F%2Fexample.org%2Findex.min.json")
        XCTAssertEqual(address.url.absoluteString, "https://example.org/index.min.json")
    }
    func testLegacyIndexesAreRejected() {
        for json in [
            #"[{"id":"en.test","lang":"en","file":"test.aix"}]"#,
            #"{"name":"Old","sources":[{"id":"en.test","name":"Old","version":1,"lang":"en","file":"test.aix"}]}"#,
        ] {
            XCTAssertThrowsError(try SourceCatalog.decode(Data(json.utf8)))
        }
    }
    func testInvalidAndDuplicateIdentitiesAreRejected() {
        XCTAssertThrowsError(
            try SourceCatalog.decode(Data(modern.replacingOccurrences(of: "en.example", with: "../escape").utf8)))
        let entry = #"{"id":"a","name":"A","version":1,"languages":[],"downloadURL":"a.aix"}"#
        XCTAssertThrowsError(try SourceCatalog.decode(Data("{\"name\":\"A\",\"sources\":[\(entry),\(entry)]}".utf8)))
        for url in [
            "file:///tmp/source", "https://user:password@example.org/", "aidoku://other?url=https://example.org",
        ] { XCTAssertThrowsError(try RepositoryAddress(url)) }
        let entryWithBadURL = modern.replacingOccurrences(of: "sources/example.aix", with: "file:///tmp/file")
        let catalog = try? SourceCatalog.decode(Data(entryWithBadURL.utf8))
        XCTAssertThrowsError(
            try catalog?.sources[0].packageURL(relativeTo: URL(string: "https://example.org/index.json")!))
    }
    func testSourceSettingsRequirements() {
        let values = [
            "en.test.login": "logged_in", "en.test.enabled": "1", "en.test.disabled": "0",
            "en.test.url": "https://example.org",
        ]
        func matches(_ expression: String) -> Bool {
            SourceSettingCondition.evaluate(expression, namespace: "en.test") { values[$0] }
        }
        XCTAssertTrue(matches("login && enabled"))
        XCTAssertTrue(matches(" url == https://example.org && true "))
        XCTAssertFalse(matches("disabled"))
        XCTAssertFalse(matches("missing"))
        XCTAssertFalse(matches("url == other"))
    }
    func testOnlineChapterIdentityAndPersistence() throws {
        func reference(_ manga: String, _ chapter: String) -> OnlineChapterReference {
            .init(
                sourceKey: "en.test", mangaKey: manga, chapterKey: chapter, mangaTitle: "Title",
                chapterTitle: "Chapter", cover: nil, mangaData: Data("manga".utf8), chapterData: Data("chapter".utf8))
        }
        XCTAssertNotEqual(reference("a:b", "c").identity, reference("a", "b:c").identity)
        var book = ComicBook(title: "Title", pages: ["0.image", "1.image"], sourceIdentity: "online")
        book.online = reference("漫画", "1")
        book.currentPage = 1
        XCTAssertEqual(try JSONDecoder().decode(ComicBook.self, from: JSONEncoder().encode(book)), book)
        var local = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        local.removeValue(forKey: "online")
        XCTAssertNil(
            try JSONDecoder().decode(ComicBook.self, from: JSONSerialization.data(withJSONObject: local)).online)
    }
}
