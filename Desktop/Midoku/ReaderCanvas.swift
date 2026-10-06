import AppKit
import MidokuCore
import QuartzCore
import SwiftUI

// Adaptive paging and continuous reading share the native viewport and input rules.
struct ReaderCanvas: NSViewRepresentable {
    @ObservedObject var session: ReaderSession
    let background: NSColor
    @AppStorage("reader.preloadPages") private var preloadPages = 2
    func makeNSView(context: Context) -> ComicScrollView { ComicScrollView(frame: .zero) }
    func updateNSView(_ scroll: ComicScrollView, context: Context) {
        scroll.configure(session: session, background: background, preloadPages: preloadPages)
    }
    static func dismantleNSView(_ scroll: ComicScrollView, coordinator: ()) { scroll.stop() }
}

@MainActor
final class ComicScrollView: NSScrollView {
    weak var session: ReaderSession?
    private let comic = ComicDocumentView()
    private var tasks: [Int: (UUID, Task<Void, Never>)] = [:]
    private var boundsObserver: NSObjectProtocol?
    private var revision: UUID?
    private var reloadToken: UUID?
    private var bookID: UUID?
    private var paths: [String] = []
    private var measuredSizes: [Int: NSSize] = [:]
    private let decoded = NSCache<NSNumber, NSImage>()
    private var failedPages: Set<Int> = []
    private var prefetched: Set<Int> = []
    private var extraPreloadPages = 2
    private var renderedPage: Int?
    private var transition: ComicTransitionView?
    private var transitionDirection: CGFloat = 1
    private var transitionTask: Task<Void, Never>?
    private var transitionPending = false
    private var mode: PageLayout?
    private var ordering: ReadingDirection?
    private var layingOut = false
    private var hasLayout = false
    private var wheel = WheelTurnGate()
    var displayedPages: [Int] { comic.items.map(\.page) }

    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        decoded.totalCostLimit = 128 * 1024 * 1024
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = comic
        comic.viewport = self
        contentView.postsBoundsChangedNotifications = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(session: ReaderSession, background: NSColor, preloadPages: Int = 2) {
        extraPreloadPages = min(20, max(0, preloadPages))
        self.session = session
        session.viewport = self
        session.window = window
        backgroundColor = background
        comic.pageBackground = background
        guard let book = session.book else { return }
        let navigated = revision != session.navigationRevision
        let reload = reloadToken != session.reloadToken
        let structureChanged =
            bookID != book.id || paths != book.pages || mode != session.position.layout
            || ordering != session.direction
        if navigated, !structureChanged, !reload, session.position.layout == .adaptive,
            let previous = renderedPage, previous != session.position.page
        {
            beginTransition(from: previous, to: session.position.page)
        } else if structureChanged || reload {
            clearTransition()
        }
        renderedPage = session.position.page
        revision = session.navigationRevision
        reloadToken = session.reloadToken
        if bookID != book.id || paths != book.pages || reload {
            measuredSizes = [:]
            decoded.removeAllObjects()
            failedPages = []
            prefetched = []
        }
        if structureChanged || reload {
            hasLayout = false
            for pending in tasks.values { pending.1.cancel() }
            tasks = [:]
            comic.cancelClick()
            comic.items = []
        }
        bookID = book.id
        paths = book.pages
        mode = session.position.layout
        ordering = session.direction
        layoutComic(resetPosition: navigated || structureChanged)
        loadVisiblePages()
        finishTransition()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        guard window != nil else {
            stop()
            return
        }
        session?.window = window
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scrolled() }
        }
    }
    func stop() {
        clearTransition()
        decoded.removeAllObjects()
        comic.cancelClick()
        for pending in tasks.values { pending.1.cancel() }
        tasks = [:]
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        if session?.viewport === self { session?.viewport = nil }
        session?.saveProgress()
    }
    override func layout() {
        super.layout()
        layoutComic(resetPosition: false)
        loadVisiblePages()
    }

    private func anchor() -> (page: Int, fraction: Double) {
        let top = contentView.bounds.minY
        let active =
            session?.position.layout == .continuous
            ? comic.items.first(where: { $0.rect.maxY > top + 1 }) ?? comic.items.last
            : comic.items.first(where: { $0.page == session?.position.page })
        guard let item = active else {
            return (session?.position.page ?? 0, session?.pageOffset ?? 0)
        }
        return (item.page, min(1, max(0, Double((top - item.rect.minY) / max(1, item.rect.height)))))
    }

    private func refreshVisiblePages() {
        guard let session, let book = session.book else { return }
        let pages: [Int]
        if session.position.layout == .continuous {
            pages = Array(book.pages.indices)
        } else {
            let available = contentView.bounds.size
            let width = max(1, Double(available.width) - 32)
            let height = max(1, Double(available.height) - 32)
            // Bound lookahead by the minimum readable width instead of scanning
            // or decoding the entire chapter whenever the window resizes.
            let limit = max(1, Int(width / AdaptivePageLayout.minimumPageWidth) + 1)
            let candidates = Array((session.position.page..<session.position.count).prefix(limit))
            let count = AdaptivePageLayout.pageCount(
                width: width, height: height,
                aspectRatios: candidates.map { page in
                    let size = measuredSizes[page] ?? NSSize(width: 1000, height: 1400)
                    return Double(size.width / size.height)
                })
            let logical = Array(candidates.prefix(count))
            pages = session.direction == .rightToLeft ? Array(logical.reversed()) : logical
        }
        let old = Dictionary(uniqueKeysWithValues: comic.items.map { ($0.page, $0) })
        if displayedPages != pages {

            comic.cancelClick()
            comic.items = pages.map { page in
                if let previous = old[page] { return previous }
                var item = ComicPageItem(page: page, url: session.library.pageURL(for: book, at: page))
                if let size = measuredSizes[page] { item.size = size }
                item.image = decoded.object(forKey: NSNumber(value: page))
                item.failed = failedPages.contains(page)
                return item
            }
        }
        let count = session.position.layout == .continuous ? 1 : pages.count
        if session.position.pageCapacity != max(1, count) {
            let revision = session.navigationRevision
            let layout = session.position.layout
            // Publishing during a representable update is unsafe. Validate the
            // result again after yielding so an old resize cannot overwrite a seek.
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.session === session,
                    session.navigationRevision == revision, session.position.layout == layout,
                    (layout == .continuous ? 1 : self.comic.items.count) == count
                else { return }
                session.updateVisiblePageCount(count)
            }
        }
    }

    func layoutComic(resetPosition: Bool) {
        guard !layingOut, let session else { return }
        let viewport = contentView.bounds.size
        guard viewport.width > 32, viewport.height > 32 else { return }
        layingOut = true
        defer { layingOut = false }
        let restoring = resetPosition || !hasLayout
        let saved = restoring ? (page: session.position.page, fraction: session.pageOffset) : anchor()
        refreshVisiblePages()
        guard !comic.items.isEmpty else { return }
        let oldWidth = max(1, comic.frame.width)
        let horizontal = contentView.bounds.midX / oldWidth
        var totalWidth: CGFloat = viewport.width
        var totalHeight: CGFloat = viewport.height
        if session.position.layout == .continuous {
            var y: CGFloat = 16
            for i in comic.items.indices {
                let size = comic.items[i].size
                let scale: CGFloat
                switch session.zoom {
                case .page: scale = min(1000, viewport.width - 32) / size.width
                case .width: scale = (viewport.width - 32) * session.widthRatio / size.width
                case .actual: scale = 1
                case .custom(let value): scale = value
                }
                let width = max(1, size.width * scale)
                let height = max(1, size.height * scale)
                comic.items[i].rect = NSRect(x: 0, y: y, width: width, height: height)
                y += height + 12
                totalWidth = max(totalWidth, width + 32)
            }
            totalHeight = max(totalHeight, y + 4)
            for i in comic.items.indices {
                comic.items[i].rect.origin.x = (totalWidth - comic.items[i].rect.width) / 2
            }
        } else {
            let gap = CGFloat(AdaptivePageLayout.gap)
            let spacing = gap * CGFloat(max(0, comic.items.count - 1))
            let aspects = comic.items.map { $0.size.width / $0.size.height }
            let totalAspect = aspects.reduce(CGFloat(0), +)
            let sizes: [NSSize]
            let slotWidths: [CGFloat]
            switch session.zoom {
            case .page:
                let slotAspects = aspects.map { CGFloat(AdaptivePageLayout.slotAspectRatio(Double($0))) }
                let height = min(
                    viewport.height - 32,
                    max(1, viewport.width - 32 - spacing) / slotAspects.reduce(CGFloat(0), +))
                slotWidths = slotAspects.map { $0 * height }
                sizes = aspects.enumerated().map { index, aspect in
                    let imageHeight = min(height, slotWidths[index] / aspect)
                    return NSSize(width: aspect * imageHeight, height: imageHeight)
                }
            case .width:
                let height = max(1, (viewport.width - 32) * session.widthRatio - spacing) / totalAspect
                sizes = aspects.map { NSSize(width: $0 * height, height: height) }
                slotWidths = sizes.map(\.width)
            case .actual:
                sizes = comic.items.map(\.size)
                slotWidths = sizes.map(\.width)
            case .custom(let scale):
                sizes = comic.items.map { NSSize(width: $0.size.width * scale, height: $0.size.height * scale) }
                slotWidths = sizes.map(\.width)
            }
            let rowWidth = slotWidths.reduce(CGFloat(0), +) + spacing
            let rowHeight = sizes.map(\.height).max() ?? 1
            totalWidth = max(totalWidth, rowWidth + 32)
            totalHeight = max(totalHeight, rowHeight + 32)
            var x = (totalWidth - rowWidth) / 2
            for i in comic.items.indices {
                let size = sizes[i]
                comic.items[i].rect = NSRect(
                    x: x + (slotWidths[i] - size.width) / 2, y: (totalHeight - size.height) / 2,
                    width: size.width, height: size.height)
                x += slotWidths[i] + gap
            }
        }
        let newSize = NSSize(width: totalWidth, height: totalHeight)
        let geometryChanged = comic.frame.size != newSize
        if geometryChanged { comic.setFrameSize(newSize) }
        if restoring || geometryChanged {
            if let item = comic.items.first(where: { $0.page == saved.page }) {
                let x =
                    restoring
                    ? (totalWidth - viewport.width) / 2 : horizontal * totalWidth - viewport.width / 2
                scrollTo(
                    x: x,
                    y: item.rect.minY + CGFloat(saved.fraction) * item.rect.height
                        - (saved.fraction == 0 ? 16 : 0))
            }
        }
        hasLayout = true
        if let item = comic.items.first(where: { $0.page == session.position.page }) {
            session.displayedScale = item.rect.width / item.size.width
        }
        comic.updateLoadingIndicators()
        comic.needsDisplay = true
        reflectScrolledClipView(contentView)
    }

    private func scrollTo(x: CGFloat, y: CGFloat) {
        contentView.scroll(
            to: NSPoint(
                x: min(max(0, x), max(0, comic.frame.width - contentView.bounds.width)),
                y: min(max(0, y), max(0, comic.frame.height - contentView.bounds.height))))
        reflectScrolledClipView(contentView)
    }
    func scrollScreen(forward: Bool) {
        scrollTo(
            x: contentView.bounds.minX,
            y: contentView.bounds.minY + (forward ? 1 : -1) * contentView.bounds.height * 0.9)
        scrolled()
    }
    private func scrolled() {
        guard !layingOut, window != nil else { return }
        loadVisiblePages()
        comic.updateLoadingIndicators()
        let current = anchor()
        session?.didScroll(
            page: current.page, offset: current.fraction,
            reachedEnd: contentView.bounds.maxY >= comic.frame.height - 2)
    }

    private func loadVisiblePages() {
        guard window != nil, !layingOut, let session, let book = session.book else { return }
        let range = contentView.bounds
        let visible = comic.items.filter { $0.rect.intersects(range) }.map(\.page)
        let nearby: [Int]
        if session.position.layout == .adaptive {
            nearby = ReaderPrefetchPolicy.pages(
                count: book.pages.count, page: session.position.page, visibleCount: comic.items.count,
                extraPages: extraPreloadPages)
        } else {
            let first = visible.min() ?? session.position.page
            let last = visible.max() ?? first
            nearby = ReaderPrefetchPolicy.pages(
                count: book.pages.count, page: first, visibleCount: last - first + 1,
                extraPages: extraPreloadPages)
        }
        let wanted = Set(nearby)
        prefetched.formIntersection(wanted)
        for page in Array(tasks.keys) where !wanted.contains(page) {
            tasks.removeValue(forKey: page)?.1.cancel()
        }
        for i in comic.items.indices where !wanted.contains(comic.items[i].page) {
            comic.items[i].image = nil
        }
        // Current pages always get the limited decoding slots before neighbours.
        let priority =
            visible
            + nearby.filter { !visible.contains($0) }.sorted {
                abs($0 - session.position.page) < abs($1 - session.position.page)
            }
        for page in priority {
            if let image = decoded.object(forKey: NSNumber(value: page)) {
                if let index = comic.items.firstIndex(where: { $0.page == page }) {
                    comic.items[index].image = image
                    comic.items[index].size = image.size
                }
                continue
            }
            if comic.items.contains(where: { $0.page == page && $0.image != nil }) { continue }
            if !visible.contains(page), prefetched.contains(page) { continue }
            guard tasks.count < 4 else { break }
            guard tasks[page] == nil, !failedPages.contains(page),
                let url = session.library.pageURL(for: book, at: page)
            else { continue }
            let token = UUID()
            prefetched.insert(page)
            let task = Task { @MainActor [weak self] in
                do {
                    let preview = try await PageImages.shared.preview(for: url)
                    try Task.checkCancellation()
                    guard let image = preview.image(), image.size.width > 0, image.size.height > 0 else {
                        throw ImportFailure.empty
                    }
                    guard let self, self.tasks[page]?.0 == token else { return }
                    let pixels =
                        image.representations.map {
                            max(1, $0.pixelsWide) * max(1, $0.pixelsHigh)
                        }.max() ?? 1
                    self.decoded.setObject(image, forKey: NSNumber(value: page), cost: pixels * 4)
                    self.measuredSizes[page] = image.size
                    if let index = self.comic.items.firstIndex(where: { $0.page == page }) {
                        self.comic.items[index].image = image
                        self.comic.items[index].size = image.size
                    }
                } catch is CancellationError {} catch {
                    guard let self, self.tasks[page]?.0 == token else { return }
                    self.failedPages.insert(page)
                    if let index = self.comic.items.firstIndex(where: { $0.page == page }) {
                        self.comic.items[index].failed = true
                    }
                }
                guard let self, self.tasks[page]?.0 == token else { return }
                self.tasks[page] = nil
                self.layoutComic(resetPosition: false)
                self.scrolled()
                self.finishTransition()
            }
            tasks[page] = (token, task)
        }
    }

    private func transitionPages() -> [ComicTransitionPage] {
        comic.items.map { item in
            let rect = comic.convert(item.rect, to: contentView)
            return ComicTransitionPage(
                page: item.page, image: item.image,
                rect: rect.offsetBy(dx: -contentView.bounds.minX, dy: -contentView.bounds.minY))
        }
    }
    private func beginTransition(from previous: Int, to next: Int) {
        if transitionPending, transition != nil {
            transitionDirection = (next > previous ? 1 : -1) * (session?.direction == .rightToLeft ? 1 : -1)
            return
        }
        let pages = transition?.snapshotPages ?? transitionPages()
        // An interrupted animation is replaced by the most recent target;
        // never queue keyboard repeats behind a long animation.
        clearTransition()
        guard !pages.isEmpty else { return }
        let overlay = ComicTransitionView(frame: contentView.frame)
        overlay.wantsLayer = true
        overlay.layer?.masksToBounds = true
        overlay.layer?.isGeometryFlipped = true
        overlay.layer?.backgroundColor = backgroundColor.cgColor
        overlay.show(pages)
        addSubview(overlay, positioned: .above, relativeTo: contentView)
        transition = overlay
        transitionPending = true
        transitionDirection = (next > previous ? 1 : -1) * (session?.direction == .rightToLeft ? 1 : -1)
        // Placeholder pages participate in the turn and retain a live spinner.
    }
    private func finishTransition() {
        guard transitionPending, let overlay = transition else { return }
        transitionPending = false
        let incoming = transitionPages()
        if comic.items.contains(where: { $0.failed }) || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clearTransition()
            return
        }
        overlay.animate(to: incoming, direction: transitionDirection)
        transitionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(260)) } catch { return }
            self?.clearTransition()
        }
    }
    private func clearTransition() {
        transitionTask?.cancel()
        transitionTask = nil
        transition?.removeFromSuperview()
        transition = nil
        transitionPending = false
    }
    func click(at point: NSPoint) {
        guard let session else { return }
        let fraction = Double((point.x - contentView.bounds.minX) / max(1, contentView.bounds.width))
        let enabled = UserDefaults.standard.object(forKey: "reader.clickToTurn") as? Bool ?? true
        let action = ReaderInputPolicy.click(
            at: fraction, direction: session.direction, layout: session.position.layout,
            enabled: enabled, swapSides: UserDefaults.standard.bool(forKey: "reader.swapClickSides"))
        switch action {
        case .controls: session.perform(.toggleChrome)
        case .next: session.perform(.nextPage)
        case .previous: session.perform(.previousPage)
        }
    }
    func preview(at point: NSPoint) {
        if let page = comic.items.first(where: { $0.rect.contains(point) })?.page {
            session?.previewPage = page
        }
    }
    func retry(at point: NSPoint) -> Bool {
        guard let index = comic.items.firstIndex(where: { $0.failed && $0.rect.contains(point) }) else {
            return false
        }
        failedPages.remove(comic.items[index].page)
        comic.items[index].failed = false
        loadVisiblePages()
        return true
    }
    override func scrollWheel(with event: NSEvent) {
        guard let session else {
            super.scrollWheel(with: event)
            return
        }
        if event.modifierFlags.contains(.command) {
            session.zoom = .custom(
                min(8, max(0.05, session.displayedScale * exp(event.scrollingDeltaY / 100))))
            return
        }
        if session.position.layout == .continuous {
            wheel.reset()
            super.scrollWheel(with: event)
            return
        }
        // Positive here means scrolling down in content coordinates, regardless
        // of the user's macOS natural-scrolling preference.
        let delta = -event.scrollingDeltaY
        let rect = contentView.bounds
        let canScroll = delta > 0 ? rect.maxY < comic.frame.height - 1 : rect.minY > 1
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if horizontal {
            super.scrollWheel(with: event)
            return
        }
        let turn = wheel.consume(
            delta: Double(delta), time: event.timestamp, precise: event.hasPreciseScrollingDeltas,
            began: event.phase.contains(.began), ended: event.phase.contains(.ended),
            momentum: event.momentumPhase != [], canScroll: canScroll, phased: event.phase != [])
        if canScroll {
            super.scrollWheel(with: event)
            return
        }
        if let turn {
            // Reversal is for wheel paging of fitted pages; a tall/zoomed page
            // advances in its scroll direction once a new boundary gesture starts.
            let reversed =
                comic.frame.height <= contentView.bounds.height + 1
                && UserDefaults.standard.bool(forKey: "reader.reverseWheelPaging")
            session.perform((turn > 0) != reversed ? .nextPage : .previousPage)
        }
    }
    override func magnify(with event: NSEvent) {
        guard let session else { return }
        session.zoom = .custom(min(8, max(0.05, session.displayedScale * (1 + event.magnification))))
    }
}

