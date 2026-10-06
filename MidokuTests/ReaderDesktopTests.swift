@testable import Midoku
import AidokuRunner
import Foundation
import Testing

struct ReaderDesktopTests {
    @Test func restoresSourceIdentityAndChapterOrder() throws {
        let chapters = [Chapter(key: "two", chapterNumber: 2), Chapter(key: "one", chapterNumber: 1)]
        let manga = Manga(sourceKey: "fixture.source", key: "book", title: "Fixture", viewer: .rightToLeft, chapters: chapters)
        let request = ReaderWindowRequest(manga: manga, chapter: chapters[0], startPage: 7)
        let restored = try #require(ReaderWindowRequest(activity: request.activity))
        #expect(restored.manga.sourceKey == "fixture.source")
        #expect(restored.manga == manga)
        #expect(restored.chapter == chapters[0])
        #expect(restored.startPage == 7)
    }

    @Test func invalidRestorationDoesNotOpenAReader() {
        #expect(ReaderWindowRequest(activity: nil) == nil)
        let unrelated = NSUserActivity(activityType: "fixture.unrelated")
        #expect(ReaderWindowRequest(activity: unrelated) == nil)
        let corrupted = NSUserActivity(activityType: ReaderWindowRequest.activityType)
        corrupted.userInfo = ["reader": Data("invalid".utf8)]
        #expect(ReaderWindowRequest(activity: corrupted) == nil)
    }

    @Test func trackpadGestureAndMomentumTurnOnlyOnePage() {
        var policy = ReaderScrollPagingPolicy()
        policy.beginGesture()
        #expect(policy.pageTurn(delta: 20, threshold: 45) == nil)
        #expect(policy.pageTurn(delta: 50, threshold: 45) == true)
        #expect(policy.pageTurn(delta: 700, threshold: 45) == nil)
        #expect(policy.pageTurn(delta: -70, threshold: 45) == nil)
        policy.beginGesture()
        #expect(policy.pageTurn(delta: -50, threshold: 45) == false)
    }

    @Test func mouseWheelTicksTurnImmediately() {
        var policy = ReaderScrollPagingPolicy()
        policy.beginGesture()
        #expect(policy.pageTurn(delta: 1, threshold: 1) == true)
        #expect(policy.pageTurn(delta: 30, threshold: 1) == nil)
        policy.beginGesture()
        #expect(policy.pageTurn(delta: 1, threshold: 1) == true)
    }

    @Test func longImagesKeepScrollingUntilANewGestureStartsAtTheEdge() {
        #expect(!ReaderScrollPagingPolicy.canTurnPage(velocity: -50, offset: 250, minimum: 0, maximum: 500, zoomScale: 1, minimumZoomScale: 1))
        #expect(ReaderScrollPagingPolicy.canTurnPage(velocity: -50, offset: 500, minimum: 0, maximum: 500, zoomScale: 1, minimumZoomScale: 1))
        #expect(!ReaderScrollPagingPolicy.canTurnPage(velocity: 50, offset: 500, minimum: 0, maximum: 500, zoomScale: 1, minimumZoomScale: 1))
        #expect(ReaderScrollPagingPolicy.canTurnPage(velocity: 50, offset: 0, minimum: 0, maximum: 500, zoomScale: 1, minimumZoomScale: 1))
        #expect(!ReaderScrollPagingPolicy.canTurnPage(velocity: -50, offset: 500, minimum: 0, maximum: 500, zoomScale: 2, minimumZoomScale: 1))
    }
}
