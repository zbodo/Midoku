#if targetEnvironment(macCatalyst)
@testable import Midoku
import AidokuRunner
import Testing
import UIKit

@Suite(.serialized)
@MainActor
struct ReaderSlidingSpreadTests {
    @Test func movesExactlyOneSlotInEitherReadingDirection() {
        #expect(ReaderSpreadSlide.translation(width: 1000, forward: true, rightToLeft: false) == -500)
        #expect(ReaderSpreadSlide.translation(width: 1000, forward: false, rightToLeft: false) == 500)
        #expect(ReaderSpreadSlide.translation(width: 1000, forward: true, rightToLeft: true) == 500)
        #expect(ReaderSpreadSlide.translation(width: 1000, forward: false, rightToLeft: true) == -500)
        #expect(ReaderSpreadSlide.translation(width: 640, forward: true, rightToLeft: false) == -320)
    }

    @Test(arguments: [ReadingMode.ltr, .rtl])
    func advancesAndReversesOverlappingPairs(mode: ReadingMode) async throws {
        try await withReader(mode: mode) { reader, delegate in
            let visible = try #require(reader.children.first as? UIPageViewController)
            let initial = try #require(visible.viewControllers?.first as? ReaderDoublePageViewController)
            #expect(delegate.pages == 1...2)
            turn(reader, forward: true)
            let second = try #require(visible.viewControllers?.first as? ReaderDoublePageViewController)
            #expect(initial.secondPageController === second.firstPageController)
            #expect(reader.currentPage == 2)
            #expect(delegate.pages == 2...3)
            turn(reader, forward: true)
            #expect(reader.currentPage == 3)
            #expect(delegate.pages == 3...4)
            turn(reader, forward: false)
            #expect(reader.currentPage == 2)
            #expect(delegate.pages == 2...3)
            turn(reader, forward: false)
            #expect(reader.currentPage == 1)
            #expect(delegate.pages == 1...2)
        }
    }

    @Test func chapterBoundaryDoesNotRepeatTheLastVisiblePage() async throws {
        try await withReader(mode: .ltr) { reader, delegate in
            for _ in 0..<3 { reader.moveRight() }
            #expect(delegate.pages == 4...5)
            reader.moveRight()
            #expect(reader.currentPage == 6)
            reader.moveLeft()
            #expect(reader.currentPage == 4)
            #expect(delegate.pages == 4...5)
        }
    }

    @Test func firstPageOffsetKeepsItsSingleCover() async throws {
        try await withReader(mode: .ltr, offset: true) { reader, delegate in
            #expect(delegate.pages == 1...1)
            reader.moveRight()
            #expect(delegate.pages == 2...3)
            reader.moveRight()
            #expect(delegate.pages == 3...4)
        }
    }

    @Test func adjacentChapterPreviewsRemainReachable() async throws {
        let next = AidokuRunner.Chapter(key: "next.chapter")
        try await withReader(mode: .ltr, next: next) { reader, delegate in
            for _ in 0..<4 { reader.moveRight() }
            #expect(reader.currentPage == 6)
            reader.moveRight()
            #expect(reader.chapter == next)
            #expect(delegate.changedChapter == next)
        }
        let previous = AidokuRunner.Chapter(key: "previous.chapter")
        try await withReader(mode: .ltr, previous: previous) { reader, delegate in
            reader.moveLeft()
            #expect(reader.currentPage == 0)
            reader.moveLeft()
            #expect(reader.chapter == previous)
            #expect(delegate.changedChapter == previous)
        }
    }

    private func turn(_ reader: ReaderPagedViewController, forward: Bool) {
        if forward == (reader.readingMode == .rtl) { reader.moveLeft() } else { reader.moveRight() }
    }

    private func withReader(
        mode: ReadingMode, offset: Bool = false,
        previous: AidokuRunner.Chapter? = nil, next: AidokuRunner.Chapter? = nil,
        body: (ReaderPagedViewController, ProgressRecorder) throws -> Void
    ) async throws {
        let settings: [String: Any] = [
            "Reader.pagedPageLayout": "double", "Reader.pagedPageOffset": offset,
            "Reader.animatePageTransitions": false, "Reader.splitWideImages": false,
            "Reader.pagesToPreload": 0
        ]
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        for (key, value) in settings { defaults.set(value, forKey: key) }
        defer {
            for key in settings.keys {
                if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let store = ReaderTemporaryPageStore()
        let reader = ReaderPagedViewController(source: nil,
                                              manga: Manga(sourceKey: "fixture", key: UUID().uuidString, title: "Spread"),
                                              temporaryPageStore: store)
        let recorder = ProgressRecorder()
        recorder.previousChapter = previous
        recorder.nextChapter = next
        reader.delegate = recorder
        reader.readingMode = mode
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let chapter = AidokuRunner.Chapter(key: "fixture.chapter")
        reader.chapter = chapter
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 140)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
        }
        reader.viewModel.preloadedChapter = chapter
        reader.viewModel.preloadedPages = (0..<5).map {
            Midoku.Page(sourceId: "fixture", chapterId: chapter.key, index: $0, image: image)
        }
        await reader.loadChapter(startPage: 1)
        do {
            try body(reader, recorder)
        } catch {
            await store.removeAll()
            throw error
        }
        await store.removeAll()
    }

    private final class ProgressRecorder: ReaderHoldingDelegate {
        var barsHidden = false
        var pages: ClosedRange<Int>?
        var previousChapter: AidokuRunner.Chapter?
        var nextChapter: AidokuRunner.Chapter?
        var changedChapter: AidokuRunner.Chapter?
        func hideBars() { barsHidden = true }
        func getNextChapter() -> AidokuRunner.Chapter? { nextChapter }
        func getPreviousChapter() -> AidokuRunner.Chapter? { previousChapter }
        func setChapter(_ chapter: AidokuRunner.Chapter) { changedChapter = chapter }
        func setCurrentPage(_ page: Int, position: Double?) { pages = page...page }
        func setCurrentPages(_ pages: ClosedRange<Int>) { self.pages = pages }
        func setPages(_ pages: [Midoku.Page]) {}
        func displayPage(_ page: Int) {}
        func setSliderOffset(_ offset: CGFloat) {}
        func setCompleted() {}
    }
}
#endif
