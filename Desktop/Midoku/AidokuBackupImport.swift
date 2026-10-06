import AidokuRunner
import AppKit
import MidokuCore
import SwiftUI
import UniformTypeIdentifiers

struct AidokuBackupPreview: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let data: Data
    let backup: AidokuBackup

    static func load(_ url: URL) throws -> Self {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= AidokuBackup.maximumFileSize else { throw AidokuBackupError.tooLarge }
        let data = try Data(contentsOf: url)
        return .init(filename: url.lastPathComponent, data: data, backup: try AidokuBackup.decode(data))
    }
}

struct AidokuBackupImportView: View {
    let preview: AidokuBackupPreview
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var restoreSettings = true
    @State private var restoreSources = true
    @State private var restoring = false
    @State private var restored = false
    @State private var messages: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(restored ? "Aidoku Backup Imported" : "Import Aidoku Backup").font(.title2)
            Text(preview.filename).foregroundStyle(.secondary)
            Text(preview.backup.date, style: .date)
            if let version = preview.backup.version { Text("Aidoku \(version)").font(.caption) }
            counts
            if !restored {
                Text(
                    "Merge into your library. Newer reading progress is kept. A copy of the current library will be saved before importing."
                )
                Toggle("Restore supported reading preferences and source settings", isOn: $restoreSettings)
                Toggle("Add repositories and install missing sources", isOn: $restoreSources)
                Text(
                    "The complete backup is preserved. Tracking, vocabulary, update rules, category groups, custom sources and unsupported settings remain stored but are not active desktop features. Backups do not include downloaded pages or source packages."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !messages.isEmpty {
                ScrollView { Text(messages.joined(separator: "\n\n")).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180).textSelection(.enabled)
            }
            HStack {
                if restoring {
                    ProgressView().controlSize(.small)
                    Text("Restoring…")
                }
                Spacer()
                Button(restored ? "Done" : "Cancel") { dismiss() }.disabled(restoring)
                if restored {
                    Button("Open Imported Library") {
                        dismiss()
                        openWindow(id: "aidoku-backup")
                    }
                } else {
                    Button("Import") { Task { await restore() } }
                        .keyboardShortcut(.defaultAction).disabled(restoring || sources.busy || library.isImporting)
                }
            }
        }
        .padding(24).frame(width: 620)
        .interactiveDismissDisabled(restoring)
    }

    private var counts: some View {
        Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 6) {
            GridRow {
                Text("Library")
                Text("\(preview.backup.library?.count ?? 0)")
            }
            GridRow {
                Text("Chapters / History")
                Text("\(preview.backup.chapters?.count ?? 0) / \(preview.backup.history?.count ?? 0)")
            }
            GridRow {
                Text("Categories / Sources")
                Text("\(preview.backup.categories?.count ?? 0) / \(preview.backup.sources?.count ?? 0)")
            }
            GridRow {
                Text("Repositories / Settings")
                Text("\(preview.backup.sourceLists?.count ?? 0) / \(preview.backup.settings?.count ?? 0)")
            }
        }
    }

    private func restore() async {
        restoring = true
        error = nil
        defer { restoring = false }
        do {
            try library.restoreAidokuBackup(preview, settings: restoreSettings)
            if restoreSettings {
                for key in sources.snapshot.installed.map(\.id) { library.applyAidokuSourceSettings(key, force: true) }
            }
            if restoreSources { messages = await sources.restoreAidokuSources(preview.backup) }
            restored = true
        } catch { self.error = error.localizedDescription }
    }
}

private struct AidokuShelfEntry: Identifiable {
    let library: AidokuBackupLibraryManga
    let manga: AidokuBackupManga?
    var id: [String] { [library.sourceId, library.mangaId] }
}

