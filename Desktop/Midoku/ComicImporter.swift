import AppKit
import ImageIO
import MidokuCore
import UniformTypeIdentifiers
import ZIPFoundation

enum ImportFailure: LocalizedError, Equatable {
    case unsupported, empty, tooLarge, invalidArchive
    var errorDescription: String? {
        switch self {
        case .unsupported:
            "Choose a CBZ, ZIP, PDF, image, or folder of comic pages. RAR/CBR archives are not supported yet."
        case .empty: "No readable comic pages were found."
        case .tooLarge: "This comic exceeds the import limit (10,000 pages, 256 MB per page, or 4 GB total)."
        case .invalidArchive: "The archive contains unsafe paths or links."
        }
    }
}

// Imported books own their files. Closing a reader or moving the original file
// cannot revoke access to a book in the library.
actor ComicImporter {
    static let maximumPageBytes: UInt64 = 256 * 1024 * 1024
    static let maximumTotalBytes: UInt64 = 4 * 1024 * 1024 * 1024
    static let maximumPageCount = 10_000

    func importBook(from source: URL, into root: URL) throws -> ComicBook {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let temporary = root.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ImportFailure.invalidArchive }
        let pages: [String]
        if values.isDirectory == true {
            pages = try importDirectory(source, into: temporary)
        } else {
            switch source.pathExtension.lowercased() {
            case "cbz", "zip": pages = try importArchive(source, into: temporary)
            case "pdf": pages = try importPDF(source, into: temporary)
            default:
                guard PageCatalog.imageExtensions.contains(source.pathExtension.lowercased()) else {
                    throw ImportFailure.unsupported
                }
                pages = try copyPages([source], into: temporary)
            }
        }
        guard !pages.isEmpty else { throw ImportFailure.empty }
        // Validate the cover while import can still roll back. Individual page
        // decode failures are reported by the reader rather than silently hidden.
        let coverURL = temporary.appendingPathComponent(pages[0])
        guard let imageSource = CGImageSourceCreateWithURL(coverURL as CFURL, nil),
            CGImageSourceGetCount(imageSource) > 0
        else { throw ImportFailure.empty }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return ComicBook(
            id: id,
            title: values.isDirectory == true
                ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent,
            pages: pages, sourceIdentity: source.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    private func importDirectory(_ source: URL, into destination: URL) throws -> [String] {
        var traversalError: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    traversalError = error
                    return false
                }
            )
        else { throw ImportFailure.empty }
        var urls: [String: URL] = [:]
        for case let url as URL in enumerator {
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true else { throw ImportFailure.invalidArchive }
            if properties.isRegularFile == true {
                let relative = String(url.path.dropFirst(source.path.count + 1))
                if PageCatalog.isImage(relative) { urls[relative] = url }
            }
            guard urls.count <= Self.maximumPageCount else { throw ImportFailure.tooLarge }
        }
        if let traversalError { throw traversalError }
        return try copyPages(PageCatalog.sorted(Array(urls.keys)).compactMap { urls[$0] }, into: destination)
    }

    private func copyPages(_ urls: [URL], into destination: URL) throws -> [String] {
        guard urls.count <= Self.maximumPageCount else { throw ImportFailure.tooLarge }
        var total: UInt64 = 0
        return try urls.enumerated().map { index, url in
            let size = UInt64(max(0, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
            total += size
            guard size <= Self.maximumPageBytes, total <= Self.maximumTotalBytes else { throw ImportFailure.tooLarge }
            let filename = "\(index).\(url.pathExtension.lowercased())"
            try FileManager.default.copyItem(at: url, to: destination.appendingPathComponent(filename))
            return filename
        }
    }

    private func importArchive(_ source: URL, into destination: URL) throws -> [String] {
        let archive = try Archive(url: source, accessMode: .read)
        var entries: [String: Entry] = [:]
        var total: UInt64 = 0
        for entry in archive {
            guard entry.type != .symlink else { throw ImportFailure.invalidArchive }
            guard entry.type != .file || PageCatalog.isSafeRelativePath(entry.path) else {
                throw ImportFailure.invalidArchive
            }
            guard entry.type == .file, PageCatalog.isImage(entry.path) else { continue }
            guard entries[entry.path] == nil else { throw ImportFailure.invalidArchive }
            guard entry.uncompressedSize <= Self.maximumPageBytes else { throw ImportFailure.tooLarge }
            total += entry.uncompressedSize
            guard total <= Self.maximumTotalBytes else { throw ImportFailure.tooLarge }
            entries[entry.path] = entry
            guard entries.count <= Self.maximumPageCount else { throw ImportFailure.tooLarge }
        }
        return try PageCatalog.sorted(Array(entries.keys)).enumerated().map { index, path in
            let filename = "\(index).\(URL(fileURLWithPath: path).pathExtension.lowercased())"
            // Calculate AND compare CRC32. Bound actual streamed bytes as well as
            // the archive's declared sizes. Never extract to an archive-supplied path.
            let entry = entries[path]!
            let url = destination.appendingPathComponent(filename)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ImportFailure.invalidArchive
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var written: UInt64 = 0
            let checksum = try archive.extract(entry) { chunk in
                written += UInt64(chunk.count)
                guard written <= entry.uncompressedSize, written <= Self.maximumPageBytes else {
                    throw ImportFailure.tooLarge
                }
                try handle.write(contentsOf: chunk)
            }
            guard checksum == entry.checksum, written == entry.uncompressedSize else {
                throw ImportFailure.invalidArchive
            }
            return filename
        }
    }

    private func importPDF(_ source: URL, into destination: URL) throws -> [String] {
        guard let document = CGPDFDocument(source as CFURL), !document.isEncrypted else {
            throw ImportFailure.unsupported
        }
        guard document.numberOfPages > 0, document.numberOfPages <= Self.maximumPageCount else {
            throw ImportFailure.tooLarge
        }
        var total: UInt64 = 0
        return try (1...document.numberOfPages).map { number in
            try autoreleasepool {
                guard let page = document.page(at: number) else { throw ImportFailure.empty }
                let bounds = page.getBoxRect(.mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { throw ImportFailure.empty }
                let scale = min(2, 3200 / max(bounds.width, bounds.height))
                let width = max(1, Int(bounds.width * scale))
                let height = max(1, Int(bounds.height * scale))
                guard
                    let context = CGContext(
                        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    )
                else { throw ImportFailure.empty }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                let renderRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
                context.fill(renderRect)
                context.concatenate(
                    page.getDrawingTransform(.mediaBox, rect: renderRect, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(page)
                guard let image = context.makeImage() else { throw ImportFailure.empty }
                let name = "\(number - 1).jpg"
                let url = destination.appendingPathComponent(name)
                guard
                    let output = CGImageDestinationCreateWithURL(
                        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { throw ImportFailure.empty }
                CGImageDestinationAddImage(
                    output, image, [kCGImageDestinationLossyCompressionQuality as String: 0.92] as CFDictionary)
                guard CGImageDestinationFinalize(output) else { throw ImportFailure.empty }
                total += UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                guard total <= Self.maximumTotalBytes else { throw ImportFailure.tooLarge }
                return name
            }
        }
    }
}
