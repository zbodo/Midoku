import AidokuRunner
import MidokuCore
import SwiftUI

struct SourceMangaLink: Hashable, Codable {
    let sourceKey: String
    let mangaKey: String
    let title: String
    let cover: String?
}

struct NativeSourceHub: View {
    @EnvironmentObject private var sources: SourceStore
    @State private var selected: String?
    @State private var managing = false
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Installed Sources") {
                    ForEach(
                        sources.snapshot.installed.sorted {
                            $0.name.localizedStandardCompare($1.name) == .orderedAscending
                        }
                    ) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name)
                            Text(source.languages.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }.tag(source.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                Button {
                    managing = true
                } label: {
                    Label("Manage Sources…", systemImage: "shippingbox")
                }
                .padding(12).frame(maxWidth: .infinity)
            }
        } detail: {
            if let selected, sources.snapshot.installed.contains(where: { $0.id == selected }) {
                NativeSourceBrowse(sourceKey: selected).id(
                    "\(selected)-\(sources.snapshot.installed.first(where: { $0.id == selected })?.version ?? 0)")
            } else {
                ContentUnavailableView {
                    Label("Explore Manga Sources", systemImage: "globe")
                } description: {
                    Text("Add a modern Aidoku source repository, install a source, then choose it in the sidebar.")
                } actions: {
                    Button("Manage Sources…") { managing = true }
                }
            }
        }
        .navigationTitle("Sources")
        .toolbar {
            Button {
                managing = true
            } label: {
                Label("Manage Sources", systemImage: "shippingbox")
            }
        }
        .sheet(isPresented: $managing) { NativeRepositoryManager().environmentObject(sources) }
        .alert(
            "Source Error",
            isPresented: Binding(get: { sources.errorMessage != nil }, set: { if !$0 { sources.errorMessage = nil } })
        ) {
            Button("OK") { sources.errorMessage = nil }
        } message: {
            Text(sources.errorMessage ?? "")
        }
    }
}

struct NativeRepositoryManager: View {
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var query = ""
    @State private var uninstalling: InstalledSource?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Source Repositories").font(.title2.weight(.semibold))
                Spacer()
                if sources.busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack {
                TextField("Repository index URL or aidoku:// link", text: $address)
                    .textFieldStyle(.roundedBorder).onSubmit { sources.add(address) }
                Button("Add") { sources.add(address) }.disabled(address.isEmpty || sources.busy)
            }.padding(.horizontal, 20)
            TextField("Filter sources by name or language", text: $query).textFieldStyle(.roundedBorder).padding(20)
            List {
                ForEach(sources.snapshot.repositories) { repository in
                    Section {
                        ForEach(
                            repository.catalog.sources.filter {
                                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                                    || $0.languages.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                            }
                        ) { entry in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).font(.headline)
                                    Text("\(entry.languages.joined(separator: ", ")) · v\(entry.version)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let installed = sources.snapshot.installed.first(where: { $0.id == entry.id }) {
                                    if installed.version < entry.version {
                                        Button("Update") { sources.install(entry, repository: repository.url) }
                                    }
                                    Button("Uninstall…") { uninstalling = installed }
                                } else {
                                    Button("Install") { sources.install(entry, repository: repository.url) }
                                }
                            }.padding(.vertical, 6).disabled(sources.busy)
                        }
                    } header: {
                        HStack {
                            Text(repository.catalog.name)
                            Spacer()
                            Button {
                                sources.refresh(repository.url)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }.help("Refresh Repository")
                            Button {
                                sources.remove(repository.url)
                            } label: {
                                Image(systemName: "minus.circle")
                            }.help("Remove Repository")
                        }.disabled(sources.busy)
                    } footer: {
                        Text(repository.url.absoluteString).font(.caption).textSelection(.enabled)
                    }
                }
                if sources.snapshot.repositories.isEmpty {
                    Text(
                        "Only modern Aidoku repositories and source packages are supported. Enter the repository's index URL above."
                    )
                    .foregroundStyle(.secondary)
                }
                let orphaned = sources.snapshot.installed.filter { source in
                    !sources.snapshot.repositories.contains(where: {
                        $0.catalog.sources.contains(where: { $0.id == source.id })
                    })
                }
                if !orphaned.isEmpty {
                    Section("Other Installed Sources") {
                        ForEach(orphaned) { source in
                            HStack {
                                Text(source.name)
                                Spacer()
                                Button("Uninstall…") { uninstalling = source }
                            }
                            .disabled(sources.busy)
                        }
                    }
                }
            }
            if let error = sources.errorMessage {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled).padding(16)
            }
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 500, idealHeight: 650)
        .confirmationDialog(
            "Uninstall this source?",
            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })
        ) {
            Button("Uninstall", role: .destructive) {
                if let uninstalling { sources.uninstall(uninstalling.id) }
                uninstalling = nil
            }
        } message: {
            Text("Saved chapters remain in your library. Reinstall this source to refresh their pages.")
        }
    }
}

