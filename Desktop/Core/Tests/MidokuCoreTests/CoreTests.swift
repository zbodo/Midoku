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

    func testAdaptiveWindowSlidesOnePageAtATime() {
        var position = ReadingPosition(count: 6, pageCapacity: 3)
        XCTAssertEqual(position.visiblePages, [0, 1, 2])
        position.advance()
        XCTAssertEqual(position.visiblePages, [1, 2, 3])
        position.advance()
        XCTAssertEqual(position.visiblePages, [2, 3, 4])
        position.seek(4)
        XCTAssertEqual(position.visiblePages, [4, 5])
        position.advance()
        XCTAssertEqual(position.visiblePages, [5])
        position.advance()
        XCTAssertEqual(position.page, 5)
        position.retreat()
        XCTAssertEqual(position.visiblePages, [4, 5])
    }

    func testResizingPreservesExactLeadingPageAndSeek() {
        var position = ReadingPosition(count: 8, page: 3, pageCapacity: 2)
        XCTAssertEqual(position.visiblePages, [3, 4])
        position.pageCapacity = 4
        XCTAssertEqual(position.page, 3)
        XCTAssertEqual(position.visiblePages, [3, 4, 5, 6])
        position.pageCapacity = 1
        XCTAssertEqual(position.visiblePages, [3])
        position.seek(5)
        XCTAssertEqual(position.page, 5)
        position.layout = .continuous
        position.pageCapacity = 4
        XCTAssertEqual(position.visiblePages, [5])
    }

    func testEveryPageIsReachableAndNavigationRoundTrips() {
        for count in 1...30 {
            for capacity in 1...6 {
                var position = ReadingPosition(count: count, pageCapacity: capacity)
                for expected in 0..<count {
                    XCTAssertEqual(position.page, expected)
                    XCTAssertEqual(position.visiblePages.first, expected)
                    position.advance()
                }
                XCTAssertEqual(position.page, count - 1)
                for expected in (0..<(count - 1)).reversed() {
                    position.retreat()
                    XCTAssertEqual(position.page, expected)
                }
            }
        }
    }

    func testAdaptiveCapacityRespondsToViewportAndImageRatios() {
        let portraits = Array(repeating: 0.7, count: 8)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 500, height: 800, aspectRatios: portraits), 1)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1200, height: 800, aspectRatios: portraits), 2)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1800, height: 800, aspectRatios: portraits), 3)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1200, height: 1200, aspectRatios: portraits), 1)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1800, height: 800, aspectRatios: [1.5, 0.7, 0.7]), 2)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1800, height: 800, aspectRatios: [0.7]), 1)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1800, height: 800, aspectRatios: []), 0)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1, height: 800, aspectRatios: portraits), 1)
        XCTAssertEqual(
            AdaptivePageLayout.pageCount(width: 1200, height: 800, aspectRatios: [0.01, 0.01, 0.01, 0.01]), 3)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: .nan, height: 800, aspectRatios: portraits), 1)
        for width in [1.0, 50, 200, 1000] {
            XCTAssertEqual(AdaptivePageLayout.pageCount(width: width, height: 800, aspectRatios: [3, 3]), 1)
        }
    }

    func testLandscapeImagesUseTwoSlotsButRemainOneNavigationPage() {
        XCTAssertEqual(AdaptivePageLayout.pageSpan(aspectRatio: 0.7), 1)
        XCTAssertEqual(AdaptivePageLayout.pageSpan(aspectRatio: 1), 1)
        XCTAssertEqual(AdaptivePageLayout.pageSpan(aspectRatio: 1.01), 2)
        XCTAssertEqual(AdaptivePageLayout.pageSpan(aspectRatio: 3), 2)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1500, height: 800, aspectRatios: [1.1, 0.7]), 1)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1800, height: 800, aspectRatios: [1.1, 0.7]), 2)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 1800, height: 800, aspectRatios: [3, 3]), 1)
        XCTAssertEqual(AdaptivePageLayout.pageCount(width: 500, height: 800, aspectRatios: [3, 0.7]), 1)
        XCTAssertEqual(AdaptivePageLayout.slotAspectRatio(3), AdaptivePageLayout.portraitAspectRatio * 2)
        var position = ReadingPosition(count: 3, pageCapacity: 2)
        position.advance()
        XCTAssertEqual(position.page, 1)
        position.retreat()
        XCTAssertEqual(position.page, 0)
    }

    func testLegacyLayoutSettingsMigrateToAdaptive() throws {
        for value in ["single", "spread", "adaptive"] {
            XCTAssertEqual(PageLayout.preference(value), .adaptive)
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(PageLayout.self, from: data), .adaptive)
        }
        XCTAssertEqual(PageLayout.preference("continuous"), .continuous)
        XCTAssertEqual(PageLayout.allCases, [.adaptive, .continuous])
        XCTAssertEqual(
            try JSONDecoder().decode(PageLayout.self, from: JSONEncoder().encode(PageLayout.adaptive)), .adaptive)
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
        XCTAssertNil(shortcuts.action(for: ShortcutMap.defaults[.nextPage]!.first!))
        XCTAssertThrowsError(try shortcuts.assign(binding, to: .previousPage)) { error in
            XCTAssertEqual(error as? ShortcutError, .conflict(.nextPage))
        }
        let roundTrip = try JSONDecoder().decode(ShortcutMap.self, from: JSONEncoder().encode(shortcuts))
        XCTAssertEqual(roundTrip, shortcuts)
        shortcuts.reset()
        XCTAssertEqual(shortcuts.bindings(for: .nextPage), ShortcutMap.defaults[.nextPage])
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
        let bindings = ReaderAction.allCases.flatMap { map.bindings(for: $0) }
        XCTAssertEqual(Set(bindings).count, bindings.count)
    }

    func testArrowKeysAreCustomizableAndMultipleCharactersRejected() throws {
        var map = ShortcutMap()
        map.unbind(.nextPage)
        try map.add(.init(key: "\u{f703}"), to: .previousPage)
        XCTAssertEqual(map.action(for: .init(key: "\u{f703}")), .previousPage)
        XCTAssertThrowsError(try map.assign(.init(key: "next"), to: .nextPage))
    }

    func testMultipleBindingsUnbindAndPersistence() throws {
        var map = ShortcutMap()
        try map.add(.init(key: "n"), to: .nextPage)
        XCTAssertEqual(map.action(for: .init(key: "d")), .nextPage)
        XCTAssertEqual(map.action(for: .init(key: "n")), .nextPage)
        map.remove(.init(key: "d"), from: .nextPage)
        XCTAssertNil(map.action(for: .init(key: "d")))
        map.unbind(.toggleOverview)
        let roundTrip = try JSONDecoder().decode(ShortcutMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(roundTrip, map)
        XCTAssertNil(roundTrip.binding(for: .toggleOverview))
        XCTAssertNil(roundTrip.action(for: .init(key: "f")))
    }

    func testLegacyOverridesWinOverNewDefaults() throws {
        struct Legacy: Encodable { let overrides: [ReaderAction: KeyBinding] }
        let bytes = try JSONEncoder().encode(Legacy(overrides: [.toggleChrome: .init(key: "t")]))
        let map = try JSONDecoder().decode(ShortcutMap.self, from: bytes)
        XCTAssertEqual(map.action(for: .init(key: "t")), .toggleChrome)
        XCTAssertTrue(map.bindings(for: .toggleThumbnails).isEmpty)
        XCTAssertEqual(map.action(for: .init(key: "d")), .nextPage)
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
        snapshot.version = 999
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
