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
        XCTAssertNil(
            gate.consume(
                delta: 25, time: 1, precise: true, began: true, ended: false, momentum: false, canScroll: false))
        XCTAssertEqual(
            gate.consume(
                delta: 25, time: 1.01, precise: true, began: false, ended: false, momentum: false, canScroll: false), 1)
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
    func testDiscreteMouseBurstAndDirectionReversal() {
        var gate = WheelTurnGate()
        XCTAssertEqual(
            gate.consume(
                delta: 3, time: 1, precise: false, began: false, ended: false, momentum: false, canScroll: false), 1)
        XCTAssertNil(
            gate.consume(
                delta: 3, time: 1.1, precise: false, began: false, ended: false, momentum: false, canScroll: false))
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
}