@MainActor
final class SourceBrowseModel: ObservableObject {
    @Published var source: AidokuRunner.Source?
    @Published var listings: [AidokuRunner.Listing] = []
    @Published var selectedListing = ""
    @Published var books: [AidokuRunner.Manga] = []
    @Published var homeSections: [(String, [AidokuRunner.Manga])] = []
    @Published var homeLinks: [AidokuRunner.HomeComponent.Value.Link] = []
    @Published var homeFilters: [AidokuRunner.HomeComponent.Value.FilterItem] = []
    @Published var loading = false
    @Published var hasNext = false
    @Published var error: String?
    private var page = 0
    private var query = ""
    private var filters: [AidokuRunner.FilterValue] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func start(_ key: String, store: SourceStore) async {
        do {
            let source = try await store.source(key)
            self.source = source
            listings = try await source.getListings()
            selectedListing = source.features.providesHome ? "__home__" : listings.first?.id ?? "__search__"
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func search(_ text: String) {
        query = text
        reload()
    }
    func select(_ listing: String) {
        selectedListing = listing
        query = ""
        filters = []
        reload()
    }
    func openListing(_ listing: AidokuRunner.Listing) {
        if !listings.contains(where: { $0.id == listing.id }) { listings.append(listing) }
        select(listing.id)
    }
    func apply(_ values: [AidokuRunner.FilterValue]) {
        selectedListing = "__search__"
        filters = values
        reload()
    }
    func reload() { load(reset: true) }
    func more() {
        guard !loading, hasNext else { return }
        load(reset: false)
    }

    private func load(reset: Bool) {
        guard let source else { return }
        task?.cancel()
        let token = UUID()
        generation = token
        let pageNumber = reset ? 1 : page + 1
        let listing = listings.first { $0.id == selectedListing }
        let home = selectedListing == "__home__" && query.isEmpty && reset
        let query = query
        let filters = filters
        loading = true
        error = nil
        if reset {
            books = []
            homeSections = []
            homeFilters = []
            homeLinks = []
            hasNext = false
        }
        task = Task {
            do {
                if home {
                    let value = try await source.getHome()
                    guard generation == token, !Task.isCancelled else { return }
                    for component in value.components {
                        let entries: [AidokuRunner.Manga]
                        switch component.value {
                        case .bigScroller(let values, _): entries = values
                        case .imageScroller(let links, _, _, _), .scroller(let links, _),
                            .mangaList(_, _, let links, _), .links(let links):
                            homeLinks += links.filter { link in
                                switch link.value {
                                case .listing, .url: return true
                                default: return false
                                }
                            }
                            entries = links.compactMap {
                                if case .manga(let manga) = $0.value { return manga }
                                return nil
                            }
                        case .mangaChapterList(_, let values, _): entries = values.map(\.manga)
                        case .filters(let values):
                            homeFilters += values
                            entries = []
                        }
                        if !entries.isEmpty { homeSections.append((component.title ?? source.name, entries)) }
                    }
                } else {
                    let result =
                        try await
                        (query.isEmpty && listing != nil
                        ? source.getMangaList(listing: listing!, page: pageNumber)
                        : source.getSearchMangaList(
                            query: query.isEmpty ? nil : query, page: pageNumber, filters: filters))
                    guard generation == token, !Task.isCancelled else { return }
                    let existing = Set(books.map(\.key))
                    books += result.entries.filter { !existing.contains($0.key) }
                    hasNext = result.hasNextPage
                }
                page = pageNumber
            } catch { if generation == token, !Task.isCancelled { self.error = error.localizedDescription } }
            if generation == token { loading = false }
        }
    }
}

struct NativeSourceBrowse: View {
    let sourceKey: String
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @StateObject private var model = SourceBrowseModel()
    @State private var query = ""
    @State private var showingSettings = false
    @State private var showingFilters = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search this source", text: $query).textFieldStyle(.roundedBorder).onSubmit {
                    model.search(query)
                }
                Button("Search") { model.search(query) }.disabled(model.loading)
                if !query.isEmpty {
                    Button {
                        query = ""
                        model.search("")
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                }
            }.padding(16)
            if let error = model.error {
                VStack {
                    Text(error).textSelection(.enabled)
                    Button("Retry") {
                        if model.source == nil {
                            Task { await model.start(sourceKey, store: sources) }
                        } else {
                            model.reload()
                        }
                    }
                }
                .padding().foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !model.homeFilters.isEmpty {
                        HStack {
                            ForEach(model.homeFilters.indices, id: \.self) { index in
                                let filter = model.homeFilters[index]
                                Button(filter.title) { model.apply(filter.values ?? []) }
                            }
                        }
                    }
                    if !model.homeLinks.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))]) {
                            ForEach(model.homeLinks.indices, id: \.self) { index in
                                let link = model.homeLinks[index]
                                Button(link.title) {
                                    switch link.value {
                                    case .listing(let listing):
                                        query = ""
                                        model.openListing(listing)
                                    case .url(let raw): if let url = URL(string: raw) { openURL(url) }
                                    default: break
                                    }
                                }
                            }
                        }
                    }
                    ForEach(model.homeSections.indices, id: \.self) { index in
                        Text(model.homeSections[index].0).font(.title2.weight(.semibold))
                        grid(model.homeSections[index].1)
                    }
                    grid(model.books)
                    if model.loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if model.hasNext {
                        Button("Load More") { model.more() }.frame(maxWidth: .infinity)
                    } else if model.books.isEmpty && model.homeSections.isEmpty && model.error == nil {
                        ContentUnavailableView(
                            "No Manga Found", systemImage: "magnifyingglass",
                            description: Text("Choose a listing or search by title."))
                    }
                }.padding(24)
            }
        }
        .navigationTitle(model.source?.name ?? sourceKey)
        .toolbar {
            if let source = model.source {
                Picker(
                    "Listing",
                    selection: Binding(
                        get: { model.selectedListing },
                        set: {
                            query = ""
                            model.select($0)
                        })
                ) {
                    if source.features.providesHome { Text("Home").tag("__home__") }
                    Text("Search").tag("__search__")
                    ForEach(model.listings, id: \.id) { Text($0.name).tag($0.id) }
                }.frame(width: 150)
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh")
                Button {
                    openWindow(id: "source-web", value: sourceKey)
                } label: {
                    Image(systemName: "globe")
                }.help("Open Source Website / Sign In")
                Button {
                    showingFilters = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }.help("Search Filters")
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }.help("Source Settings")
            }
        }
        .task { await model.start(sourceKey, store: sources) }
        .sheet(isPresented: $showingFilters) {
            if let source = model.source { NativeSourceFilters(source: source) { model.apply($0) } }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { model.reload() }) {
            if let source = model.source { NativeSourceSettings(source: source) }
        }
    }

    private func grid(_ books: [AidokuRunner.Manga]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 24)], spacing: 24) {
            ForEach(Array(books.enumerated()), id: \.offset) { _, manga in
                Button {
                    openWindow(
                        id: "manga",
                        value: SourceMangaLink(
                            sourceKey: sourceKey, mangaKey: manga.key, title: manga.title, cover: manga.cover))
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        SourceCover(sourceKey: sourceKey, cover: manga.cover).frame(height: 210).frame(
                            maxWidth: .infinity)
                        Text(manga.title).font(.callout.weight(.medium)).lineLimit(2).frame(height: 36, alignment: .top)
                    }
                }.buttonStyle(.plain)
            }
        }
    }
}

struct SourceCover: View {
    let sourceKey: String
    let cover: String?
    @EnvironmentObject private var sources: SourceStore
    @State private var url: URL?
    @State private var failed = false
    var body: some View {
        Group {
            if failed {
                Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary).frame(
                    maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ComicImage(url: url, maximumDimension: 600)
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(
            id:
                "\(sourceKey)-\(cover ?? "")-\(sources.snapshot.installed.first(where: { $0.id == sourceKey })?.version ?? 0)"
        ) {
            failed = false
            url = nil
            guard let cover else {
                failed = true
                return
            }
            do {
                let cached = try RemotePageCache.coverPath(cover, sourceKey: sourceKey, root: sources.root)
                if FileManager.default.fileExists(atPath: cached.path) {
                    url = cached
                    return
                }
                let source = try await sources.source(sourceKey)
                url = try await RemotePageCache.shared.coverURL(cover, source: source, root: sources.root)
            } catch { failed = true }
        }
    }
}