struct AidokuBackupLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var sources: SourceStore
    @Environment(\.openWindow) private var openWindow
    @State private var category = ""
    @State private var query = ""
    @State private var messages: [String] = []
    @State private var restoring = false
    private var backup: AidokuBackup? { library.aidokuBackup?.backup }

    private var entries: [AidokuShelfEntry] {
        var metadata: [[String]: AidokuBackupManga] = [:]
        for manga in backup?.manga ?? [] { metadata[[manga.sourceId, manga.id]] = manga }
        return (backup?.library ?? []).compactMap { item -> AidokuShelfEntry? in
            let manga = metadata[[item.sourceId, item.mangaId]]
            let title = manga?.title ?? item.mangaId
            let visible =
                (category.isEmpty || item.categories?.contains(category) == true)
                && (query.isEmpty || title.localizedCaseInsensitiveContains(query))
            return visible ? AidokuShelfEntry(library: item, manga: manga) : nil
        }.sorted { $0.library.dateAdded > $1.library.dateAdded }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Category", selection: $category) {
                    Text("All Comics").tag("")
                    ForEach(backup?.categoryTitles ?? [], id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 250)
                Spacer()
                if restoring { ProgressView().controlSize(.small) }
                Button("Restore Missing Sources") {
                    guard let backup else { return }
                    restoring = true
                    Task {
                        messages = await sources.restoreAidokuSources(backup)
                        restoring = false
                    }
                }.disabled(backup == nil || sources.busy || restoring)
            }.padding()
            Divider()
            if let backup {
                List {
                    ForEach(entries) { entry in mangaRow(entry) }
                    Section("Original Backups") {
                        ForEach(library.aidokuBackup?.originals ?? []) { original in
                            HStack {
                                Text(original.filename)
                                Spacer()
                                Button("Save Original…") { export(original) }
                            }
                        }
                    }
                    Section("Preserved Data") {
                        Text(
                            "Tracking: \(backup.trackItems?.count ?? 0) · Reading sessions: \(backup.readingSessions?.count ?? 0) · Vocabulary: \(backup.vocabulary?.count ?? 0) · Updates: \(backup.updates?.count ?? 0)"
                        )
                        Text(
                            "Custom sources, category groups and unsupported settings are stored with the complete original backup. They are not active desktop features."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Aidoku Backup Imported", systemImage: "tray.and.arrow.down",
                    description: Text("Import an .aib backup exported by Aidoku v0.9."))
            }
            if !messages.isEmpty {
                Divider()
                ScrollView {
                    Text(messages.joined(separator: "\n\n")).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .frame(maxHeight: 180).textSelection(.enabled)
            }
        }
        .searchable(text: $query, prompt: "Search imported manga")
        .toolbar {
            Button("Import Aidoku Backup…") {
                openWindow(id: "library")
                library.aidokuImportPanel()
            }.disabled(library.isImporting || library.loadFailed || restoring)
            Button("Manage Sources") { openWindow(id: "sources") }
        }
    }

    private func mangaRow(_ item: AidokuShelfEntry) -> some View {
        let entry = item.library
        let manga = item.manga
        let available = sources.snapshot.installed.contains { $0.id == entry.sourceId }
        return Button {
            openWindow(
                id: "manga",
                value: SourceMangaLink(
                    sourceKey: entry.sourceId, mangaKey: entry.mangaId,
                    title: manga?.title ?? entry.mangaId, cover: manga?.cover))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manga?.title ?? entry.mangaId).font(.headline)
                    Text((entry.categories ?? []).joined(separator: " · ")).font(.caption)
                    Text(entry.sourceId).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !available { Label("Source Missing", systemImage: "exclamationmark.triangle").font(.caption) }
                Image(systemName: "chevron.right")
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func export(_ original: AidokuBackupOriginal) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: original.filename).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            do { try original.data.write(to: url, options: .atomic) } catch { messages = [error.localizedDescription] }
        }
    }
}