private struct ComicPageItem {
    let page: Int
    let url: URL?
    var image: NSImage?
    var size = NSSize(width: 1000, height: 1400)
    var rect = NSRect.zero
    var failed = false
}

@MainActor
private final class ComicDocumentView: NSView {
    weak var viewport: ComicScrollView?
    var items: [ComicPageItem] = []
    var pageBackground = NSColor.black
    private var loadingIndicators: [Int: NSProgressIndicator] = [:]
    private var press: ReaderClickCandidate?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        pageBackground.setFill()
        dirtyRect.fill()
        for item in items where item.rect.intersects(dirtyRect) {
            if let image = item.image {
                image.draw(
                    in: item.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: nil)
            } else if item.failed {
                (String(localized: "Page could not be decoded. Click to retry.") as NSString).draw(
                    at: NSPoint(x: item.rect.minX + 16, y: max(visibleRect.minY + 24, item.rect.minY + 24)),
                    withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
            }
        }
    }
    func updateLoadingIndicators() {
        let loading = items.filter { $0.image == nil && !$0.failed && $0.rect.intersects(visibleRect) }
        let wanted = Set(loading.map(\.page))
        for page in Array(loadingIndicators.keys) where !wanted.contains(page) {
            loadingIndicators.removeValue(forKey: page)?.removeFromSuperview()
        }
        for item in loading {
            let indicator: NSProgressIndicator
            if let existing = loadingIndicators[item.page] {
                indicator = existing
            } else {
                indicator = NSProgressIndicator()
                indicator.style = .spinning
                indicator.isIndeterminate = true
                indicator.setAccessibilityLabel(String(localized: "Loading page…"))
                addSubview(indicator)
                indicator.startAnimation(nil)
                loadingIndicators[item.page] = indicator
            }
            let area = item.rect.intersection(visibleRect)
            indicator.frame = NSRect(x: area.midX - 16, y: area.midY - 16, width: 32, height: 32)
        }
    }
    func cancelClick() { press = nil }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(viewport)
        cancelClick()
        press = ReaderClickCandidate(x: event.locationInWindow.x, y: event.locationInWindow.y)
    }
    override func mouseDragged(with event: NSEvent) {
        press?.move(x: event.locationInWindow.x, y: event.locationInWindow.y)
        if press?.isClick == false { cancelClick() }
    }
    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        guard press?.isClick == true else { return }
        let point = convert(event.locationInWindow, from: nil)
        if viewport?.retry(at: point) == true { return }
        viewport?.click(at: point)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        cancelClick()
        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        if let page = items.first(where: { $0.rect.contains(point) })?.page {
            let preview = NSMenuItem(
                title: String(localized: "Preview Image"), action: #selector(openPreview(_:)),
                keyEquivalent: "")
            preview.target = self
            preview.representedObject = page
            menu.addItem(preview)
        }
        for action in [ReaderAction.nextPage, .previousPage, .fitPage, .fitWidth, .actualSize] {
            let item = NSMenuItem(
                title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }
        return menu
    }
    @objc private func openPreview(_ sender: NSMenuItem) {
        viewport?.session?.previewPage = sender.representedObject as? Int
    }
    @objc private func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ReaderAction(rawValue: raw)
        else { return }
        viewport?.session?.perform(action)
    }
}

