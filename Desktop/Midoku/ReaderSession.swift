import AidokuRunner
import AppKit
import MidokuCore
import SwiftUI

enum ZoomMode: Equatable {
    case page, width, actual
    case custom(CGFloat)
}

@MainActor
final class ReaderSession: ObservableObject {
    let bookID: UUID
    let library: LibraryStore
    @Published private(set) var position: ReadingPosition
    @Published var direction: ReadingDirection {
        didSet { UserDefaults.standard.set(direction.rawValue, forKey: "desktop.direction") }
    }
    @Published var zoom: ZoomMode = .page
    @Published var chromeVisible = true
    @Published var showPageList = false
    @Published var showOverview = false
    @Published var showReadingSettings = false
    @Published var previewPage: Int?
    @Published var widthRatio: CGFloat = 1
    @Published private(set) var navigationRevision = UUID()
    private(set) var pageOffset: Double = 0
    weak var viewport: ComicScrollView?
    private var progressTask: Task<Void, Never>?
    private var reachedViewportEnd = false
    @Published var errorMessage: String?
    @Published var reloadToken = UUID()
    weak var window: NSWindow?
    var displayedScale: CGFloat = 1
    var revealLibrary: (() -> Void)?

    init(book: ComicBook, library: LibraryStore) {
        bookID = book.id
        self.library = library
        var initialDirection =
            ReadingDirection(rawValue: UserDefaults.standard.string(forKey: "desktop.direction") ?? "")
            ?? .rightToLeft
        var layout =
            PageLayout(rawValue: UserDefaults.standard.string(forKey: "desktop.layout") ?? "") ?? .single
        if let data = book.online?.mangaData,
            let manga = try? JSONDecoder().decode(AidokuRunner.Manga.self, from: data)
        {
            switch manga.viewer {
            case .leftToRight: initialDirection = .leftToRight
            case .rightToLeft: initialDirection = .rightToLeft
            case .vertical, .webtoon: layout = .continuous
            case .unknown: break
            }
        }
        direction = initialDirection
        position = ReadingPosition(count: book.pages.count, page: book.currentPage, layout: layout)
        pageOffset = min(1, max(0, book.pageOffset ?? 0))
    }

    var book: ComicBook? { library.book(bookID) }
    var title: String { book?.title ?? String(localized: "Reader") }
    var pageLabel: String {
        let pages = position.visiblePages
        let visible = pages.count == 2 ? "\(pages[0] + 1)–\(pages[1] + 1)" : "\(position.page + 1)"
        return "\(visible) / \(position.count)"
    }

    func updatePageCount(_ count: Int) {
        guard count > 0, count != position.count else { return }
        position = ReadingPosition(
            count: count, page: position.page, layout: position.layout,
            coverIsSingle: position.coverIsSingle)
        reloadToken = UUID()
        saveProgress()
    }

    func seek(_ page: Int) {
        position.seek(page)
        pageOffset = 0
        reachedViewportEnd = false
        navigationRevision = UUID()
        saveProgress()
    }

    func setLayout(_ layout: PageLayout) {
        position.layout = layout
        position.seek(position.page)
        UserDefaults.standard.set(layout.rawValue, forKey: "desktop.layout")
        navigationRevision = UUID()
        saveProgress()
    }

    func setSingleCover(_ enabled: Bool) {
        position.coverIsSingle = enabled
        position.seek(position.page)
        navigationRevision = UUID()
        saveProgress()
    }

