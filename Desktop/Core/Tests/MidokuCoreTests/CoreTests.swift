import Foundation
import XCTest

@testable import MidokuCore

final class ReadingPositionTests: XCTestCase {
    func testEmptyAndOutOfRangePositions() {
        var empty = ReadingPosition(count: 0, page: 100)
        empty.advance()
        empty.retreat()
        XCTAssertEqual(empty.page, 0)
        XCTAssertTrue(empty.visiblePages.isEmpty)
        XCTAssertEqual(ReadingPosition(count: 3, page: 9).page, 2)
        XCTAssertEqual(ReadingPosition(count: 3, page: -1).page, 0)
    }

    func testCoverAndSpreadAdvanceRetreat() {
        var position = ReadingPosition(count: 6, layout: .spread)
        XCTAssertEqual(position.visiblePages, [0])
        position.advance()
        XCTAssertEqual(position.visiblePages, [1, 2])
        position.advance()
        XCTAssertEqual(position.visiblePages, [3, 4])
        position.advance()
        XCTAssertEqual(position.visiblePages, [5])
        position.advance()
        XCTAssertEqual(position.visiblePages, [5])
        position.retreat()
        XCTAssertEqual(position.visiblePages, [3, 4])
        position.retreat()
        position.retreat()
        XCTAssertEqual(position.visiblePages, [0])
    }

    func testSpreadWithoutSingleCoverAndSeekAlignment() {
        var position = ReadingPosition(count: 5, layout: .spread, coverIsSingle: false)
        XCTAssertEqual(position.visiblePages, [0, 1])
        position.seek(3)
        XCTAssertEqual(position.visiblePages, [2, 3])
        position.advance()
        XCTAssertEqual(position.visiblePages, [4])
        position.retreat()
        XCTAssertEqual(position.visiblePages, [2, 3])
    }

    func testEveryPageIsReachableAndNavigationRoundTrips() {
        for count in 1...30 {
            for cover in [false, true] {
                var position = ReadingPosition(count: count, layout: .spread, coverIsSingle: cover)
                var visited: [Int] = []
                var starts: [Int] = []
                repeat {
                    starts.append(position.page)
                    visited += position.visiblePages
                    let oldPage = position.page
                    position.advance()
                    if position.page == oldPage { break }
                } while true
                XCTAssertEqual(visited, Array(0..<count))
                for expected in starts.dropLast().reversed() {
                    position.retreat()
                    XCTAssertEqual(position.page, expected)
                }
            }
        }
    }
}

final class PageCatalogTests: XCTestCase {
    func testNaturalSortFiltersMetadata() {
        XCTAssertEqual(
            PageCatalog.sorted(["10.jpg", "2.JPG", "1.png", "__MACOSX/1.jpg", ".hidden.png", "info.xml"]),
            ["1.png", "2.JPG", "10.jpg"])
    }
    func testRejectsTraversalAndAbsolutePaths() {
        for path in ["../page.jpg", "/page.jpg", "a/../page.jpg", "a\\page.jpg", "a//page.jpg", "./page.jpg", ""] {
            XCTAssertFalse(PageCatalog.isSafeRelativePath(path), path)
        }
        XCTAssertTrue(PageCatalog.isSafeRelativePath("chapter 1/01.jpg"))
    }
}

final class ShortcutTests: XCTestCase {
    func testCustomBindingPersistenceAndConflict() throws {
        var shortcuts = ShortcutMap()
        let binding = KeyBinding(key: "N", modifiers: .option)
        try shortcuts.assign(binding, to: .nextPage)
        XCTAssertEqual(shortcuts.action(for: binding), .nextPage)
        XCTAssertNil(shortcuts.action(for: ShortcutMap.defaults[.nextPage]!))
        XCTAssertThrowsError(try shortcuts.assign(binding, to: .previousPage)) { error in
            XCTAssertEqual(error as? ShortcutError, .conflict(.nextPage))
        }
        let roundTrip = try JSONDecoder().decode(ShortcutMap.self, from: JSONEncoder().encode(shortcuts))
        XCTAssertEqual(roundTrip, shortcuts)
        shortcuts.reset()
        XCTAssertEqual(shortcuts.binding(for: .nextPage), ShortcutMap.defaults[.nextPage])
    }

    func testProtectsSystemKeys() {
        var shortcuts = ShortcutMap()
        for key in ["q", "w", "h", "m", "o", ",", "\t"] {
            XCTAssertThrowsError(try shortcuts.assign(.init(key: key, modifiers: .command), to: .nextPage))
        }
        XCTAssertThrowsError(try shortcuts.assign(.init(key: "\u{1b}"), to: .nextPage))
    }

    func testDefaultsHaveNoCollisions() {
        let map = ShortcutMap()
        XCTAssertEqual(Set(ReaderAction.allCases.map { map.binding(for: $0) }).count, ReaderAction.allCases.count)
    }

    func testRejectsArrowKeysAndMultipleCharacters() {
        var map = ShortcutMap()
        for key in ["\u{f700}", "\u{f701}", "\u{f702}", "\u{f703}", "next"] {
            XCTAssertThrowsError(try map.assign(.init(key: key), to: .nextPage))
        }
    }
}

final class PersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLibraryRoundTripAndAtomicReplacement() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        XCTAssertTrue(try LibraryPersistence.load(from: file).books.isEmpty)
        var snapshot = LibrarySnapshot()
        var book = ComicBook(title: "Test", pages: ["0.jpg", "1.jpg"], sourceIdentity: "/original.cbz")
        book.currentPage = 1
        book.isFavorite = true
        book.collection = "Favorites"
        snapshot.books = [book]
        snapshot.collections = ["Favorites"]
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertEqual(try LibraryPersistence.load(from: file), snapshot)
        snapshot.books[0].title = "Renamed"
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertEqual(try LibraryPersistence.load(from: file).books[0].title, "Renamed")
    }

    func testRejectsCorruptLibraryWithoutOverwriting() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let bytes = Data("invalid JSON".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try LibraryPersistence.load(from: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testRejectsUnknownVersionAndUnsafePages() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        var snapshot = LibrarySnapshot()
        snapshot.version = 2
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertThrowsError(try LibraryPersistence.load(from: file))
        snapshot.version = 1
        snapshot.books = [ComicBook(title: "Unsafe", pages: ["../../outside.png"], sourceIdentity: "")]
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertThrowsError(try LibraryPersistence.load(from: file))
    }

    func testRejectsDuplicateIDsAndInvalidProgress() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        var snapshot = LibrarySnapshot()
        let book = ComicBook(title: "Test", pages: ["0.jpg"], sourceIdentity: "original")
        snapshot.books = [book, book]
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertThrowsError(try LibraryPersistence.load(from: file))
        snapshot.books = [book]
        snapshot.books[0].currentPage = 9
        try LibraryPersistence.save(snapshot, to: file)
        XCTAssertThrowsError(try LibraryPersistence.load(from: file))
    }
}
