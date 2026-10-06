#if targetEnvironment(macCatalyst)
import UIKit

/// Three page slots move together while the shared live page is transferred to its new spread.
@MainActor
enum ReaderSpreadSlide {
    static func translation(width: CGFloat, forward: Bool, rightToLeft: Bool) -> CGFloat {
        width / 2 * (forward == rightToLeft ? 1 : -1)
    }

    static func overlaps(previous: ReaderDoublePageViewController, next: ReaderDoublePageViewController) -> Bool {
        previous.secondPageController === next.firstPageController
            || previous.firstPageController === next.secondPageController
    }

    static func animate(
        from previous: ReaderDoublePageViewController,
        to next: ReaderDoublePageViewController,
        in container: UIView,
        install: () -> Void,
        completion: @escaping () -> Void
    ) {
        previous.zoomView.setZoomScale(1, animated: false)
        previous.view.layoutIfNeeded()
        let overlay = UIView(frame: container.bounds)
        overlay.clipsToBounds = true
        overlay.backgroundColor = .systemBackground
        var ancestor: UIView? = previous.view
        while let view = ancestor {
            if let color = view.backgroundColor, color.cgColor.alpha > 0 {
                overlay.backgroundColor = color
                break
            }
            ancestor = view.superview
        }

        // Capture before installing: the two spreads deliberately reuse the retained page view.
        for controller in [previous.firstPageController, previous.secondPageController] {
            guard let page = controller.pageView,
                  let snapshot = page.snapshotView(afterScreenUpdates: false) else {
                install()
                completion()
                return
            }
            snapshot.frame = page.convert(page.bounds, to: container)
            overlay.addSubview(snapshot)
        }
        container.addSubview(overlay)
        previous.prepareForSlide()
        install()
        next.view.layoutIfNeeded()

        let forward = previous.secondPageController === next.firstPageController
        let offset = translation(width: container.bounds.width, forward: forward, rightToLeft: next.direction == .rtl)
        let incoming = forward ? next.secondPageController : next.firstPageController
        guard let page = incoming.pageView,
              let snapshot = page.snapshotView(afterScreenUpdates: true) else {
            overlay.removeFromSuperview()
            completion()
            return
        }
        snapshot.frame = page.convert(page.bounds, to: container).offsetBy(dx: -offset, dy: 0)
        overlay.addSubview(snapshot)

        // Moving the entire strip by one slot keeps the retained page on exactly the same trajectory.
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3,
                       delay: 0, options: [.curveEaseInOut]) {
            for page in overlay.subviews { page.frame.origin.x += offset }
        } completion: { _ in
            overlay.removeFromSuperview()
            completion()
        }
    }
}
#endif
