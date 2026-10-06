import AppKit
import MidokuCore
import SwiftUI
import UniformTypeIdentifiers

private enum Shelf: Hashable {
    case all, reading, favorites, finished
    case collection(String)
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.openWindow) private var openWindow
    @State private var shelf: Shelf? = .all
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var sort = "title"
    @State private var showInspector = true
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

    private var visibleBooks: [ComicBook] {
        library.books.filter { book in
            let included: Bool
            switch shelf ?? .all {
            case .all: included = true
            case .reading: included = book.lastReadAt != nil && !book.isRead
            case .favorites: included = book.isFavorite
            case .finished: included = book.isRead
            case .collection(let name): included = book.collection == name
            }
            return included && (query.isEmpty || book.title.localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            if sort == "recent" { return (lhs.lastReadAt ?? lhs.importedAt) > (rhs.lastReadAt ?? rhs.importedAt) }
            if sort == "imported" { return lhs.importedAt > rhs.importedAt }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private var selectedBook: ComicBook? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return library.book(id)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $shelf) {
                Section("Library") {
                    Label("All Comics", systemImage: "books.vertical").tag(Shelf.all)
                    Label("Continue Reading", systemImage: "book").tag(Shelf.reading)
                    Label("Favorites", systemImage: "star").tag(Shelf.favorites)
                    Label("Finished", systemImage: "checkmark.circle").tag(Shelf.finished)
                }
                Section("Collections") {
                    ForEach(library.snapshot.collections, id: \.self) { name in
                        Label(name, systemImage: "folder").tag(Shelf.collection(name))
                            .contextMenu {
                                Button("Delete Collection", role: .destructive) {
                                    library.commit { snapshot in
                                        snapshot.collections.removeAll { $0 == name }
                                        for index in snapshot.books.indices
                                        where snapshot.books[index].collection == name {
                                            snapshot.books[index].collection = nil
                                        }
                                    }
                                    shelf = .all
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
                    Text("\(library.books.count) comics").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if library.isImporting { ProgressView().controlSize(.small) }
                }.padding(12)
            }
        } detail: {
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
            .toolbar {
                Button {
                    openWindow(id: "sources")
                } label: {
                    Label("Sources", systemImage: "globe")
                }
                ToolbarItemGroup {
                    Button {
                        library.importPanel()
                    } label: {
                        Label("Import Comics", systemImage: "plus")
                    }
                    .disabled(library.isImporting || library.loadFailed)
                    Picker("Sort", selection: $sort) {
                        Text("Title").tag("title")
                        Text("Recently Read").tag("recent")
                        Text("Date Imported").tag("imported")
                    }.frame(width: 140)
                    Menu {
                        Slider(value: $coverSize, in: 100...260, step: 10) { Text("Cover Size") }
                        Toggle("Show Inspector", isOn: $showInspector)
                    } label: {
                        Label("Shelf Appearance", systemImage: "square.grid.2x2")
                    }
                }
            }
        }
        .onChange(of: shelf) { _, _ in
            selection = []
            selectionAnchor = nil
            selectionCursor = nil
        }
        .onChange(of: query) { _, _ in selection = selection.intersection(Set(visibleBooks.map(\.id))) }
        .onChange(of: library.books) { _, _ in selection = selection.intersection(Set(library.books.map(\.id))) }
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
        .alert("New Collection", isPresented: $creatingCollection) {
            TextField("Name", text: $collectionName)
            Button("Cancel", role: .cancel) { collectionName = "" }
            Button("Create") {
                let name = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !library.snapshot.collections.contains(name) {
                    library.commit { $0.collections.append(name) }
                    shelf = .collection(name)
                }
                collectionName = ""
            }.disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Remove selected comics from the library?", isPresented: $removingBooks) {
            Button("Remove Comics", role: .destructive) {
                library.remove(selection)
                selection = []
            }
        } message: {
            Text("Imported copies will be deleted. Your original files will remain on disk.")
        }
        .alert(
            "Library Error",
            isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })
        ) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
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
                        ? "Import CBZ archives, PDFs, or folders of comic pages. You can also drop them into this window."
                        : "Try another title or select All Comics.")
            } actions: {
                if query.isEmpty { Button("Import Comics…") { library.importPanel() }.disabled(library.isImporting) }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: CGFloat(coverSize), maximum: CGFloat(coverSize + 40)), spacing: 24)
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

    private func bookCard(_ book: ComicBook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfCover(book: book, pageURL: library.pageURL(for: book, at: 0))
                .frame(height: CGFloat(coverSize * 1.4))
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if book.isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).padding(8).shadow(radius: 2)
                    }
                }
            Text(book.title).font(.callout.weight(.medium)).lineLimit(2).frame(height: 36, alignment: .top)
            HStack {
                Text("\(book.pages.count) pages")
                Spacer()
                if book.isRead {
                    Image(systemName: "checkmark.circle.fill")
                } else if book.lastReadAt != nil {
                    Text("\(Int(book.progress * 100))%")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            selection.contains(book.id) ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(
                selection.contains(book.id) ? Color.accentColor : .clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openBook(book) }
        .onTapGesture {
            shelfFocused = true
            select(book.id, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openBook(book) }
        .contextMenu {
            Button("Open in Reader Window") { openBook(book) }
            Button(book.isFavorite ? "Remove Favorite" : "Add to Favorites") {
                library.updateBook(book.id) { $0.isFavorite.toggle() }
            }
            Button(book.isRead ? "Mark Unread" : "Mark Finished") { library.updateBook(book.id) { $0.isRead.toggle() } }
            Menu("Move to Collection") {
                Button("None") { library.updateBook(book.id) { $0.collection = nil } }
                ForEach(library.snapshot.collections, id: \.self) { name in
                    Button(name) { library.updateBook(book.id) { $0.collection = name } }
                }
            }
            Divider()
            Button("Remove from Library…", role: .destructive) {
                if !selection.contains(book.id) { selection = [book.id] }
                removingBooks = true
            }
        }
    }

    private func inspector(_ book: ComicBook) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ShelfCover(book: book, pageURL: library.pageURL(for: book, at: 0)).frame(maxHeight: 300)
                Text(book.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text("\(book.pages.count) pages").foregroundStyle(.secondary)
                if book.lastReadAt != nil {
                    ProgressView(value: book.progress)
                    Text("Page \(book.currentPage + 1)").font(.callout).foregroundStyle(.secondary)
                }
                Button(book.lastReadAt == nil ? "Start Reading" : "Continue Reading") { openBook(book) }
                    .buttonStyle(.borderedProminent)
                Toggle(
                    "Favorite",
                    isOn: Binding(
                        get: { book.isFavorite },
                        set: { value in library.updateBook(book.id) { $0.isFavorite = value } }))
                TextField(
                    "Title",
                    text: Binding(
                        get: { library.book(book.id)?.title ?? book.title },
                        set: { value in library.updateBook(book.id) { $0.title = value } })
                )
                .textFieldStyle(.roundedBorder)
            }.padding(20)
        }
    }

    private var shelfTitle: String {
        switch shelf ?? .all {
        case .all: String(localized: "All Comics")
        case .reading: String(localized: "Continue Reading")
        case .favorites: String(localized: "Favorites")
        case .finished: String(localized: "Finished")
        case .collection(let name): name
        }
    }

    private func openBook(_ book: ComicBook) { openWindow(id: "reader", value: book.id) }

    private func updateColumns(_ width: CGFloat) {
        columnCount = max(1, Int((width - 56 + 24) / (CGFloat(coverSize) + 24)))
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
    let book: ComicBook
    let pageURL: URL?
    var body: some View {
        if let online = book.online, online.cover != nil {
            SourceCover(sourceKey: online.sourceKey, cover: online.cover)
        } else {
            ComicImage(url: pageURL, maximumDimension: 600)
        }
    }
}
