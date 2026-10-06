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