extension LibraryStore {
    func applyAidokuMangaOverrides(to manga: inout AidokuRunner.Manga, source: String) {
        if let item = aidokuBackup?.backup.manga?.first(where: { $0.sourceId == source && $0.id == manga.key }),
            let imported = aidokuManga(source: source, key: manga.key)
        {
            let edits = item.editedKeys ?? 0
            if edits & (1 << 0) != 0 { manga.title = imported.title }
            if edits & (1 << 1) != 0 { manga.authors = imported.authors }
            if edits & (1 << 2) != 0 { manga.artists = imported.artists }
            if edits & (1 << 3) != 0 { manga.description = imported.description }
            if edits & (1 << 4) != 0 { manga.tags = imported.tags }
            if edits & (1 << 5) != 0 { manga.cover = imported.cover }
            if edits & (1 << 6) != 0 { manga.url = imported.url }
            if edits & (1 << 7) != 0 { manga.status = imported.status }
            if edits & (1 << 8) != 0 { manga.contentRating = imported.contentRating }
            if imported.viewer != .unknown { manga.viewer = imported.viewer }
            if edits & (1 << 10) != 0 { manga.updateStrategy = imported.updateStrategy }
        }
        if let state = aidokuBackup, state.restoreSourceSettings {
            switch state.backup.readingMode(source: source, manga: manga.key) {
            case "rtl": manga.viewer = .rightToLeft
            case "ltr": manga.viewer = .leftToRight
            case "vertical": manga.viewer = .vertical
            case "webtoon", "scroll", "continuous": manga.viewer = .webtoon
            default: break
            }
        }
    }

    func aidokuManga(source: String, key: String) -> AidokuRunner.Manga? {
        guard let backup = aidokuBackup?.backup,
            let item = backup.manga?.first(where: { $0.sourceId == source && $0.id == key })
        else { return nil }
        let chapters = (backup.chapters ?? []).filter { $0.sourceId == source && $0.mangaId == key }
            .sorted { $0.sourceOrder < $1.sourceOrder }.map { chapter in
                AidokuRunner.Chapter(
                    key: chapter.id, title: chapter.title, chapterNumber: chapter.chapter,
                    volumeNumber: chapter.volume, dateUploaded: chapter.dateUploaded,
                    scanlators: chapter.scanlator.map { $0.components(separatedBy: ", ") },
                    url: chapter.url.flatMap(URL.init(string:)), language: chapter.lang,
                    thumbnail: chapter.thumbnail, locked: chapter.locked ?? false)
            }
        // Backup values use legacy enums. RTL/LTR are reversed in AidokuRunner,
        // and content ratings have a different zero value; raw-value casts are incorrect.
        let viewer: AidokuRunner.Viewer
        switch item.viewer {
        case 1: viewer = .rightToLeft
        case 2: viewer = .leftToRight
        case 3: viewer = .vertical
        case 4: viewer = .webtoon
        default: viewer = .unknown
        }
        let rating: AidokuRunner.ContentRating
        switch item.nsfw {
        case 0: rating = .safe
        case 1: rating = .suggestive
        case 2: rating = .nsfw
        default: rating = .unknown
        }
        let status = UInt8(exactly: item.status).flatMap(AidokuRunner.PublishingStatus.init(rawValue:)) ?? .unknown
        return AidokuRunner.Manga(
            sourceKey: source, key: key, title: item.title, cover: item.cover,
            artists: item.artist.map { $0.components(separatedBy: ", ") },
            authors: item.author.map { $0.components(separatedBy: ", ") },
            description: item.desc, url: item.url.flatMap(URL.init(string:)), tags: item.tags,
            status: status, contentRating: rating, viewer: viewer,
            updateStrategy: item.neverUpdate == true ? .never : .always,
            chapters: chapters)
    }

    func aidokuChapterCompleted(source: String, manga: String, chapter: String) -> Bool {
        if let record = mangaRecord(source: source, key: manga)?.chapterRecord(chapter) {
            return record.isRead
        }
        // Local chapter progress has priority after reading since the import.
        if let book = books.first(where: {
            $0.online?.sourceKey == source && $0.online?.mangaKey == manga && $0.online?.chapterKey == chapter
        }) {
            return book.isRead
        }
        return aidokuHistory(source: source, manga: manga, chapter: chapter)?.completed ?? false
    }
}
