import AppKit
import MidokuCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    @Published var pendingAidokuBackup: AidokuBackupPreview?
    @Published private(set) var aidokuBackup: AidokuBackupState?
    private(set) var loadFailed = false
    let root: URL
    private let importer = ComicImporter()
    private var aidokuHistoryIndex: [[String]: AidokuBackupHistory] = [:]
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Midoku", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            snapshot = try LibraryPersistence.load(from: indexURL)
            if let file = snapshot.aidokuBackupFile {
                aidokuBackup = try AidokuBackupPersistence.load(from: self.root.appendingPathComponent(file))
                aidokuHistoryIndex = aidokuBackup?.backup.historyByIdentifier ?? [:]
            }
        } catch {
            loadFailed = true  // Never replace an unreadable library with an empty one.
            errorMessage = error.localizedDescription
        }
    }

    var books: [ComicBook] { snapshot.books }
    func book(_ id: UUID) -> ComicBook? { books.first { $0.id == id } }
    func pageURL(for book: ComicBook, at index: Int) -> URL? {
        guard book.pages.indices.contains(index) else { return nil }
        return root.appendingPathComponent(book.id.uuidString, isDirectory: true).appendingPathComponent(
            book.pages[index])
    }

    func commit(_ update: (inout LibrarySnapshot) -> Void) {
        guard !loadFailed else {
            errorMessage =
                "The library could not be loaded. Its files have been preserved. Restart after repairing or restoring library.json."
            return
        }
        var next = snapshot
        update(&next)
        do {
            try LibraryPersistence.save(next, to: indexURL)
            snapshot = next
        } catch { errorMessage = error.localizedDescription }
    }

    func updateBook(_ id: UUID, _ update: (inout ComicBook) -> Void) {
        commit { snapshot in
            guard let index = snapshot.books.firstIndex(where: { $0.id == id }) else { return }
            update(&snapshot.books[index])
        }
    }

    func saveProgress(_ id: UUID, page: Int, finished: Bool = false, offset: Double = 0) {
        updateBook(id) {
            $0.currentPage = min(max(0, page), max(0, $0.pages.count - 1))
            $0.pageOffset = min(1, max(0, offset))
            $0.lastReadAt = Date()
            $0.isRead = $0.isRead || finished
        }
    }

    func remove(_ ids: Set<UUID>) {
        let removed = books.filter { ids.contains($0.id) }
        commit { $0.books.removeAll { ids.contains($0.id) } }
        for old in removed where book(old.id) == nil {
            Task { await RemotePageCache.shared.forget(book: old, root: root) }
        }
        for id in ids where book(id) == nil {
            do { try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString)) } catch {
                errorMessage =
                    "The book was removed from the shelf, but its stored pages could not be deleted: \(error.localizedDescription)"
            }
        }
    }

    func importPanel() {
        guard !isImporting, !loadFailed else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Import comic archives, PDFs, or folders of images")
        panel.allowedContentTypes = [.folder, .image, .pdf, .zip, UTType(filenameExtension: "cbz") ?? .data,
                                     UTType(filenameExtension: "aib") ?? .data, .json, .propertyList]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importFiles(_ urls: [URL]) {
        guard !isImporting, !loadFailed else { return }
        if let backupURL = urls.first(where: { ["aib", "json", "plist"].contains($0.pathExtension.lowercased()) }) {
            guard urls.count == 1 else {
                errorMessage = "Import an Aidoku backup separately from comic files."
                return
            }
            previewAidokuBackup(backupURL)
            return
        }
        isImporting = true
        Task {
            defer { isImporting = false }
            var failures: [String] = []
            for url in urls {
                let identity = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard !books.contains(where: { $0.sourceIdentity == identity }) else { continue }
                do {
                    let book = try await importer.importBook(from: url, into: root)
                    commit { $0.books.append(book) }
                    if self.book(book.id) == nil {
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(book.id.uuidString))
                    }
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    func aidokuImportPanel() {
        guard !isImporting, !loadFailed else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "aib") ?? .data, .json, .propertyList]
        panel.message = "Choose a backup exported by Aidoku v0.9"
        if panel.runModal() == .OK, let url = panel.url { previewAidokuBackup(url) }
    }

    private func previewAidokuBackup(_ url: URL) {
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                pendingAidokuBackup = try await Task.detached { try AidokuBackupPreview.load(url) }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Write the entire library atomically before applying preferences or fetching sources.
    /// A copy of the previous library remains available even when no library file existed yet.
    func restoreAidokuBackup(_ preview: AidokuBackupPreview, settings: Bool) throws {
        guard !loadFailed, !isImporting else { throw CocoaError(.fileWriteUnknown) }
        var next = snapshot
        let archive = aidokuBackup?.merging(
            backup: preview.backup, data: preview.data, filename: preview.filename,
            restoreSourceSettings: settings)
            ?? AidokuBackupState(backup: preview.backup, data: preview.data,
                                 filename: preview.filename, restoreSourceSettings: settings)
        for title in preview.backup.categoryTitles where !next.collections.contains(title) {
            next.collections.append(title)
        }
        let histories = archive.backup.historyByIdentifier
        for index in next.books.indices {
            if let reference = next.books[index].online {
                applyHistory(to: &next.books[index], history: histories[[reference.sourceKey, reference.mangaKey, reference.chapterKey]])
            }
        }
        let directory = root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try LibraryPersistence.save(snapshot, to: directory.appendingPathComponent("before-aidoku-\(UUID()).json"))
        let archiveDirectory = root.appendingPathComponent("AidokuBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archiveFile = "AidokuBackups/\(UUID()).json"
        let archiveURL = root.appendingPathComponent(archiveFile)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: archiveURL) } }
        try AidokuBackupPersistence.save(archive, to: archiveURL)
        next.aidokuBackupFile = archiveFile
        try LibraryPersistence.save(next, to: indexURL)
        committed = true
        snapshot = next
        aidokuBackup = archive
        aidokuHistoryIndex = histories
        if settings {
            for (key, value) in preview.backup.desktopSettings {
                UserDefaults.standard.set(value.rawValue, forKey: key)
            }
        }
    }

    func aidokuHistory(source: String, manga: String, chapter: String) -> AidokuBackupHistory? {
        aidokuHistoryIndex[[source, manga, chapter]]
    }

    func applyImportedHistory(to book: inout ComicBook) {
        guard let reference = book.online else { return }
        applyHistory(to: &book, history: aidokuHistory(source: reference.sourceKey, manga: reference.mangaKey,
                                                    chapter: reference.chapterKey))
    }

    private func applyHistory(to book: inout ComicBook, history: AidokuBackupHistory?) {
        guard let history,
            book.lastReadAt == nil || history.dateRead > book.lastReadAt!
        else { return }
        book.currentPage = history.pageIndex(pageCount: book.pages.count)
        book.isRead = history.completed
        book.lastReadAt = history.dateRead
        book.pageOffset = nil // Aidoku v0.9 exports page progress, but no within-page scroll offset.
    }

    func applyAidokuSourceSettings(_ key: String, force: Bool = false) {
        guard let state = aidokuBackup, state.restoreSourceSettings else { return }
        let revision = state.originals.last?.id.uuidString ?? ""
        let marker = "midoku.aidoku.settingsRevision." + key
        guard force || UserDefaults.standard.string(forKey: marker) != revision else { return }
        for (setting, value) in state.backup.sourceSettings(for: key) {
            UserDefaults.standard.set(value.rawValue, forKey: setting)
        }
        UserDefaults.standard.set(revision, forKey: marker)
    }
}
