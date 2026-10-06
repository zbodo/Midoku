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
    @Published var errorMessage: String?
    @Published var reloadToken = UUID()
    weak var window: NSWindow?
    var displayedScale: CGFloat = 1
    var revealLibrary: (() -> Void)?

    init(book: ComicBook, library: LibraryStore) {
        bookID = book.id
        self.library = library
        var initialDirection =
            ReadingDirection(rawValue: UserDefaults.standard.string(forKey: "desktop.direction") ?? "") ?? .rightToLeft
        var layout = PageLayout(rawValue: UserDefaults.standard.string(forKey: "desktop.layout") ?? "") ?? .single
        if let data = book.online?.mangaData, let manga = try? JSONDecoder().decode(AidokuRunner.Manga.self, from: data)
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
            count: count, page: position.page, layout: position.layout, coverIsSingle: position.coverIsSingle)
        reloadToken = UUID()
        saveProgress()
    }

    func seek(_ page: Int) {
        position.seek(page)
        saveProgress()
    }

    func setLayout(_ layout: PageLayout) {
        position.layout = layout
        position.seek(position.page)
        UserDefaults.standard.set(layout.rawValue, forKey: "desktop.layout")
        saveProgress()
    }

    func setSingleCover(_ enabled: Bool) {
        position.coverIsSingle = enabled
        position.seek(position.page)
        saveProgress()
    }

    func perform(_ action: ReaderAction) {
        let currentScale: CGFloat
        if case .custom(let value) = zoom { currentScale = value } else { currentScale = displayedScale }
        switch action {
        case .nextPage:
            position.advance()
            saveProgress()
        case .previousPage:
            position.retreat()
            saveProgress()
        case .firstPage: seek(0)
        case .lastPage: seek(position.count - 1)
        case .zoomIn: zoom = .custom(min(8, currentScale * 1.25))
        case .zoomOut: zoom = .custom(max(0.01, currentScale / 1.25))
        case .actualSize: zoom = .actual
        case .fitPage: zoom = .page
        case .fitWidth: zoom = .width
        case .toggleChrome: chromeVisible.toggle()
        case .toggleFullScreen: window?.toggleFullScreen(nil)
        case .showLibrary: revealLibrary?()
        }
    }

    func horizontalArrow(left: Bool) {
        let next = direction == .rightToLeft ? left : !left
        perform(next ? .nextPage : .previousPage)
    }

    func saveProgress() {
        library.saveProgress(bookID, page: position.page, finished: position.visiblePages.last == position.count - 1)
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
