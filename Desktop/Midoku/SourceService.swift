import AidokuRunner
import CryptoKit
import Foundation
import MidokuCore
import ZIPFoundation

struct InstalledSource: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: Int
    let languages: [String]
    let folder: UUID
    let repository: URL
}

struct SavedRepository: Codable, Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    var catalog: SourceCatalog
    var indexURL: URL? = nil
}

struct SourceSnapshot: Codable, Sendable {
    var repositories: [SavedRepository] = []
    var installed: [InstalledSource] = []
}

actor SourceService {
    let root: URL
    private var snapshot: SourceSnapshot
    private var loaded: [String: AidokuRunner.Source] = [:]
    private var loading: [String: (UUID, Task<AidokuRunner.Source, Error>)] = [:]

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sources.json")
        snapshot =
            FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(SourceSnapshot.self, from: Data(contentsOf: file)) : SourceSnapshot()
        guard Set(snapshot.installed.map(\.id)).count == snapshot.installed.count,
            snapshot.installed.allSatisfy({ SourceCatalog.validSourceKey($0.id) })
        else { throw RepositoryError.invalidCatalog }
    }

    func state() -> SourceSnapshot { snapshot }

    private func persist(_ next: SourceSnapshot) throws {
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("sources.json"), options: .atomic)
        snapshot = next
    }

    func addRepository(_ address: RepositoryAddress) async throws {
        let (file, response) = try await URLSession.shared.download(
            for: URLRequest(url: address.url), delegate: SizeLimitedDownloadDelegate(limit: 8 * 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else {
            throw SourceFailure.tooLarge
        }
        let data = try Data(contentsOf: file)
        try SourceHTTP.requireSuccess(response)
        guard data.count <= 8 * 1024 * 1024 else { throw SourceFailure.tooLarge }
        let catalog = try SourceCatalog.decode(data)
        let indexURL = response.url ?? address.url
        for entry in catalog.sources { _ = try entry.packageURL(relativeTo: indexURL) }
        var next = snapshot
        if let index = next.repositories.firstIndex(where: { $0.url == address.url }) {
            next.repositories[index].catalog = catalog
            next.repositories[index].indexURL = indexURL
        } else {
            next.repositories.append(SavedRepository(url: address.url, catalog: catalog, indexURL: indexURL))
        }
        try persist(next)
    }

    func removeRepository(_ url: URL) throws {
        var next = snapshot
        next.repositories.removeAll { $0.url == url }
        try persist(next)
    }

    func source(_ key: String) async throws -> AidokuRunner.Source {
        if let existing = loaded[key] { return existing }
        guard let record = snapshot.installed.first(where: { $0.id == key }) else { throw SourceFailure.noSource(key) }
        let task: Task<AidokuRunner.Source, Error>
        if let pending = loading[key], pending.0 == record.folder {
            task = pending.1
        } else {
            let url = root.appendingPathComponent(record.folder.uuidString)
            task = Task { try await Self.load(at: url, key: key) }
            loading[key] = (record.folder, task)
        }
        defer { if loading[key]?.0 == record.folder { loading[key] = nil } }
        let source = try await task.value
        guard snapshot.installed.first(where: { $0.id == key })?.folder == record.folder else {
            throw SourceFailure.noSource(key)
        }
        loaded[key] = source
        return source
    }

    static func load(at url: URL, key: String) async throws -> AidokuRunner.Source {
        try await SourceCredentials.restore(sourceKey: key)
        let source = try await AidokuRunner.Source(
            url: url,
            interpreterConfig: .init(requestHandler: { request in
                try await SourceHTTP.request(request, sourceKey: key)
            }))
        guard source.key == key else { throw SourceFailure.invalidPackage }
        return source
    }

    func install(_ entry: SourceCatalogEntry, repository: URL) async throws {
        let baseURL = snapshot.repositories.first(where: { $0.url == repository })?.indexURL ?? repository
        let url = try entry.packageURL(relativeTo: baseURL)
        let (file, response) = try await URLSession.shared.download(
            for: URLRequest(url: url), delegate: SizeLimitedDownloadDelegate(limit: 32 * 1024 * 1024))
        defer { try? FileManager.default.removeItem(at: file) }
        try SourceHTTP.requireSuccess(response)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32 * 1024 * 1024 else {
            throw SourceFailure.tooLarge
        }
        if let expected = entry.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw SourceFailure.invalidPackage }
        }
        let generation = UUID()
        let destination = root.appendingPathComponent(generation.uuidString, isDirectory: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        try Self.extractPackage(file, into: destination)
        let manifest = try JSONDecoder().decode(
            AidokuRunner.SourceInfo.self, from: Data(contentsOf: destination.appendingPathComponent("source.json")))
        guard manifest.info.id == entry.id, manifest.info.version == entry.version else {
            throw SourceFailure.invalidPackage
        }
        let source = try await Self.load(at: destination, key: entry.id)
        var next = snapshot
        let previous = next.installed.first { $0.id == entry.id }
        next.installed.removeAll { $0.id == entry.id }
        next.installed.append(
            .init(
                id: entry.id, name: source.name, version: source.version, languages: source.languages,
                folder: generation, repository: repository))
        try persist(next)
        committed = true
        loading[entry.id]?.1.cancel()
        loading[entry.id] = nil
        loaded[entry.id] = source
        if let previous {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(previous.folder.uuidString))
        }
    }

    func uninstall(_ key: String) throws {
        guard let previous = snapshot.installed.first(where: { $0.id == key }) else { return }
        var next = snapshot
        next.installed.removeAll { $0.id == key }
        try persist(next)
        loading[key]?.1.cancel()
        loading[key] = nil
        loaded[key] = nil
        try FileManager.default.removeItem(at: root.appendingPathComponent(previous.folder.uuidString))
    }

    static func extractPackage(_ file: URL, into destination: URL) throws {
        let archive = try Archive(url: file, accessMode: .read)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var total: UInt64 = 0
        var names: Set<String> = []
        for entry in archive {
            guard entry.type != .symlink else { throw SourceFailure.invalidPackage }
            guard entry.type == .file else { continue }
            guard entry.path.hasPrefix("Payload/"), PageCatalog.isSafeRelativePath(entry.path),
                names.insert(entry.path).inserted,
                entry.uncompressedSize <= 32 * 1024 * 1024, names.count <= 100
            else { throw SourceFailure.invalidPackage }
            total += entry.uncompressedSize
            guard total <= 64 * 1024 * 1024 else { throw SourceFailure.tooLarge }
            let relative = String(entry.path.dropFirst("Payload/".count))
            let output = destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                throw SourceFailure.invalidPackage
            }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            var size: UInt64 = 0
            let checksum = try archive.extract(entry) { bytes in
                size += UInt64(bytes.count)
                guard size <= entry.uncompressedSize else { throw SourceFailure.tooLarge }
                try handle.write(contentsOf: bytes)
            }
            guard checksum == entry.checksum, size == entry.uncompressedSize else { throw SourceFailure.invalidPackage }
        }
        guard FileManager.default.fileExists(atPath: destination.appendingPathComponent("main.wasm").path),
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("source.json").path)
        else { throw SourceFailure.invalidPackage }
    }
}
