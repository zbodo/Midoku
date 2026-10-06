import AppKit
import MidokuCore
import SwiftUI
import UniformTypeIdentifiers

private enum Shelf: Hashable {
    case all, reading, favorites, finished, uncategorized
    case collection(String)
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.openWindow) private var openWindow
    @State private var shelf: Shelf? = .all
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @AppStorage("desktop.library.sort") private var sort: LibrarySort = .lastOpened
    @AppStorage("desktop.library.ascending") private var ascending = false
    @AppStorage("desktop.library.pin") private var pin: LibraryPin = .none
    @AppStorage("desktop.library.unreadFilter") private var unreadFilter: LibraryFilterState = .any
    @AppStorage("desktop.library.downloadFilter") private var downloadFilter: LibraryFilterState = .any
    @AppStorage("desktop.library.startedFilter") private var startedFilter: LibraryFilterState = .any
    @AppStorage("desktop.library.completedFilter") private var completedFilter: LibraryFilterState = .any
    @AppStorage("desktop.library.sourceFilter") private var sourceFilter = ""
    @AppStorage("desktop.library.opensReader") private var opensReader = false
    @AppStorage("desktop.library.resumeLastOpened") private var resumeLastOpened = false
    @AppStorage("desktop.library.unreadBadges") private var unreadBadges = true
    @AppStorage("desktop.library.downloadedBadges") private var downloadedBadges = true
    @AppStorage("desktop.library.listView") private var listView = false
    @State private var refreshing = false
    @State private var opening: UUID?
    @State private var deletingDownloads = false
    @State private var showInspector = true
    @State private var showingSources = false
    @State private var collectionName = ""
    @State private var creatingCollection = false
    @State private var removingBooks = false
    @State private var targetForDrop = false
    @State private var selectionAnchor: UUID?
    @State private var selectionCursor: UUID?
    @State private var keyboardTarget: UUID?
    @State private var columnCount = 1
    @FocusState private var shelfFocused: Bool
    @AppStorage("desktop.coverSize") private var coverSize = 150.0

    private func sourcesForLinks(_ url: URL) {
        guard url.scheme == "aidoku" else { return }
        sources.add(url.absoluteString)
        openWindow(id: "sources")
    }

    private var visibleBooks: [ShelfBook] {
        var options = LibraryQuery()
        options.text = query; options.sort = sort; options.ascending = ascending; options.pin = pin
        options.unread = unreadFilter; options.downloaded = downloadFilter
        options.started = startedFilter; options.completed = completedFilter
        options.source = sourceFilter.isEmpty ? nil : sourceFilter
        switch shelf ?? .all {
        case .collection(let name): options.category = name
        case .uncategorized: options.category = ""
        default: break
        }
        return options.apply(to: library.shelfBooks).filter { book in
            switch shelf ?? .all {
            case .reading: book.lastReadAt != nil && book.unreadCount > 0
            case .favorites: book.isFavorite
            case .finished: book.isRead
            default: true
            }
        }
    }

    private var selectedBook: ShelfBook? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return library.shelfBook(id)
    }

    var body: some View {
        interactiveShelf
            .sheet(isPresented: $showingSources) {
                sourceSheet
            }
            .sheet(item: $library.pendingAidokuBackup) { preview in
                AidokuBackupImportView(preview: preview).environmentObject(library).environmentObject(sources)
            }
            .alert("New Collection", isPresented: $creatingCollection) {
                TextField("Name", text: $collectionName)
                Button("Cancel", role: .cancel) { collectionName = "" }
                Button("Create") { createCollection() }
                    .disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("Remove selected comics from the library?", isPresented: $removingBooks) {
                Button("Remove from Library", role: .destructive) {
                    library.remove(selection)
                    selection = []
                }
                Button("Remove and Delete Stored Pages", role: .destructive) {
                    library.remove(selection, deleteDownloads: true)
                    selection = []
                }
            } message: {
                Text("Removing a book preserves reading history and stored pages. You can choose to delete its stored pages separately.")
            }
            .confirmationDialog("Delete downloaded chapters?", isPresented: $deletingDownloads) {
                Button("Delete Downloads", role: .destructive) { library.deleteDownloads(selection) }
            } message: {
                Text("Reading history is preserved. Online chapter pages will need to be fetched again.")
            }
            .alert("Library Error", isPresented: libraryErrorPresented) {
                Button("OK") { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
    }

    private var libraryErrorPresented: Binding<Bool> {
        Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } })
    }

    private var sourceSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sources").font(.headline)
                Spacer()
                Button("Done") { showingSources = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            NativeSourceHub()
                .environmentObject(sources)
                .environmentObject(library)
        }
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 500, idealHeight: 700)
    }

    private var layout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            shelfDetail
        }
    }

    private var shelfDetail: some View {
        HStack(spacing: 0) {
            shelfContent
            if showInspector, let book = selectedBook {
                Divider()
                inspector(book).frame(width: 260)
            }
        }
        .onOpenURL { url in sourcesForLinks(url) }
        .navigationTitle(shelfTitle)
        .searchable(text: $query, prompt: "Search your library")
        .toolbar { shelfToolbar }
    }

    @ToolbarContentBuilder private var shelfToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                showingSources = true
            } label: {
                Label("Sources", systemImage: "globe")
            }
        }
        ToolbarItem {
            Button {
                library.importPanel()
            } label: {
                Label("Import Comics", systemImage: "plus")
            }
            .disabled(library.isImporting || library.loadFailed)
        }
        ToolbarItem { sortPicker }
        ToolbarItem { filterMenu }
        ToolbarItem { appearanceMenu }
        ToolbarItem {
            Button { refreshLibrary() } label: { Label("Update Library", systemImage: "arrow.clockwise") }
                .disabled(refreshing || library.loadFailed)
        }
    }

    private var sortPicker: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(LibrarySort.allCases, id: \.self) { option in Text(option.title).tag(option) }
            }
            Toggle("Ascending", isOn: $ascending)
            Divider()
            Picker("Pin Titles", selection: $pin) {
                Text("Disabled").tag(LibraryPin.none)
                Text("Unread Chapters").tag(LibraryPin.unread)
                Text("Updated Chapters").tag(LibraryPin.updatedChapters)
            }
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
        .onChange(of: sort) { _, value in ascending = value == .title }
    }

    private var filterMenu: some View {
        Menu {
            filterPicker("Unread Chapters", selection: $unreadFilter)
            filterPicker("Downloaded", selection: $downloadFilter)
            filterPicker("Started", selection: $startedFilter)
            filterPicker("Publishing Completed", selection: $completedFilter)
            Picker("Source", selection: $sourceFilter) {
                Text("All Sources").tag("")
                ForEach(Array(Set(library.snapshot.mangaBooks.map(\.sourceKey))).sorted(), id: \.self) { key in
                    Text(key).tag(key)
                }
            }
            Button("Reset Filters") {
                unreadFilter = .any; downloadFilter = .any; startedFilter = .any
                completedFilter = .any; sourceFilter = ""
            }
        } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
    }

    private func filterPicker(_ title: String, selection: Binding<LibraryFilterState>) -> some View {
        Picker(LocalizedStringKey(title), selection: selection) {
            Text("Any").tag(LibraryFilterState.any)
            Text("Include").tag(LibraryFilterState.include)
            Text("Exclude").tag(LibraryFilterState.exclude)
        }
    }

    private var appearanceMenu: some View {
        Menu {
            Slider(value: $coverSize, in: 100...260, step: 10) { Text("Cover Size") }
            Toggle("List View", isOn: $listView)
            Toggle("Show Inspector", isOn: $showInspector)
            Toggle("Unread Chapter Badges", isOn: $unreadBadges)
            Toggle("Downloaded Chapter Badges", isOn: $downloadedBadges)
            Divider()
            Toggle("Open Reader Directly", isOn: $opensReader)
            Toggle("Resume Last Opened Chapter", isOn: $resumeLastOpened)
        } label: {
            Label("Shelf Appearance", systemImage: "square.grid.2x2")
        }
    }

    private var interactiveShelf: some View {
        layout
            .onChange(of: shelf) { _, _ in
                selection = []
                selectionAnchor = nil
                selectionCursor = nil
            }
            .onChange(of: query) { _, _ in selection = selection.intersection(Set(visibleBooks.map(\.id))) }
            .onChange(of: library.shelfBooks) { _, _ in selection = selection.intersection(Set(library.shelfBooks.map(\.id))) }
            .onDrop(of: [.fileURL], isTargeted: $targetForDrop) { providers in
                guard !library.isImporting, !library.loadFailed else { return false }
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = await droppedURL(provider) { urls.append(url) }
                    }
                    library.importFiles(urls)
                }
                return true
            }
            .overlay {
                if targetForDrop {
                    RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 4).padding(8).allowsHitTesting(false)
                }
            }
    }

    private var sidebar: some View {
        List(selection: $shelf) {
            Section("Library") {
                Label("All Comics", systemImage: "books.vertical").tag(Shelf.all)
                Label("Uncategorized", systemImage: "folder").tag(Shelf.uncategorized)
                Label("Continue Reading", systemImage: "book").tag(Shelf.reading)
                Label("Favorites", systemImage: "star").tag(Shelf.favorites)
                Label("Finished", systemImage: "checkmark.circle").tag(Shelf.finished)
                Button {
                    openWindow(id: "aidoku-backup")
                } label: {
                    Label("Aidoku Library & Backups", systemImage: "tray.and.arrow.down")
                }.buttonStyle(.plain)
            }
            Section("Collections") {
                ForEach(library.snapshot.collections, id: \.self) { name in
                    Label(name, systemImage: "folder").tag(Shelf.collection(name))
                        .contextMenu {
                            Button("Delete Collection", role: .destructive) {
                                deleteCollection(name)
                            }
                        }
                }
                Button {
                    creatingCollection = true
                } label: {
                    Label("New Collection…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(library.shelfBooks.count) comics").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if library.isImporting { ProgressView().controlSize(.small) }
            }.padding(12)
        }
    }

    private func createCollection() {
        let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, !library.snapshot.collections.contains(name) {
            library.commit { $0.collections.append(name) }
            shelf = .collection(name)
        }
        collectionName = ""
    }

    private func deleteCollection(_ name: String) {
        library.commit { (snapshot: inout LibrarySnapshot) in
            snapshot.collections.removeAll { (collection: String) in collection == name }
            for index in snapshot.books.indices {
                snapshot.books[index].categories.removeAll { $0 == name }
            }
            for index in snapshot.mangaBooks.indices {
                snapshot.mangaBooks[index].categories.removeAll { $0 == name }
            }
            for index in snapshot.retainedManga?.indices ?? 0..<0 {
                snapshot.retainedManga?[index].categories.removeAll { $0 == name }
            }
        }
        shelf = .all
    }

    @ViewBuilder private var shelfContent: some View {
        if library.loadFailed {
            ContentUnavailableView(
                "Library Could Not Be Loaded", systemImage: "exclamationmark.triangle",
                description: Text(
                    "Your library files have been preserved. Restore or repair library.json before importing new comics."
                ))
        } else if visibleBooks.isEmpty {
            ContentUnavailableView {
                Label(query.isEmpty ? "Your Shelf Awaits" : "No Results", systemImage: "books.vertical")
            } description: {
                Text(
                    query.isEmpty
                        ? (library.shelfBooks.isEmpty ? "Add manga from Sources or import local comic files." : "Adjust filters or select another category.")
                        : "Try another title or author.")
            } actions: {
                if query.isEmpty { Button("Import Comics…") { library.importPanel() }.disabled(library.isImporting) }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                listView ? .flexible() : .adaptive(minimum: CGFloat(coverSize), maximum: CGFloat(coverSize + 40)), spacing: 24)
                        ], spacing: 24
                    ) {
                        ForEach(visibleBooks) { book in
                            bookCard(book).id(book.id)
                        }
                    }
                    .padding(28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .background {
                    GeometryReader { geometry in
                        Color.clear.onAppear { updateColumns(geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
                            .onChange(of: coverSize) { _, _ in updateColumns(geometry.size.width) }
                            .onChange(of: listView) { _, _ in updateColumns(geometry.size.width) }
                    }
                }
                .focusable()
                .focused($shelfFocused)
                .onChange(of: keyboardTarget) { _, target in
                    if let target { proxy.scrollTo(target, anchor: .center) }
                }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    if press.modifiers == .command, press.characters.lowercased() == "a" {
                        selection = Set(visibleBooks.map(\.id))
                        return .handled
                    }
                    if press.key == .return, let book = selectedBook {
                        openBook(book)
                        return .handled
                    }
                    let offset: Int
                    switch press.key {
                    case .leftArrow: offset = -1
                    case .rightArrow: offset = 1
                    case .upArrow: offset = -columnCount
                    case .downArrow: offset = columnCount
                    default: return .ignored
                    }
                    moveSelection(offset: offset, extend: press.modifiers.contains(.shift))
                    return .handled
                }
            }
        }
    }

    private func bookCard(_ book: ShelfBook) -> some View {
        Group {
            if listView {
                HStack(spacing: 16) {
                    bookCover(book).frame(width: 60, height: 84)
                    bookSummary(book)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    bookCover(book).frame(height: CGFloat(coverSize * 1.4))
                    bookSummary(book)
                }
            }
        }
        .padding(8)
        .background(selection.contains(book.id) ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(selection.contains(book.id) ? Color.accentColor : .clear, lineWidth: 2) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openBook(book) }
        .onTapGesture {
            shelfFocused = true
            select(book.id, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openBook(book) }
        .contextMenu { bookMenu(book) }
    }

    private func bookCover(_ book: ShelfBook) -> some View {
        ShelfCover(book: book, pageURL: library.pageURL(for: book, at: 0))
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if book.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).padding(8).shadow(radius: 2)
                    }
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        if unreadBadges && book.unreadCount > 0 {
                            Text("\(book.unreadCount)").padding(4).background(.blue, in: RoundedRectangle(cornerRadius: 4))
                                .help("Unread Chapters")
                        }
                        if downloadedBadges && book.downloadedCount > 0 {
                            Label("\(book.downloadedCount)", systemImage: "arrow.down")
                                .padding(4).background(.green, in: RoundedRectangle(cornerRadius: 4)).help("Downloaded Chapters")
                        }
                    }.font(.caption).foregroundStyle(.white).padding(6)
                }
    }

    private func bookSummary(_ book: ShelfBook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(book.title).font(.callout.weight(.medium)).lineLimit(2)
            bookSizeLabel(book).font(.caption).foregroundStyle(.secondary)
            if book.lastReadAt != nil {
                Text("\(book.unreadCount) unread chapters").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func targetIDs(_ book: ShelfBook) -> Set<UUID> {
        selection.contains(book.id) ? selection : [book.id]
    }

    private func categoryMenu(_ book: ShelfBook) -> some View {
        Menu("Edit Categories") {
            Button("Uncategorized") {
                for id in targetIDs(book) { library.updateShelfBook(id) { $0.categories = [] } }
            }
            ForEach(library.snapshot.collections, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { targetIDs(book).allSatisfy { library.shelfBook($0)?.categories.contains(name) == true } },
                    set: { included in
                        for id in targetIDs(book) {
                            library.updateShelfBook(id) {
                                if included { $0.categories = Array(Set($0.categories + [name])).sorted() }
                                else { $0.categories.removeAll { $0 == name } }
                            }
                        }
                    }))
            }
        }
    }

    @ViewBuilder private func bookMenu(_ book: ShelfBook) -> some View {
        Button(book.manga == nil ? "Open in Reader Window" : "View Chapters") { openDetails(book) }
        if book.manga != nil { Button("Continue Reading") { continueBook(book) }.disabled(opening != nil) }
        Button(book.isFavorite ? "Remove Favorite" : "Add to Favorites") {
            let favorite = !book.isFavorite
            for id in targetIDs(book) { library.updateShelfBook(id) { $0.isFavorite = favorite } }
        }
        Menu("Mark All Chapters") {
            Button("Read") { library.markChapters(targetIDs(book), read: true) }
            Button("Unread") { library.markChapters(targetIDs(book), read: false) }
        }
        categoryMenu(book)
        if book.manga != nil {
            Button("Update Chapters") { refreshLibrary(ids: targetIDs(book)) }.disabled(refreshing)
            Button("Delete Downloads…", role: .destructive) { selection = targetIDs(book); deletingDownloads = true }
        }
        Divider()
        Button("Remove from Library…", role: .destructive) { selection = targetIDs(book); removingBooks = true }
    }

    private func inspector(_ book: ShelfBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ShelfCover(book: book, pageURL: library.pageURL(for: book, at: 0)).frame(maxHeight: 300)
                Text(book.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                bookSizeLabel(book).foregroundStyle(.secondary)
                if book.lastReadAt != nil {
                    if book.manga != nil { Text("Current Chapter Progress").font(.caption) }
                    ProgressView(value: book.progress)
                    if let chapter = book.readingBook?.online {
                        Text(chapter.chapterTitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Page \(book.currentPage + 1)").font(.callout).foregroundStyle(.secondary)
                }
                Button(book.lastReadAt == nil ? "Start Reading" : "Continue Reading") { continueBook(book) }
                    .disabled(opening != nil)
                    .buttonStyle(.borderedProminent)
                Toggle(
                    "Favorite",
                    isOn: Binding(
                        get: { book.isFavorite },
                        set: { value in library.updateShelfBook(book.id) { $0.isFavorite = value } }))
                TextField(
                    "Title",
                    text: Binding(
                        get: { library.shelfBook(book.id)?.title ?? book.title },
                        set: { value in library.updateShelfBook(book.id) { $0.title = value } })
                )
                .textFieldStyle(.roundedBorder)
            }.padding(20)
        }
    }

    private var shelfTitle: String {
        switch shelf ?? .all {
        case .all: String(localized: "All Comics")
        case .uncategorized: String(localized: "Uncategorized")
        case .reading: String(localized: "Continue Reading")
        case .favorites: String(localized: "Favorites")
        case .finished: String(localized: "Finished")
        case .collection(let name): name
        }
    }

    @ViewBuilder private func bookSizeLabel(_ book: ShelfBook) -> some View {
        if book.manga != nil {
            Text("\(book.chapterCount) chapters")
        } else {
            Text("\(book.pages.count) pages")
        }
    }

    private func openBook(_ book: ShelfBook) {
        if opensReader && book.manga != nil { continueBook(book) } else { openDetails(book) }
    }

    private func openDetails(_ book: ShelfBook) {
        if let manga = book.manga {
            library.mangaOpened(manga)
            openWindow(id: "manga", value: SourceMangaLink(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey,
                                                         title: manga.title, cover: manga.cover))
        } else if let chapter = book.readingBook { openWindow(id: "reader", value: chapter.id) }
    }

    private func continueBook(_ book: ShelfBook) {
        guard let manga = book.manga else { openDetails(book); return }
        guard opening == nil else { return }
        opening = book.id
        Task {
            defer { opening = nil }
            do {
                if let id = try await sources.continueManga(manga, library: library, resumeLastOpened: resumeLastOpened) {
                    library.mangaOpened(manga)
                    openWindow(id: "reader", value: id)
                } else { openDetails(book) }
            } catch { library.errorMessage = error.localizedDescription }
        }
    }

    private func refreshLibrary(ids: Set<UUID>? = nil) {
        guard !refreshing else { return }
        let targets = library.snapshot.mangaBooks.filter { ids == nil || ids!.contains($0.id) }
        refreshing = true
        Task {
            defer { refreshing = false }
            var errors: [String] = []
            for manga in targets {
                do { try await sources.refreshManga(manga, library: library) }
                catch { errors.append("\(manga.title): \(error.localizedDescription)") }
            }
            if !errors.isEmpty { library.errorMessage = errors.joined(separator: "\n") }
        }
    }

    private func updateColumns(_ width: CGFloat) {
        columnCount = listView ? 1 : max(1, Int((width - 56 + 24) / (CGFloat(coverSize) + 24)))
    }

    private func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        selectionCursor = id
        let ids = visibleBooks.map(\.id)
        if modifiers.contains(.shift), let anchor = selectionAnchor,
            let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: id)
        {
            selection = Set(ids[min(start, end)...max(start, end)])
        } else if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    private func moveSelection(offset: Int, extend: Bool) {
        let ids = visibleBooks.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: selectionCursor ?? selection.first ?? ids[0]) ?? 0
        let next = selection.isEmpty ? 0 : min(max(0, current + offset), ids.count - 1)
        if extend, let anchor = selectionAnchor, let start = ids.firstIndex(of: anchor) {
            selection = Set(ids[min(start, next)...max(start, next)])
        } else {
            selection = [ids[next]]
            selectionAnchor = ids[next]
        }
        selectionCursor = ids[next]
        keyboardTarget = ids[next]
    }

    private func droppedURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                if let data = value as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let url = value as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct ShelfCover: View {
    let book: ShelfBook
    let pageURL: URL?
    var body: some View {
        if let manga = book.manga {
            SourceCover(sourceKey: manga.sourceKey, cover: manga.cover)
        } else {
            ComicImage(url: pageURL, maximumDimension: 600)
        }
    }
}

private extension LibrarySort {
    var title: String {
        switch self {
        case .title: String(localized: "Title")
        case .lastRead: String(localized: "Recently Read")
        case .lastOpened: String(localized: "Last Opened")
        case .lastUpdated: String(localized: "Last Updated")
        case .dateAdded: String(localized: "Date Added")
        case .latestChapter: String(localized: "Latest Chapter")
        case .unreadChapters: String(localized: "Unread Chapters")
        case .totalChapters: String(localized: "Total Chapters")
        }
    }
}
