import Foundation

/// A gesture may turn one page. Scrolling within an image keeps ownership until the next gesture.
struct ReaderScrollPagingPolicy {
    private var didTurn = false

    mutating func beginGesture() { didTurn = false }

    mutating func pageTurn(delta: CGFloat, threshold: CGFloat) -> Bool? {
        guard !didTurn, delta.isFinite, abs(delta) >= threshold else { return nil }
        didTurn = true
        return delta > 0
    }

    static func canTurnPage(velocity: CGFloat, offset: CGFloat, minimum: CGFloat, maximum: CGFloat,
                            zoomScale: CGFloat, minimumZoomScale: CGFloat) -> Bool {
        guard zoomScale <= minimumZoomScale + 0.01 else { return false }
        guard maximum - minimum > 1 else { return true }
        if velocity < 0 { return offset >= maximum - 1 }
        if velocity > 0 { return offset <= minimum + 1 }
        return false
    }
}
