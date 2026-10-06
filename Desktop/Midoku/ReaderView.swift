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
        } catch is CancellationError {} catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

struct ReaderWindowView: View {
    let contentRevision: UUID
    @ObservedObject private var library: LibraryStore
    @StateObject private var session: ReaderSession
    @EnvironmentObject private var shortcuts: ShortcutStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("desktop.background") private var background = "dark"
    @AppStorage("reader.hintsSeen") private var hintsSeen = false
    @State private var showHelp = false

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
        readerContent
            .background(Color(nsColor: color))
            .preferredColorScheme(background == "dark" ? .dark : background == "light" ? .light : nil)
            .background(ReaderKeyboardScope(session: session, shortcuts: shortcuts.map))
            .navigationTitle(session.title)
            .navigationSubtitle(session.pageLabel)
            .focusedSceneValue(\.readerSession, session)
            .toolbar(session.chromeVisible ? .visible : .hidden, for: .windowToolbar)
            .toolbar { readerToolbar }
            .onAppear {
                session.revealLibrary = { openWindow(id: "library") }
                if !hintsSeen { showHelp = true }
                session.saveProgress()
            }
            .onChange(of: contentRevision) { _, revision in session.reloadToken = revision }
            .onChange(of: library.book(session.bookID)?.pages.count) { _, count in
                if let count { session.updatePageCount(count) }
            }
            .onChange(of: showHelp) { _, visible in if !visible { hintsSeen = true } }
            .onDisappear { session.saveProgress() }
            .sheet(isPresented: $session.showOverview) { ReaderPageOverview(session: session) }
            .sheet(isPresented: $session.showReadingSettings) { ReaderOptionsPanel(session: session) }
            .sheet(
                isPresented: Binding(
                    get: { session.previewPage != nil }, set: { if !$0 { session.previewPage = nil } })
            ) {
                if let page = session.previewPage, let book = session.book {
                    ReaderImagePreview(url: session.library.pageURL(for: book, at: page), page: page)
                }
            }
            .alert(
                "Unable to Load Page",
                isPresented: Binding(
                    get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })
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

    private var readerContent: some View {
        HStack(spacing: 0) {
            if session.showPageList {
                List(0..<session.position.count, id: \.self) { page in
                    Button {
                        session.seek(page)
                    } label: {
                        HStack {
                            if let book = session.book {
                                ComicImage(url: session.library.pageURL(for: book, at: page), maximumDimension: 240)
                                    .frame(width: 48, height: 64)
                            }
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
                .frame(width: 210)
                Divider()
            }
            VStack(spacing: 0) {
                ZStack {
                    ReaderCanvas(session: session, background: color)
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
                        .help("Next Page").disabled(
                            session.position.visiblePages.last == session.position.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.bar)
                }
            }
        }
    }

    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                session.showPageList.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show / Hide Thumbnails")
            Button {
                session.perform(.toggleOverview)
            } label: {
                Image(systemName: "square.grid.3x3")
            }
            .help("Page Overview")
            Button {
                session.perform(.readingSettings)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Reading Settings")
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("Reader Controls")
            .popover(isPresented: $showHelp) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reader Controls").font(.headline)
                    Text(
                        "Click the sides to turn pages; click the center to show controls. Double-click a page to preview its image. Dragging does not move the page."
                    )
                    Text(
                        "A / D: pages · Space: a screen · Q: controls · T: thumbnails · F: overview · R: reading settings"
                    )
                    .font(.callout)
                    Button("Got It") {
                        hintsSeen = true
                        showHelp = false
                    }
                }.padding(20).frame(width: 350)
            }
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
            Picker(
                "Page Layout",
                selection: Binding(get: { session.position.layout }, set: { session.setLayout($0) })
            ) {
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
                    isOn: Binding(
                        get: { session.position.coverIsSingle }, set: { session.setSingleCover($0) }))
                Divider()
                ForEach([ReaderAction.fitPage, .fitWidth, .actualSize, .zoomIn, .zoomOut], id: \.self) {
                    action in
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
        .disabled(
            next
                ? session.position.visiblePages.last == session.position.count - 1
                : session.position.page == 0)
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
                guard readerWindow.isKeyWindow else { return event }
                let binding = KeyBinding(event: event)
                return self.session?.handleKey(
                    binding, shortcuts: self.shortcuts, repeatEvent: event.isARepeat) == true
                    ? nil : event
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

private struct ReaderPageOverview: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Page Overview").font(.title2)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 16) {
                        if let book = session.book {
                            ForEach(book.pages.indices, id: \.self) { page in
                                Button {
                                    session.seek(page)
                                    dismiss()
                                } label: {
                                    VStack {
                                        ComicImage(
                                            url: session.library.pageURL(for: book, at: page), maximumDimension: 300
                                        )
                                        .frame(height: 150)
                                        Text("Page \(page + 1)")
                                    }.padding(6)
                                        .background(
                                            session.position.visiblePages.contains(page)
                                                ? Color.accentColor.opacity(0.2) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain).id(page)
                            }
                        }
                    }.padding()
                }.onAppear { proxy.scrollTo(session.position.page, anchor: .center) }
            }
        }.frame(minWidth: 640, idealWidth: 800, minHeight: 500, idealHeight: 640)
            .focusable().focused($focused)
            .onAppear { focused = true }
            .onKeyPress("f") {
                dismiss()
                return .handled
            }
    }
}

