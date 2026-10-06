#if targetEnvironment(macCatalyst)
import UIKit

/// Desktop input uses the existing reader actions, including RTL and chapter transitions.
@MainActor
final class CatalystReaderInput: NSObject, UIGestureRecognizerDelegate {
    private weak var owner: ReaderViewController?
    private let wheel = UIPanGestureRecognizer()
    private let trackpad = UIPanGestureRecognizer()
    private let drag = UIPanGestureRecognizer()
    private var paging = ReaderScrollPagingPolicy()

    init(owner: ReaderViewController) {
        self.owner = owner
        super.init()
        for (gesture, mask) in [(wheel, UIScrollTypeMask.discrete), (trackpad, UIScrollTypeMask.continuous)] {
            gesture.allowedTouchTypes = []
            gesture.allowedScrollTypesMask = mask
            gesture.delegate = self
            gesture.addTarget(self, action: #selector(scrolled(_:)))
            owner.view.addGestureRecognizer(gesture)
        }
        drag.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        drag.delegate = self
        drag.addTarget(self, action: #selector(dragged(_:)))
        owner.view.addGestureRecognizer(drag)
        func prioritizeDrag(in view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is ZoomableScrollView) {
                scroll.panGestureRecognizer.require(toFail: drag)
            }
            view.subviews.forEach(prioritizeDrag)
        }
        prioritizeDrag(in: owner.view)
    }

    var acceptsKeyboardCommands: Bool {
        guard let owner, owner.view.window?.isKeyWindow == true,
              owner.presentedViewController == nil else { return false }
        return !Self.hasFocusedControl(in: owner.view.window)
    }

    private static func hasFocusedControl(in view: UIView?) -> Bool {
        guard let view else { return false }
        if view.isFirstResponder && (view is UIControl || view is UITextView || view is UISearchBar) { return true }
        return view.subviews.contains { hasFocusedControl(in: $0) }
    }

    private var activeImageScrollViews: [ZoomableScrollView] {
        guard let owner else { return [] }
        func find(_ view: UIView) -> [ZoomableScrollView] {
            if let scroll = view as? ZoomableScrollView,
               scroll.window != nil, !scroll.isHidden,
               scroll.convert(scroll.bounds, to: owner.view).intersects(owner.view.bounds) {
                return [scroll]
            }
            return view.subviews.flatMap(find)
        }
        return find(owner.view)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let owner, owner.presentedViewController == nil,
              owner.reader is ReaderPagedViewController || owner.reader is ReaderPagedTextViewController,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: owner.view)
        let movement = velocity == .zero ? pan.translation(in: owner.view) : velocity
        let horizontalScroll = pan !== drag && (owner.reader as? ReaderPagedViewController)?.usesSlidingDoublePages == true
            && abs(movement.x) > abs(movement.y)
        if (pan === drag && owner.readingMode != .vertical) || horizontalScroll {
            guard abs(movement.x) > abs(movement.y) else { return false }
            return activeImageScrollViews.allSatisfy {
                $0.zoomScale <= $0.minimumZoomScale + 0.01 && $0.contentSize.width <= $0.bounds.width + 1
            }
        }
        guard abs(movement.y) > abs(movement.x) else { return false }
        // Native scrolling owns zoomed images and long pages until a new gesture starts at an edge.
        let location = pan.location(in: owner.view)
        let images = activeImageScrollViews.filter {
            $0.convert($0.bounds, to: owner.view).contains(location)
        }
        for scroll in images {
            let minY = -scroll.adjustedContentInset.top
            let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            guard ReaderScrollPagingPolicy.canTurnPage(velocity: movement.y, offset: scroll.contentOffset.y,
                                                       minimum: minY, maximum: maxY, zoomScale: scroll.zoomScale,
                                                       minimumZoomScale: scroll.minimumZoomScale) else { return false }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        gestureRecognizer === drag && !(touch.view is UIControl)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A fitted UIScrollView still recognizes scroll events even when it cannot scroll.
        // Let the reader receive those events; shouldBegin keeps scrolling images native.
        otherGestureRecognizer.view is UIScrollView && otherGestureRecognizer is UIPanGestureRecognizer
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard let owner else { return }
        switch gesture.state {
            case .began:
                paging.beginGesture()
                fallthrough
            case .changed:
                let translation = gesture.translation(in: owner.view)
                let horizontal = (owner.reader as? ReaderPagedViewController)?.usesSlidingDoublePages == true
                    && abs(translation.x) > abs(translation.y)
                let delta = horizontal ? -translation.x : -translation.y
                let threshold: CGFloat = gesture === wheel ? 1 : 45
                guard let forward = paging.pageTurn(delta: delta, threshold: threshold) else { return }
                if horizontal {
                    forward ? owner.moveRight() : owner.moveLeft()
                } else {
                    owner.desktopTurnPage(forward: forward)
                }
            default:
                break
        }
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, let owner else { return }
        let translation = gesture.translation(in: owner.view)
        if owner.readingMode == .vertical {
            guard abs(translation.y) >= 60 else { return }
            owner.desktopTurnPage(forward: translation.y < 0)
        } else {
            guard abs(translation.x) >= 60 else { return }
            translation.x > 0 ? owner.moveLeft() : owner.moveRight()
        }
    }

    func zoom(by multiplier: CGFloat) {
        for scroll in activeImageScrollViews {
            scroll.setZoomScale(min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.zoomScale * multiplier)), animated: true)
        }
    }
}
#endif
