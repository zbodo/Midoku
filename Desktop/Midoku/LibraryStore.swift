import AppKit
import MidokuCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var snapshot = LibrarySnapshot()
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?
    private(set) var loadFailed = false
    let root: URL
    private let importer = ComicImporter()
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Midoku", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            snapshot = try LibraryPersistence.load(from: indexURL)
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

    func saveProgress(_ id: UUID, page: Int, finished: Bool = false) {
        updateBook(id) {
            $0.currentPage = min(max(0, page), max(0, $0.pages.count - 1))
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
        panel.allowedContentTypes = [.folder, .image, .pdf, .zip, UTType(filenameExtension: "cbz") ?? .data]
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importFiles(_ urls: [URL]) {
        guard !isImporting, !loadFailed else { return }
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
}
