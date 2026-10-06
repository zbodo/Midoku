import AidokuRunner
import MidokuCore
import SwiftUI

struct NativeMangaDetails: View {
    let link: SourceMangaLink
    @EnvironmentObject private var sources: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @State private var manga: AidokuRunner.Manga?
    @State private var source: AidokuRunner.Source?
    @State private var loading = false
    @State private var opening: String?
    @State private var error: String?
    @State private var query = ""
    @State private var ascending = false

    private var chapters: [AidokuRunner.Chapter] {
        let values = (manga?.chapters ?? []).filter {
            query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
        return ascending ? Array(values.reversed()) : values
    }

    @AppStorage("desktop.library.resumeLastOpened") private var resumeLastOpened = false
    @State private var removing = false
    @State private var starting = false

    private var record: LibraryManga? { library.mangaRecord(source: link.sourceKey, key: link.mangaKey) }
    private var nextChapter: LibraryChapter? {
        library.continuation(source: link.sourceKey, manga: link.mangaKey, resumeLastOpened: resumeLastOpened)
    }

    var body: some View {
        VStack(spacing: 0) {
            if loading { ProgressView().padding() }
            if let error {
                HStack {
                    Text(error).textSelection(.enabled)
                    Button("Retry") { Task { await refresh() } }
                }.padding()
            }
            if let manga {
                HStack(alignment: .top, spacing: 24) {
                    SourceCover(sourceKey: link.sourceKey, cover: manga.cover).frame(width: 130, height: 190)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(manga.title).font(.title.weight(.semibold)).textSelection(.enabled)
                        Text((manga.authors ?? []).joined(separator: ", ")).foregroundStyle(.secondary)
                        ScrollView {
                            Text(manga.description ?? "").frame(maxWidth: .infinity, alignment: .leading).textSelection(
                                .enabled)
                        }.frame(maxHeight: 110)
                    }
                }.padding(24)
                Divider()
                HStack {
                    TextField("Find a chapter", text: $query).textFieldStyle(.roundedBorder)
                    Button {
                        ascending.toggle()
                    } label: {
                        Label("Reverse Chapter Order", systemImage: "arrow.up.arrow.down")
                    }.labelStyle(.iconOnly)
                    Text("\(chapters.count)").foregroundStyle(.secondary)
                }.padding(16)
                List(chapters, id: \.key) { chapter in
                    Button {
                        read(chapter)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapter.displayTitle)
                                if let scanlators = chapter.scanlators {
                                    Text(scanlators.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if opening == chapter.key {
                                ProgressView().controlSize(.small)
                            } else if chapter.locked {
                                Image(systemName: "lock")
                            } else if library.aidokuChapterCompleted(source: link.sourceKey, manga: link.mangaKey,
                                                                     chapter: chapter.key) {
                                Image(systemName: "checkmark")
                            } else {
                                Image(systemName: "book")
                            }
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(opening != nil || starting)
                    .contextMenu {
                        let completed = library.aidokuChapterCompleted(source: link.sourceKey, manga: link.mangaKey, chapter: chapter.key)
                        Button(completed ? "Mark Unread" : "Mark Read") {
                            library.setChapterRead(source: link.sourceKey, manga: link.mangaKey, chapter: chapter.key, read: !completed)
                        }
                    }
                }
                if chapters.isEmpty { Text("No chapters available").foregroundStyle(.secondary).padding() }
            }
        }
        .navigationTitle(manga?.title ?? link.title)
        .toolbar {
            ToolbarItem {
                if library.mangaOnShelf(source: link.sourceKey, key: link.mangaKey) == nil {
                    Button("Add to Library") {
                        library.addManga(source: link.sourceKey, key: link.mangaKey,
                                         title: manga?.title ?? link.title, cover: manga?.cover ?? link.cover)
                    }.disabled(library.loadFailed)
                } else {
                    Button("Remove from Library…") { removing = true }
                }
            }
            ToolbarItem {
                Button(nextChapter?.lastReadAt == nil ? "Start Reading" : "Continue Reading") { continueReading() }
                    .disabled(starting || opening != nil || nextChapter == nil)
                    .help(nextChapter?.title ?? String(localized: "All Chapters Read"))
            }
            ToolbarItem {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.disabled(loading)
            }
            ToolbarItem {
                Button {
                    openWindow(id: "source-web", value: link.sourceKey)
                } label: {
                    Image(systemName: "globe")
                }.help("Open Source Website / Sign In")
            }
        }
        .confirmationDialog("Remove this manga from the library?", isPresented: $removing) {
            Button("Remove from Library", role: .destructive) {
                if let manga = library.mangaOnShelf(source: link.sourceKey, key: link.mangaKey) { library.remove([manga.id]) }
            }
        } message: { Text("Reading history and stored pages will be preserved.") }
        .task { await refresh() }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        if manga == nil {
            manga = library.storedManga(source: link.sourceKey, key: link.mangaKey)
                ?? library.aidokuManga(source: link.sourceKey, key: link.mangaKey)
        }
        do {
            let runtime = try await sources.source(link.sourceKey)
            source = runtime
            manga = try await runtime.getMangaUpdate(
                manga: manga
                    ?? .init(sourceKey: link.sourceKey, key: link.mangaKey, title: link.title, cover: link.cover),
                needsDetails: true, needsChapters: true)
            if var updated = manga {
                library.applyAidokuMangaOverrides(to: &updated, source: link.sourceKey)
                manga = updated
                library.synchronizeManga(updated, source: link.sourceKey)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func continueReading() {
        guard let record, !starting, opening == nil else { return }
        starting = true; error = nil
        Task {
            defer { starting = false }
            do {
                if let id = try await sources.continueManga(record, library: library, resumeLastOpened: resumeLastOpened) {
                    library.mangaOpened(record)
                    openWindow(id: "reader", value: id)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func read(_ chapter: AidokuRunner.Chapter) {
        guard let manga, opening == nil, !starting else { return }
        opening = chapter.key; error = nil
        Task {
            defer { opening = nil }
            do {
                let id: UUID
                if let existing = library.books.first(where: {
                    $0.online?.sourceKey == link.sourceKey && $0.online?.mangaKey == link.mangaKey
                        && $0.online?.chapterKey == chapter.key
                }) {
                    try await sources.prepare(existing, library: library)
                    id = existing.id
                } else {
                    let runtime = try await sources.source(link.sourceKey)
                    id = try await sources.openChapter(source: runtime, manga: manga, chapter: chapter, library: library)
                }
                if let record { library.mangaOpened(record) }
                openWindow(id: "reader", value: id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
