import Foundation

public enum ReadingDirection: String, Codable, CaseIterable, Sendable {
    case leftToRight, rightToLeft
}

public enum PageLayout: String, Codable, CaseIterable, Sendable {
    case adaptive, continuous

    // Previous single/spread preferences now share the adaptive viewport.
    public static func preference(_ value: String?) -> Self {
        Self(rawValue: value ?? "") ?? .adaptive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "single", "spread", "adaptive": self = .adaptive
        case "continuous": self = .continuous
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown reading layout")
        }
    }
}

public struct ReadingPosition: Equatable, Sendable {
    public let count: Int
    public private(set) var page: Int
    public var layout: PageLayout
    public var pageCapacity: Int

    public init(count: Int, page: Int = 0, layout: PageLayout = .adaptive, pageCapacity: Int = 1) {
        self.count = max(0, count)
        self.page = min(max(0, page), max(0, count - 1))
        self.layout = layout
        self.pageCapacity = max(1, pageCapacity)
    }

    public var visiblePages: [Int] {
        guard count > 0 else { return [] }
        let capacity = layout == .adaptive ? max(1, pageCapacity) : 1
        return Array(page..<(page + min(capacity, count - page)))
    }

    public mutating func seek(_ value: Int) {
        page = min(max(0, value), max(0, count - 1))
    }

    // Navigation moves the leading page, independently of viewport capacity.
    public mutating func advance() { seek(page + 1) }
    public mutating func retreat() { seek(page - 1) }
}

public enum AdaptivePageLayout {
    public static let gap: Double = 12
    public static let minimumPageWidth: Double = 320
    public static let portraitAspectRatio: Double = 5.0 / 7.0

    public static func pageSpan(aspectRatio: Double) -> Int {
        aspectRatio.isFinite && aspectRatio > 1 ? 2 : 1
    }

    public static func slotAspectRatio(_ aspectRatio: Double) -> Double {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return portraitAspectRatio }
        return pageSpan(aspectRatio: aspectRatio) == 2 ? portraitAspectRatio * 2 : aspectRatio
    }

    // Fit as many readable pages as possible at the viewport's available height.
    // Unknown images use a portrait estimate until their dimensions are decoded.
    public static func pageCount(width: Double, height: Double, aspectRatios: [Double]) -> Int {
        guard !aspectRatios.isEmpty else { return 0 }
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 1 }
        var used: Double = 0
        var count = 0
        for aspect in aspectRatios {
            let span = Double(pageSpan(aspectRatio: aspect))
            let ratio = slotAspectRatio(aspect)
            let idealWidth = max(min(minimumPageWidth * span, width), height * ratio)
            let required = idealWidth + (count == 0 ? 0 : gap)
            if count > 0 && used + required > width { break }
            count += 1
            used += required
        }
        return count
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
    private var turned = false
    public init() {}
    public mutating func reset() { self = Self() }
    // A burst must start at the boundary: scrolling to the edge cannot turn in
    // the same gesture. Inertia never starts another burst or commits a turn.
    public mutating func consume(
        delta: Double, time: Double, precise: Bool,
        began: Bool, ended: Bool, momentum: Bool, canScroll: Bool, phased: Bool = false
    ) -> Int? {
        let newBurst =
            !precise || began || lastEvent == nil || (!phased && !momentum && time - (lastEvent ?? time) > 0.22)
        if newBurst {
            turned = false
        }
        lastEvent = time
        if canScroll {
            turned = true
            return nil
        }
        guard !momentum, !turned, !ended, delta != 0 else { return nil }
        turned = precise
        return delta > 0 ? 1 : -1
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

public enum ReaderPrefetchPolicy {
    public static func pages(count: Int, page: Int, visibleCount: Int, extraPages: Int = 2) -> [Int] {
        guard count > 0 else { return [] }
        let current = min(max(0, page), count - 1)
        let visible = min(max(1, visibleCount), count - current)
        let extra = min(20, max(0, extraPages))
        return Array(max(0, current - extra)..<min(count, current + visible + extra))
    }
}
