import AppKit
import MidokuCore
import SwiftUI

struct ReaderContainer: View {
    let book: ComicBook
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @State private var prepared = false
    @State private var contentRevision = UUID()
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    var body: some View {
        Group {
            if prepared {
                VStack(spacing: 0) {
                    if let error {
                        HStack {
                            Text(error)
                            Spacer()
                            Button("Retry") { Task { await prepare() } }
                            Button("Sources…") { openWindow(id: "sources") }
                        }.padding(12)
                    }
                    ReaderWindowView(
                        book: library.book(book.id) ?? book, library: library, contentRevision: contentRevision)
                }
            } else if let error {
                VStack(spacing: 16) {
                    Text(error).textSelection(.enabled)
                    Button("Retry") { Task { await prepare() } }
                    Button("Read Cached Pages") { prepared = true }
                }.padding(30)
            } else {
                ProgressView("Preparing Chapter…")
            }
        }.task(
            id: book.online.flatMap { reference in
                sources.snapshot.installed.first(where: { $0.id == reference.sourceKey })?.folder
            }
        ) { await prepare() }
    }
    private func prepare() async {
        error = nil
        do {
            try await sources.prepare(book, library: library)
            try Task.checkCancellation()
            prepared = true
            contentRevision = UUID()
        } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct ReaderWindowView: View {
    let contentRevision: UUID
    @ObservedObject private var library: LibraryStore
    @StateObject private var session: ReaderSession
    @EnvironmentObject private var shortcuts: ShortcutStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("desktop.background") private var background = "dark"
    @State private var continuousPage: Int?

    init(book: ComicBook, library: LibraryStore, contentRevision: UUID) {
        self.contentRevision = contentRevision
        _library = ObservedObject(wrappedValue: library)
        _session = StateObject(wrappedValue: ReaderSession(book: book, library: library))
    }

    private var color: NSColor {
        switch background {
        case "light": .white
        case "system": .windowBackgroundColor
        default: NSColor(white: 0.08, alpha: 1)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if session.showPageList {
                List(0..<session.position.count, id: \.self) { page in
                    Button {
                        session.seek(page)
                    } label: {
                        HStack {
                            Text("Page \(page + 1)")
                            Spacer()
                            if session.position.visiblePages.contains(page) {
                                Image(systemName: "book.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
                .listStyle(.sidebar)
                .frame(width: 170)
                Divider()
            }
            VStack(spacing: 0) {
                ZStack {
                    if session.position.layout == .continuous {
                        continuousReader
                    } else {
                        ReaderCanvas(session: session, background: color)
                    }
                    if session.chromeVisible, session.position.layout != .continuous {
                        HStack {
                            pageButton(left: true)
                            Spacer()
                            pageButton(left: false)
                        }.padding(16)
                    }
                    if !session.chromeVisible {
                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    session.chromeVisible = true
                                } label: {
                                    Image(systemName: "toolbar")
                                }
                                .buttonStyle(.bordered).help("Show Controls")
                            }
                            Spacer()
                        }.padding(12)
                    }
                }
                if session.chromeVisible {
                    Divider()
                    HStack(spacing: 16) {
                        Button {
                            session.perform(.previousPage)
                        } label: {
                            Image(systemName: "backward.end")
                        }
                        .help("Previous Page").disabled(session.position.page == 0)
                        Slider(
                            value: Binding(
                                get: { Double(session.position.page) }, set: { session.seek(Int($0.rounded())) }),
                            in: 0...Double(max(1, session.position.count - 1)), step: 1
                        )
                        .disabled(session.position.count <= 1)
                        .accessibilityLabel("Page")
                        Text(session.pageLabel).monospacedDigit().font(.callout).frame(minWidth: 75)
                        Button {
                            session.perform(.nextPage)
                        } label: {
                            Image(systemName: "forward.end")
                        }
                        .help("Next Page").disabled(session.position.visiblePages.last == session.position.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
        .background(Color(nsColor: color))
        .preferredColorScheme(background == "dark" ? .dark : background == "light" ? .light : nil)
        .background(ReaderKeyboardScope(session: session, shortcuts: shortcuts.map))
        .navigationTitle(session.title)
        .navigationSubtitle(session.pageLabel)
        .focusedSceneValue(\.readerSession, session)
        .toolbar(session.chromeVisible ? .visible : .hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    session.showPageList.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Page List")
                Button {
                    openWindow(id: "library")
                } label: {
                    Image(systemName: "books.vertical")
                }
                .help("Show Library")
            }
            ToolbarItemGroup {
                if let reference = session.book?.online {
                    Button {
                        openWindow(
                            id: "manga",
                            value: SourceMangaLink(
                                sourceKey: reference.sourceKey, mangaKey: reference.mangaKey,
                                title: reference.mangaTitle, cover: reference.cover))
                    } label: {
                        Image(systemName: "list.bullet")
                    }.help("Chapters")
                }
                Picker("Page Layout", selection: Binding(get: { session.position.layout }, set: session.setLayout)) {
                    Text("Single Page").tag(PageLayout.single)
                    Text("Two Pages").tag(PageLayout.spread)
                    Text("Continuous").tag(PageLayout.continuous)
                }.frame(width: 130)
                Menu {
                    Picker("Reading Direction", selection: $session.direction) {
                        Text("Right to Left").tag(ReadingDirection.rightToLeft)
                        Text("Left to Right").tag(ReadingDirection.leftToRight)
                    }
                    Toggle(
                        "Single Cover Page",
                        isOn: Binding(get: { session.position.coverIsSingle }, set: session.setSingleCover))
                    Divider()
                    ForEach([ReaderAction.fitPage, .fitWidth, .actualSize, .zoomIn, .zoomOut], id: \.self) { action in
                        Button(action.title) { session.perform(action) }
                    }
                    Divider()
                    Button("Hide Controls") { session.chromeVisible = false }
                    Button("Full Screen") { session.perform(.toggleFullScreen) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Reader Options")
            }
        }
        .onAppear {
            session.revealLibrary = { openWindow(id: "library") }
            continuousPage = session.position.page
            session.saveProgress()
        }
        .onChange(of: contentRevision) { _, revision in session.reloadToken = revision }
        .onChange(of: library.book(session.bookID)?.pages.count) { _, count in
            if let count { session.updatePageCount(count) }
        }
        .onDisappear { session.saveProgress() }
        .alert(
            "Unable to Load Page",
            isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })
        ) {
            Button("Retry") {
                session.errorMessage = nil
                session.reloadToken = UUID()
            }
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private func pageButton(left: Bool) -> some View {
        let next = session.direction == .rightToLeft ? left : !left
        return Button {
            session.perform(next ? .nextPage : .previousPage)
        } label: {
            Image(systemName: left ? "chevron.left" : "chevron.right")
                .font(.title3).frame(width: 36, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(next ? "Next Page" : "Previous Page")
        .accessibilityLabel(next ? "Next Page" : "Previous Page")
        .disabled(next ? session.position.visiblePages.last == session.position.count - 1 : session.position.page == 0)
    }

    private var continuousReader: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 12) {
                    if let book = session.book {
                        ForEach(book.pages.indices, id: \.self) { page in
                            ContinuousComicPage(
                                url: session.library.pageURL(for: book, at: page), session: session,
                                viewport: geometry.size.width
                            )
                            .id(page)
                            .accessibilityLabel("Page \(page + 1)")
                        }
                    }
                }
                .scrollTargetLayout()
                .frame(minWidth: geometry.size.width)
                .padding(.vertical, 12)
            }
            .scrollPosition(id: $continuousPage, anchor: .top)
            .onChange(of: continuousPage) { _, page in
                if let page, page != session.position.page { session.seek(page) }
            }
            .onChange(of: session.position.page) { _, page in
                if continuousPage != page { continuousPage = page }
            }
        }
    }

}

private struct ContinuousComicPage: View {
    let url: URL?
    @ObservedObject var session: ReaderSession
    let viewport: CGFloat
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(width: width(for: image))
            } else if failed {
                VStack {
                    Label("Page could not be decoded", systemImage: "exclamationmark.triangle")
                    Button("Retry") { session.reloadToken = UUID() }
                }.foregroundStyle(.secondary).frame(width: max(100, viewport - 32), height: 240)
            } else {
                ProgressView().frame(width: max(100, viewport - 32), height: 240)
            }
        }
        .task(id: "\(url?.absoluteString ?? "")-\(session.reloadToken)") {
            failed = false
            guard let url else {
                failed = true
                return
            }
            do {
                let preview = try await PageImages.shared.preview(for: url)
                try Task.checkCancellation()
                image = preview.image()
                failed = image == nil
                if let image { session.displayedScale = width(for: image) / max(1, image.size.width) }
            } catch is CancellationError {} catch { failed = true }
        }
        .onDisappear { image = nil }
    }

    private func width(for image: NSImage) -> CGFloat {
        switch session.zoom {
        case .page: min(1000, max(100, viewport - 32))
        case .width: max(100, viewport - 32)
        case .actual: image.size.width
        case .custom(let value): image.size.width * value
        }
    }
}

// Monitor only this reader window. Text fields, sheets, controls, other reader
// windows and Settings retain their normal key handling.
private struct ReaderKeyboardScope: NSViewRepresentable {
    let session: ReaderSession
    let shortcuts: ShortcutMap
    func makeNSView(context: Context) -> ScopeView {
        let view = ScopeView()
        view.session = session
        view.shortcuts = shortcuts
        return view
    }
    func updateNSView(_ view: ScopeView, context: Context) {
        view.session = session
        view.shortcuts = shortcuts
        session.window = view.window
    }
    static func dismantleNSView(_ view: ScopeView, coordinator: ()) { view.stop() }

    final class ScopeView: NSView {
        weak var session: ReaderSession?
        var shortcuts = ShortcutMap()
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            session?.window = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let readerWindow = self.window, event.window === readerWindow,
                    readerWindow.attachedSheet == nil, NSApp.modalWindow == nil,
                    !(readerWindow.firstResponder is NSTextView), !(readerWindow.firstResponder is NSControl)
                else { return event }
                let binding = KeyBinding(event: event)
                if let action = self.shortcuts.action(for: binding) {
                    self.session?.perform(action)
                    return nil
                }
                if binding.modifiers.isEmpty, event.keyCode == 123 || event.keyCode == 124 {
                    self.session?.horizontalArrow(left: event.keyCode == 123)
                    return nil
                }
                return event
            }
        }
        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
