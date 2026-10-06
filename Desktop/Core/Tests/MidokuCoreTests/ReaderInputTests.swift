import XCTest

@testable import MidokuCore

final class ReaderInputTests: XCTestCase {
    func testClickZonesMirrorDirectionAndContinuousNeverTurns() {
        XCTAssertEqual(ReaderInputPolicy.click(at: 0.1, direction: .rightToLeft, layout: .adaptive), .next)
        XCTAssertEqual(ReaderInputPolicy.click(at: 0.9, direction: .rightToLeft, layout: .adaptive), .previous)
        XCTAssertEqual(ReaderInputPolicy.click(at: 0.1, direction: .leftToRight, layout: .adaptive), .previous)
        XCTAssertEqual(ReaderInputPolicy.click(at: 0.9, direction: .leftToRight, layout: .adaptive), .next)
        for fraction in [0.375, 0.5, 0.625] {
            XCTAssertEqual(ReaderInputPolicy.click(at: fraction, direction: .rightToLeft, layout: .adaptive), .controls)
        }
        XCTAssertEqual(ReaderInputPolicy.click(at: 0.1, direction: .rightToLeft, layout: .continuous), .controls)
        XCTAssertEqual(
            ReaderInputPolicy.click(at: 0.1, direction: .rightToLeft, layout: .adaptive, enabled: false), .controls)
        XCTAssertEqual(
            ReaderInputPolicy.click(at: 0.1, direction: .rightToLeft, layout: .adaptive, swapSides: true), .previous)
    }
    func testTrackpadTurnsOnceAndIgnoresMomentum() {
        var gate = WheelTurnGate()
        XCTAssertEqual(
            gate.consume(
                delta: 0.1, time: 1, precise: true, began: true, ended: false, momentum: false, canScroll: false), 1)
        XCTAssertNil(
            gate.consume(
                delta: 25, time: 1.01, precise: true, began: false, ended: false, momentum: false, canScroll: false))
        XCTAssertNil(
            gate.consume(
                delta: 100, time: 1.02, precise: true, began: false, ended: false, momentum: false, canScroll: false))
        XCTAssertNil(
            gate.consume(
                delta: 100, time: 2, precise: true, began: false, ended: false, momentum: true, canScroll: false))
        XCTAssertEqual(
            gate.consume(
                delta: -50, time: 3, precise: true, began: true, ended: false, momentum: false, canScroll: false), -1)
    }
    func testScrollingToBoundaryNeedsAnotherGesture() {
        var gate = WheelTurnGate()
        XCTAssertNil(
            gate.consume(
                delta: 100, time: 1, precise: true, began: true, ended: false, momentum: false, canScroll: true))
        XCTAssertNil(
            gate.consume(
                delta: 100, time: 1.1, precise: true, began: false, ended: false, momentum: false, canScroll: false))
        XCTAssertEqual(
            gate.consume(
                delta: 100, time: 2, precise: true, began: true, ended: false, momentum: false, canScroll: false), 1)
    }
    func testEachDiscreteWheelNotchTurnsImmediately() {
        var gate = WheelTurnGate()
        XCTAssertEqual(
            gate.consume(
                delta: 3, time: 1, precise: false, began: false, ended: false, momentum: false, canScroll: false), 1)
        XCTAssertEqual(
            gate.consume(
                delta: 0.1, time: 1.01, precise: false, began: false, ended: false, momentum: false, canScroll: false),
            1)
        XCTAssertEqual(
            gate.consume(
                delta: -3, time: 1.4, precise: false, began: false, ended: false, momentum: false, canScroll: false), -1
        )
    }
    func testSlowPhasedGestureCannotTurnTwice() {
        var gate = WheelTurnGate()
        XCTAssertEqual(
            gate.consume(
                delta: 60, time: 1, precise: true, began: true, ended: false,
                momentum: false, canScroll: false, phased: true), 1)
        XCTAssertNil(
            gate.consume(
                delta: 60, time: 4, precise: true, began: false, ended: false,
                momentum: false, canScroll: false, phased: true))
    }
    func testDraggingCancelsClickEvenWhenPointerReturns() {
        var candidate = ReaderClickCandidate(x: 10, y: 10)
        candidate.move(x: 12, y: 11)
        XCTAssertTrue(candidate.isClick)
        candidate.move(x: 30, y: 10)
        candidate.move(x: 10, y: 10)
        XCTAssertFalse(candidate.isClick)
    }
    func testPageOffsetSurvivesLibraryRoundTripAndOldRecords() throws {
        var book = ComicBook(title: "Long page", pages: ["0.jpg"], sourceIdentity: "fixture")
        book.pageOffset = 0.6
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(ComicBook.self, from: encoder.encode(book)).pageOffset, 0.6)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
        object.removeValue(forKey: "pageOffset")
        XCTAssertNil(
            try decoder.decode(ComicBook.self, from: JSONSerialization.data(withJSONObject: object)).pageOffset)
    }
    func testPrefetchBoundsAndNeighbourCoverage() {
        XCTAssertEqual(ReaderPrefetchPolicy.pages(count: 0, page: 0, visibleCount: 1), [])
        XCTAssertEqual(ReaderPrefetchPolicy.pages(count: 20, page: 5, visibleCount: 3), Array(3...9))
        XCTAssertEqual(ReaderPrefetchPolicy.pages(count: 20, page: 0, visibleCount: 3), Array(0...4))
        XCTAssertEqual(ReaderPrefetchPolicy.pages(count: 20, page: 19, visibleCount: 3), [17, 18, 19])
        XCTAssertEqual(ReaderPrefetchPolicy.pages(count: 20, page: 5, visibleCount: 3, extraPages: 0), [5, 6, 7])
        XCTAssertEqual(ReaderPrefetchPolicy.pages(count: 20, page: 5, visibleCount: 3, extraPages: 4), Array(1...11))
        XCTAssertEqual(ReaderPrefetchPolicy.pages(count: 20, page: 5, visibleCount: 3, extraPages: -1), [5, 6, 7])
    }

    func testSlidingRowRetainsPagesAndCrossesViewportEdges() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let current = (0..<3).map {
            ReaderPageFrame(page: $0, rect: CGRect(x: $0 * 400, y: 0, width: 380, height: 800))
        }
        let target = (1..<4).map {
            ReaderPageFrame(page: $0, rect: CGRect(x: ($0 - 1) * 400, y: 0, width: 380, height: 800))
        }
        let slides = ReaderSlideGeometry.slides(current: current, target: target, viewport: viewport, direction: -1)
        let kept = try XCTUnwrap(slides.first { $0.page == 1 })
        XCTAssertEqual(kept.start, current[1].rect)
        XCTAssertEqual(kept.end, target[0].rect)
        XCTAssertLessThanOrEqual(try XCTUnwrap(slides.first { $0.page == 0 }).end.maxX, viewport.minX)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(slides.first { $0.page == 3 }).start.minX, viewport.maxX)
    }

    func testSlidingGeometryMirrorsDirectionAndHandlesWidePages() throws {
        let viewport = CGRect(x: 0, y: 0, width: 900, height: 800)
        let old = [ReaderPageFrame(page: 0, rect: CGRect(x: 0, y: 0, width: 900, height: 600))]
        let new = [ReaderPageFrame(page: 1, rect: CGRect(x: 200, y: 0, width: 500, height: 800))]
        for direction in [-1.0, 1.0] {
            let slides = ReaderSlideGeometry.slides(current: old, target: new, viewport: viewport, direction: direction)
            let leaving = try XCTUnwrap(slides.first { $0.page == 0 })
            let entering = try XCTUnwrap(slides.first { $0.page == 1 })
            XCTAssertEqual(leaving.start, old[0].rect)
            XCTAssertEqual(entering.end, new[0].rect)
            if direction > 0 {
                XCTAssertGreaterThanOrEqual(leaving.end.minX, viewport.maxX)
                XCTAssertLessThanOrEqual(entering.start.maxX, viewport.minX)
            } else {
                XCTAssertLessThanOrEqual(leaving.end.maxX, viewport.minX)
                XCTAssertGreaterThanOrEqual(entering.start.minX, viewport.maxX)
            }
        }
    }

    func testInterruptedSlideStartsAtCapturedPresentationFrame() throws {
        let visible = CGRect(x: 127, y: 15, width: 420, height: 760)
        let target = CGRect(x: 10, y: 15, width: 420, height: 760)
        let slides = ReaderSlideGeometry.slides(
            current: [ReaderPageFrame(page: 2, rect: visible)],
            target: [ReaderPageFrame(page: 2, rect: target)],
            viewport: CGRect(x: 0, y: 0, width: 900, height: 800), direction: -1)
        XCTAssertEqual(try XCTUnwrap(slides.first).start, visible)
        XCTAssertEqual(try XCTUnwrap(slides.first).end, target)
    }

}
