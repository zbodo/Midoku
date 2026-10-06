import AidokuRunner
import CryptoKit
import Foundation
import ImageIO
import MidokuCore
import ZIPFoundation

actor RemotePageCache {
    static let shared = RemotePageCache()
    private struct Descriptor: Sendable {
        let source: AidokuRunner.Source
        let page: AidokuRunner.Page
        let cover: Bool
    }
    typealias Fetch = @Sendable (URLRequest, String) async throws -> (Data, URLResponse)
    private let fetch: Fetch
    init(fetch: @escaping Fetch = { request, key in try await SourceHTTP.request(request, sourceKey: key) }) {
        self.fetch = fetch
    }
    private var descriptors: [URL: Descriptor] = [:]
    private var tasks: [URL: (UUID, Task<Void, Error>)] = [:]

    func isRegistered(book: ComicBook, root: URL) -> Bool {
        book.pages.allSatisfy {
            descriptors[root.appendingPathComponent(book.id.uuidString).appendingPathComponent($0)] != nil
        }
    }

    func register(book: ComicBook, source: AidokuRunner.Source, pages: [AidokuRunner.Page], root: URL) {
        let directory = root.appendingPathComponent(book.id.uuidString)
        let allowed = Set(book.pages.map { directory.appendingPathComponent($0) })
        let obsolete = descriptors.keys.filter { $0.path.hasPrefix(directory.path + "/") && !allowed.contains($0) }
        for url in obsolete {
            tasks[url]?.1.cancel()
            tasks[url] = nil
            descriptors[url] = nil
        }
        for (index, page) in pages.enumerated() where book.pages.indices.contains(index) {
            let url = root.appendingPathComponent(book.id.uuidString).appendingPathComponent(book.pages[index])
            descriptors[url] = Descriptor(source: source, page: page, cover: false)
        }
    }

    static func coverPath(_ raw: String, sourceKey: String, root: URL) throws -> URL {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw RepositoryError.invalidURL
        }
        let key = SHA256.hash(data: Data((sourceKey + "\n" + raw).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Covers").appendingPathComponent(key + ".image")
    }

    func coverURL(_ raw: String, source: AidokuRunner.Source, root: URL) throws -> URL {
        let output = try Self.coverPath(raw, sourceKey: source.key, root: root)
        guard let url = URL(string: raw) else { throw RepositoryError.invalidURL }
        descriptors[output] = Descriptor(source: source, page: .init(content: .url(url: url)), cover: true)
        return output
    }

    func ensureFile(at url: URL) async throws {
        guard !FileManager.default.fileExists(atPath: url.path), let descriptor = descriptors[url] else { return }
        if let task = tasks[url] {
            try await task.1.value
            return
        }
        let token = UUID()
        let task = Task {
            let data = try await Self.imageData(descriptor, fetch: fetch)
            guard !data.isEmpty, data.count <= 256 * 1024 * 1024,
                CGImageSourceCreateWithData(data as CFData, nil) != nil
            else { throw SourceFailure.unsupportedPage }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        tasks[url] = (token, task)
        defer { if tasks[url]?.0 == token { tasks[url] = nil } }
        try await task.value
    }

    func unregister(sourceKey: String) {
        let urls = descriptors.filter { $0.value.source.key == sourceKey }.map(\.key)
        for url in urls {
            tasks[url]?.1.cancel()
            tasks[url] = nil
            descriptors[url] = nil
        }
    }

    func forget(book: ComicBook, root: URL) {
        let directory = root.appendingPathComponent(book.id.uuidString)
        let urls = Set(descriptors.keys).union(tasks.keys).filter { $0.path.hasPrefix(directory.path + "/") }
        for url in urls {
            tasks[url]?.1.cancel()
            tasks[url] = nil
            descriptors[url] = nil
        }
    }

    private static func imageData(_ descriptor: Descriptor, fetch: Fetch) async throws -> Data {
        switch descriptor.page.content {
        case .image(let image):
            guard let data = image.pngData() else { throw SourceFailure.unsupportedPage }
            return data
        case .text: throw SourceFailure.unsupportedPage
        case .url(let url, let context):
            let request = try await imageRequest(url, source: descriptor.source, context: context)
            let (data, response) = try await fetch(request, descriptor.source.key)
            let processes =
                descriptor.cover
                ? descriptor.source.features.processesCovers : descriptor.source.features.processesPages
            if processes {
                let pointer: Int32
                if let image = AidokuRunner.PlatformImage(data: data) {
                    pointer = try await descriptor.source.store(value: image)
                } else {
                    pointer = try await descriptor.source.store(value: data)
                }
                do {
                    let http = response as? HTTPURLResponse
                    let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { result, field in
                        if let key = field.key as? String { result[key] = String(describing: field.value) }
                    }
                    let input = AidokuRunner.Response(
                        code: http?.statusCode ?? 200, headers: headers,
                        request: .init(url: request.url, headers: request.allHTTPHeaderFields ?? [:]), image: pointer)
                    let output =
                        descriptor.cover
                        ? try await descriptor.source.processCoverImage(response: input)
                        : try await descriptor.source.processPageImage(response: input, context: context)
                    try await descriptor.source.remove(value: pointer)
                    if let bytes = output?.pngData() { return bytes }
                } catch {
                    try? await descriptor.source.remove(value: pointer)
                    throw error
                }
            }
            try SourceHTTP.requireSuccess(response)
            return data
        case .zipFile(let url, let path):
            guard PageCatalog.isImage(path) else { throw SourceFailure.unsupportedPage }
            let request = try await imageRequest(url, source: descriptor.source, context: nil)
            let (data, response) = try await fetch(request, descriptor.source.key)
            try SourceHTTP.requireSuccess(response)
            let archive = try Archive(data: data, accessMode: .read)
            guard let entry = archive[path], entry.type == .file,
                entry.uncompressedSize <= 256 * 1024 * 1024
            else { throw SourceFailure.unsupportedPage }
            var output = Data()
            let checksum = try archive.extract(entry) { bytes in
                guard UInt64(output.count + bytes.count) <= entry.uncompressedSize else { throw SourceFailure.tooLarge }
                output.append(bytes)
            }
            guard checksum == entry.checksum, UInt64(output.count) == entry.uncompressedSize else {
                throw SourceFailure.invalidPackage
            }
            return output
        }
    }

    private static func imageRequest(_ url: URL, source: AidokuRunner.Source, context: AidokuRunner.PageContext?)
        async throws -> URLRequest
    {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw RepositoryError.invalidURL }
        if source.features.providesImageRequests {
            return try await source.getImageRequest(url: url.absoluteString, context: context)
        }
        var request = URLRequest(url: url)
        let selected: String = SettingsStore.shared.get(key: source.key + ".url")
        let selectedURL = URL(string: selected).flatMap {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil
        }
        let dynamicURL = source.features.providesBaseUrl ? try await source.getBaseUrl() : nil
        if let referer = dynamicURL ?? selectedURL ?? source.urls.first {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }
}
