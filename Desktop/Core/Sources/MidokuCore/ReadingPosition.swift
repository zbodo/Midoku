import Foundation

public enum ReadingDirection: String, Codable, CaseIterable, Sendable {
    case leftToRight, rightToLeft
}

public enum PageLayout: String, Codable, CaseIterable, Sendable {
    case single, spread, continuous
}

public struct ReadingPosition: Equatable, Sendable {
    public let count: Int
    public private(set) var page: Int
    public var layout: PageLayout
    public var coverIsSingle: Bool

    public init(count: Int, page: Int = 0, layout: PageLayout = .single, coverIsSingle: Bool = true) {
        self.count = max(0, count)
        self.page = min(max(0, page), max(0, count - 1))
        self.layout = layout
        self.coverIsSingle = coverIsSingle
        seek(self.page)
    }

    public var visiblePages: [Int] {
        guard count > 0 else { return [] }
        guard layout == .spread, !(coverIsSingle && page == 0), page + 1 < count else { return [page] }
        return [page, page + 1]
    }

    public mutating func seek(_ value: Int) {
        let clamped = min(max(0, value), max(0, count - 1))
        if layout == .spread {
            let start = coverIsSingle ? 1 : 0
            page = clamped < start ? 0 : start + ((clamped - start) / 2) * 2
        } else {
            page = clamped
        }
    }

    public mutating func advance() {
        guard let last = visiblePages.last, last + 1 < count else { return }
        seek(last + 1)
    }

    public mutating func retreat() {
        seek(page - (layout == .spread ? 2 : 1))
    }
}

// Pure input policies shared by all layouts; AppKit translates native events.
public enum ReaderClickAction: Equatable, Sendable { case previous, next, controls }
public enum ReaderInputPolicy {
    public static func click(
        at fraction: Double, direction: ReadingDirection, layout: PageLayout,
        enabled: Bool = true, swapSides: Bool = false
    ) -> ReaderClickAction {
        guard enabled, layout != .continuous, fraction < 0.375 || fraction > 0.625 else { return .controls }
        let left = fraction < 0.375
        let next = (direction == .rightToLeft ? left : !left) != swapSides
        return next ? .next : .previous
    }
}

public struct WheelTurnGate: Sendable {
    private var lastEvent: Double?
    private var accumulated: Double = 0
    private var turned = false
    private var direction: Double = 0
    public init() {}
    public mutating func reset() { self = Self() }
    // A burst must start at the boundary: scrolling to the edge cannot turn in
    // the same gesture. Inertia never starts another burst or commits a turn.
    public mutating func consume(
        delta: Double, time: Double, precise: Bool,
        began: Bool, ended: Bool, momentum: Bool, canScroll: Bool, phased: Bool = false
    ) -> Int? {
        let newBurst = began || lastEvent == nil || (!phased && !momentum && time - (lastEvent ?? time) > 0.22)
        if newBurst {
            accumulated = 0
            turned = false
            direction = 0
        }
        lastEvent = time
        if canScroll {
            turned = true
            accumulated = 0
            return nil
        }
        guard !momentum, !turned, !ended, delta != 0 else { return nil }
        let sign: Double = delta > 0 ? 1 : -1
        if sign != direction {
            accumulated = 0
            direction = sign
        }
        accumulated += abs(delta)
        guard accumulated >= (precise ? 45 : 1) else { return nil }
        turned = true
        return sign > 0 ? 1 : -1
    }
}

public struct ReaderClickCandidate: Sendable {
    private let x: Double
    private let y: Double
    public private(set) var isClick = true
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public mutating func move(x: Double, y: Double) {
        if hypot(x - self.x, y - self.y) > 5 { isClick = false }
    }
}
