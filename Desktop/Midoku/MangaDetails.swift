import AidokuRunner
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
                            } else if library.books.contains(where: {
                                $0.online?.sourceKey == link.sourceKey && $0.online?.mangaKey == link.mangaKey
                                    && $0.online?.chapterKey == chapter.key && $0.isRead
                            }) {
                                Image(systemName: "checkmark")
                            } else {
                                Image(systemName: "book")
                            }
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(opening != nil)
                }
                if chapters.isEmpty { Text("No chapters available").foregroundStyle(.secondary).padding() }
            }
        }
        .navigationTitle(manga?.title ?? link.title)
        .toolbar {
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }.disabled(loading)
            Button {
                openWindow(id: "source-web", value: link.sourceKey)
            } label: {
                Image(systemName: "globe")
            }.help("Open Source Website / Sign In")
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let runtime = try await sources.source(link.sourceKey)
            source = runtime
            manga = try await runtime.getMangaUpdate(
                manga: manga
                    ?? .init(sourceKey: link.sourceKey, key: link.mangaKey, title: link.title, cover: link.cover),
                needsDetails: true, needsChapters: true)
        } catch { self.error = error.localizedDescription }
    }

    private func read(_ chapter: AidokuRunner.Chapter) {
        guard let source, let manga, opening == nil else { return }
        opening = chapter.key
        error = nil
        Task {
            defer { opening = nil }
            do {
                let id = try await sources.openChapter(source: source, manga: manga, chapter: chapter, library: library)
                openWindow(id: "reader", value: id)
            } catch { self.error = error.localizedDescription }
        }
    }
}
