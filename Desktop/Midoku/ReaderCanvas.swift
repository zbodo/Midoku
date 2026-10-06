import AppKit
import MidokuCore
import SwiftUI

struct ReaderCanvas: NSViewRepresentable {
    @ObservedObject var session: ReaderSession
    @EnvironmentObject private var shortcuts: ShortcutStore
    let background: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ComicScrollView {
        let scroll = ComicScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = ComicDocumentView()
        return scroll
    }

    func updateNSView(_ scroll: ComicScrollView, context: Context) {
        scroll.session = session
        scroll.shortcuts = shortcuts.map
        scroll.backgroundColor = background
        session.window = scroll.window
        guard let document = scroll.documentView as? ComicDocumentView, let book = session.book else { return }
        document.session = session
        document.pageBackground = background
        let pages =
            session.direction == .rightToLeft
            ? session.position.visiblePages.reversed().map { $0 } : session.position.visiblePages
        let urls = pages.compactMap { session.library.pageURL(for: book, at: $0) }
        let coordinator = context.coordinator
        if coordinator.urls != urls || coordinator.reloadToken != session.reloadToken {
            coordinator.reloadToken = session.reloadToken
            coordinator.urls = urls
            coordinator.task?.cancel()
            document.images = []
            document.needsDisplay = true
            coordinator.task = Task { @MainActor [weak scroll, weak document] in
                do {
                    var images: [NSImage] = []
                    for url in urls {
                        let preview = try await PageImages.shared.preview(for: url)
                        try Task.checkCancellation()
                        guard let image = preview.image() else { throw ImportFailure.empty }
                        images.append(image)
                    }
                    guard let scroll, let document else { return }
                    document.images = images
                    scroll.layoutComic(resetPosition: true)
                } catch is CancellationError {} catch {
                    session.errorMessage = "A page could not be loaded: \(error.localizedDescription)"
                }
            }
        }
        scroll.layoutComic(resetPosition: false)
    }

    static func dismantleNSView(_ nsView: ComicScrollView, coordinator: Coordinator) { coordinator.task?.cancel() }

    @MainActor final class Coordinator {
        var urls: [URL] = []
        var reloadToken: UUID?
        var task: Task<Void, Never>?
    }
}

final class ComicScrollView: NSScrollView {
    weak var session: ReaderSession?
    var shortcuts = ShortcutMap()
    var zoomAnchor: (fraction: NSPoint, viewport: NSPoint)?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        session?.window = window
    }

    override func layout() {
        super.layout()
        layoutComic(resetPosition: false)
    }

    func layoutComic(resetPosition: Bool) {
        guard let session, let document = documentView as? ComicDocumentView, !document.images.isEmpty else { return }
        let viewport = contentView.bounds.size
        let natural = document.naturalSize
        guard viewport.width > 0, viewport.height > 0, natural.width > 0, natural.height > 0 else { return }
        let scale: CGFloat
        switch session.zoom {
        case .page: scale = min((viewport.width - 32) / natural.width, (viewport.height - 32) / natural.height)
        case .width: scale = (viewport.width - 32) / natural.width
        case .actual: scale = 1
        case .custom(let value): scale = value
        }
        let oldSize = document.frame.size
        let center = CGPoint(
            x: contentView.bounds.midX / max(1, oldSize.width), y: contentView.bounds.midY / max(1, oldSize.height))
        document.scale = max(0.01, scale)
        session.displayedScale = document.scale
        let newSize = NSSize(
            width: max(viewport.width, natural.width * document.scale + 32),
            height: max(viewport.height, natural.height * document.scale + 32))
        if oldSize != newSize { document.setFrameSize(newSize) }
        if resetPosition {
            zoomAnchor = nil
            contentView.scroll(to: NSPoint(x: max(0, (document.frame.width - viewport.width) / 2), y: 0))
        } else if oldSize != document.frame.size {
            if let anchor = zoomAnchor {
                contentView.scroll(
                    to: NSPoint(
                        x: anchor.fraction.x * document.frame.width - anchor.viewport.x,
                        y: anchor.fraction.y * document.frame.height - anchor.viewport.y))
                zoomAnchor = nil
            } else {
                contentView.scroll(
                    to: NSPoint(
                        x: center.x * document.frame.width - viewport.width / 2,
                        y: center.y * document.frame.height - viewport.height / 2))
            }
        }
        reflectScrolledClipView(contentView)
        document.needsDisplay = true
        document.window?.invalidateCursorRects(for: document)
    }

    override func keyDown(with event: NSEvent) {
        let binding = KeyBinding(event: event)
        if let action = shortcuts.action(for: binding) {
            session?.perform(action)
            return
        }
        if binding.modifiers.isEmpty {
            if event.keyCode == 123 {
                session?.horizontalArrow(left: true)
                return
            }
            if event.keyCode == 124 {
                session?.horizontalArrow(left: false)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Normal wheel/trackpad input scrolls. Command-wheel zooms instead of
        // accidentally turning a page; trackpad pinch uses the same zoom model.
        if event.modifierFlags.contains(.command), let session {
            session.zoom = .custom(min(8, max(0.01, session.displayedScale * exp(event.scrollingDeltaY / 100))))
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let session else { return }
        session.zoom = .custom(min(8, max(0.01, session.displayedScale * (1 + event.magnification))))
    }
}

final class ComicDocumentView: NSView {
    weak var session: ReaderSession?
    var pageBackground = NSColor.black
    var images: [NSImage] = []
    var scale: CGFloat = 1
    private var dragStart: NSPoint?
    private var initialOrigin: NSPoint = .zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var naturalSize: NSSize {
        NSSize(width: images.reduce(0) { $0 + $1.size.width }, height: images.map(\.size.height).max() ?? 0)
    }

    override func draw(_ dirtyRect: NSRect) {
        pageBackground.setFill()
        bounds.fill()
        let size = naturalSize
        var x = max(16, (bounds.width - size.width * scale) / 2)
        for image in images {
            let height = image.size.height * scale
            let rect = NSRect(
                x: x, y: max(16, (bounds.height - height) / 2), width: image.size.width * scale, height: height)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += rect.width
        }
        if images.isEmpty {
            (String(localized: "Loading page…") as NSString).draw(
                at: NSPoint(x: 24, y: 24), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    override func resetCursorRects() {
        if let scroll = enclosingScrollView,
            frame.width > scroll.contentSize.width + 1 || frame.height > scroll.contentSize.height + 1
        {
            addCursorRect(visibleRect, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView as? ComicScrollView else { return }
        window?.makeFirstResponder(scroll)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            scroll.zoomAnchor = (
                NSPoint(x: point.x / max(1, frame.width), y: point.y / max(1, frame.height)),
                NSPoint(x: point.x - scroll.contentView.bounds.minX, y: point.y - scroll.contentView.bounds.minY)
            )
            session?.zoom = session?.zoom == .actual ? .page : .actual
            return
        }
        dragStart = event.locationInWindow
        initialOrigin = scroll.contentView.bounds.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scroll = enclosingScrollView else { return }
        NSCursor.closedHand.set()
        let delta = NSPoint(x: event.locationInWindow.x - start.x, y: event.locationInWindow.y - start.y)
        scroll.contentView.scroll(to: NSPoint(x: initialOrigin.x - delta.x, y: initialOrigin.y + delta.y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for action in [ReaderAction.nextPage, .previousPage, .fitPage, .fitWidth, .actualSize] {
            let item = NSMenuItem(title: action.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let action = ReaderAction(rawValue: value) else {
            return
        }
        session?.perform(action)
    }
}