    func perform(_ action: ReaderAction) {
        let currentScale: CGFloat
        if case .custom(let value) = zoom {
            currentScale = value
        } else {
            currentScale = displayedScale
        }
        switch action {
        case .nextPage:
            var next = position
            next.advance()
            seek(next.page)
        case .previousPage:
            var previous = position
            previous.retreat()
            seek(previous.page)
        case .nextScreen:
            if position.layout == .continuous {
                viewport?.scrollScreen(forward: true)
            } else {
                perform(.nextPage)
            }
        case .previousScreen:
            if position.layout == .continuous {
                viewport?.scrollScreen(forward: false)
            } else {
                perform(.previousPage)
            }
        case .increaseWidth:
            widthRatio = min(2, widthRatio + 0.05)
            zoom = .width
        case .decreaseWidth:
            widthRatio = max(0.3, widthRatio - 0.05)
            zoom = .width
        case .toggleThumbnails: showPageList.toggle()
        case .toggleOverview: showOverview.toggle()
        case .readingSettings: showReadingSettings.toggle()
        case .firstPage: seek(0)
        case .lastPage: seek(position.count - 1)
        case .zoomIn: zoom = .custom(min(8, currentScale * 1.25))
        case .zoomOut: zoom = .custom(max(0.01, currentScale / 1.25))
        case .actualSize: zoom = .actual
        case .fitPage: zoom = .page
        case .fitWidth:
            widthRatio = 1
            zoom = .width
        case .toggleChrome: chromeVisible.toggle()
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        case .showLibrary: revealLibrary?()
        }
    }

    func horizontalArrow(left: Bool) {
        let next = direction == .rightToLeft ? left : !left
        perform(next ? .nextPage : .previousPage)
    }

    func didScroll(page: Int, offset: Double, reachedEnd: Bool) {
        if position.layout == .continuous, position.page != page { position.seek(page) }
        reachedViewportEnd = reachedEnd
        pageOffset = min(1, max(0, offset))
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveProgress(reachedEnd: reachedEnd)
        }
    }

    func handleKey(_ binding: KeyBinding, shortcuts: ShortcutMap, repeatEvent: Bool) -> Bool {
        if binding.key == "\u{1b}", binding.modifiers.isEmpty {
            if previewPage != nil {
                previewPage = nil
            } else if showOverview {
                showOverview = false
            } else if showReadingSettings {
                showReadingSettings = false
            } else if showPageList {
                showPageList = false
            } else {
                chromeVisible = true
            }
            return true
        }
        guard let action = shortcuts.action(for: binding) else { return false }
        if repeatEvent && !action.allowsRepeat { return true }
        if UserDefaults.standard.bool(forKey: "reader.directionalArrows"), binding.modifiers.isEmpty,
            binding.key == "\u{f702}" || binding.key == "\u{f703}",
            action == .nextPage || action == .previousPage
        {
            horizontalArrow(left: binding.key == "\u{f702}")
        } else {
            perform(action)
        }
        return true
    }

    func saveProgress(reachedEnd: Bool = false) {
        progressTask?.cancel()
        let last = position.visiblePages.last == position.count - 1
        library.saveProgress(
            bookID, page: position.page,
            finished: last && (position.layout != .continuous || reachedEnd || reachedViewportEnd),
            offset: pageOffset)
    }
}

struct ReaderFocusKey: FocusedValueKey {
    typealias Value = ReaderSession
}

extension FocusedValues {
    var readerSession: ReaderSession? {
        get { self[ReaderFocusKey.self] }
        set { self[ReaderFocusKey.self] = newValue }
    }
}

extension ReaderAction {
    var title: String {
        switch self {
        case .nextPage: String(localized: "Next Page")
        case .previousPage: String(localized: "Previous Page")
        case .nextScreen: String(localized: "Scroll Forward a Screen")
        case .previousScreen: String(localized: "Scroll Back a Screen")
        case .increaseWidth: String(localized: "Increase Page Width")
        case .decreaseWidth: String(localized: "Decrease Page Width")
        case .toggleThumbnails: String(localized: "Show / Hide Thumbnails")
        case .toggleOverview: String(localized: "Page Overview")
        case .readingSettings: String(localized: "Reading Settings")
        case .firstPage: String(localized: "First Page")
        case .lastPage: String(localized: "Last Page")
        case .zoomIn: String(localized: "Zoom In")
        case .zoomOut: String(localized: "Zoom Out")
        case .actualSize: String(localized: "Actual Size")
        case .fitPage: String(localized: "Fit Page")
        case .fitWidth: String(localized: "Fit Width")
        case .toggleChrome: String(localized: "Show / Hide Controls")
        case .toggleFullScreen: String(localized: "Toggle Full Screen")
        case .showLibrary: String(localized: "Show Library")
        }
    }
}