private struct ComicTransitionPage {
    let page: Int
    let image: NSImage?
    let rect: NSRect
}

@MainActor
private final class ComicTransitionView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var pages: [ComicTransitionPage] = []
    private var imageLayers: [Int: CALayer] = [:]
    var snapshotPages: [ComicTransitionPage] {
        pages.map { page in
            ComicTransitionPage(
                page: page.page, image: page.image,
                rect: imageLayers[page.page]?.presentation()?.frame ?? page.rect)
        }
    }

    func show(_ pages: [ComicTransitionPage]) {
        self.pages = pages
        for page in pages {
            let imageLayer = CALayer()
            imageLayer.contents = page.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.frame = page.rect
            layer?.addSublayer(imageLayer)
            imageLayers[page.page] = imageLayer
        }
    }
    func animate(to incoming: [ComicTransitionPage], direction: CGFloat) {
        for page in incoming where page.image == nil {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.isIndeterminate = true
            let area = page.rect.intersection(bounds)
            guard !area.isEmpty else { continue }
            indicator.frame = NSRect(x: area.midX - 16, y: area.midY - 16, width: 32, height: 32)
            addSubview(indicator)
            indicator.startAnimation(nil)
        }
        let distance = pages.first.map { $0.rect.width + CGFloat(AdaptivePageLayout.gap) } ?? bounds.width
        let destinations = Dictionary(uniqueKeysWithValues: incoming.map { ($0.page, $0) })
        for old in pages {
            guard let imageLayer = imageLayers[old.page] else { continue }
            let end = destinations[old.page]?.rect ?? old.rect.offsetBy(dx: direction * distance, dy: 0)
            move(imageLayer, from: old.rect, to: end, disappearing: destinations[old.page] == nil)
        }
        for page in incoming where imageLayers[page.page] == nil {
            let imageLayer = CALayer()
            imageLayer.contents = page.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            imageLayer.contentsGravity = .resizeAspect
            layer?.addSublayer(imageLayer)
            imageLayers[page.page] = imageLayer
            move(
                imageLayer, from: page.rect.offsetBy(dx: -direction * distance, dy: 0),
                to: page.rect, disappearing: false)
        }
        pages = incoming
    }
    private func move(_ imageLayer: CALayer, from start: NSRect, to end: NSRect, disappearing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = end
        imageLayer.opacity = disappearing ? 0 : 1
        CATransaction.commit()
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: NSPoint(x: start.midX, y: start.midY))
        position.toValue = NSValue(point: NSPoint(x: end.midX, y: end.midY))
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = NSValue(size: start.size)
        size.toValue = NSValue(size: end.size)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = disappearing ? 0 : 1
        let group = CAAnimationGroup()
        group.animations = [position, size, opacity]
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageLayer.add(group, forKey: "pageTurn")
    }
}