struct ReaderOptionsPanel: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            HStack {
                Text("Reading Settings").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Form {
                Picker(
                    "Page Layout",
                    selection: Binding(get: { session.position.layout }, set: { session.setLayout($0) })
                ) {
                    Text("Single Page").tag(PageLayout.single)
                    Text("Two Pages").tag(PageLayout.spread)
                    Text("Continuous").tag(PageLayout.continuous)
                }
                Picker("Reading Direction", selection: $session.direction) {
                    Text("Right to Left").tag(ReadingDirection.rightToLeft)
                    Text("Left to Right").tag(ReadingDirection.leftToRight)
                }
                Toggle(
                    "Single Cover Page",
                    isOn: Binding(
                        get: { session.position.coverIsSingle }, set: { session.setSingleCover($0) }))
                ReaderInputSettings()
                Text(
                    "A / D and arrow keys navigate pages. Space scrolls a screen in continuous mode. Q shows controls, T opens thumbnails, F opens the page overview."
                )
                .font(.callout).foregroundStyle(.secondary)
            }.formStyle(.grouped)
        }.frame(width: 580, height: 540)
    }
}

struct ReaderInputSettings: View {
    @AppStorage("reader.clickToTurn") private var clickToTurn = true
    @AppStorage("reader.swapClickSides") private var swapClickSides = false
    @AppStorage("reader.reverseWheelPaging") private var reverseWheel = false
    @AppStorage("reader.directionalArrows") private var directionalArrows = false
    var body: some View {
        Section("Mouse and Keyboard") {
            Toggle("Click Side Areas to Turn Pages", isOn: $clickToTurn)
            Toggle("Swap Click Sides", isOn: $swapClickSides).disabled(!clickToTurn)
            Toggle("Reverse Wheel Paging", isOn: $reverseWheel)
            Toggle("Left / Right Arrows Follow Reading Direction", isOn: $directionalArrows)
            Text(
                "The center area toggles controls. Double-click an image to preview it. Scroll a zoomed page to its edge, then start a new gesture to turn the page."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ReaderImagePreview: View {
    let url: URL?
    let page: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var error: String?
    @State private var scale: CGFloat = 1
    @State private var fit = true
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Page \(page + 1)").font(.headline)
                Spacer()
                Button("Zoom Out") {
                    fit = false
                    scale = max(0.05, scale / 1.25)
                }
                Button("Zoom In") {
                    fit = false
                    scale = min(8, scale * 1.25)
                }
                Button("Actual Size") {
                    fit = false
                    scale = 1
                }
                Button("Fit Page") { fit = true }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        let factor =
                            fit
                            ? min(
                                (geometry.size.width - 32) / image.size.width,
                                (geometry.size.height - 32) / image.size.height) : scale
                        Image(nsImage: image).resizable()
                            .frame(width: image.size.width * factor, height: image.size.height * factor)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            .onChange(of: factor) { _, value in if fit { scale = value } }
                            .onAppear { if fit { scale = factor } }
                    } else if let error {
                        Text(error).padding().textSelection(.enabled)
                    } else {
                        ProgressView().frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
        }.frame(minWidth: 700, idealWidth: 1000, minHeight: 550, idealHeight: 750)
            .task(id: url) {
                do {
                    guard let url else { throw ImportFailure.empty }
                    let preview = try await PageImages.shared.preview(for: url, maximumDimension: 8192)
                    try Task.checkCancellation()
                    guard let decoded = preview.image() else { throw ImportFailure.empty }
                    image = decoded
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
    }
}
