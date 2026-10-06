import AppKit
import MidokuCore
import XCTest
import ZIPFoundation

@testable import Midoku

final class ImporterTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func png(width: Int = 8) throws -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 12, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testDirectoryImportOwnsCopiesInNaturalOrder() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var originals: [Data] = []
        for number in [1, 2, 10] {
            let data = try png(width: number)
            originals.append(data)
            try data.write(to: source.appendingPathComponent("\(number).png"))
        }
        let importer = ComicImporter()
        let book = try await importer.importBook(from: source, into: library)
        XCTAssertEqual(book.pages, ["0.png", "1.png", "2.png"])
        try FileManager.default.removeItem(at: source)
        for (index, page) in book.pages.enumerated() {
            let copy = library.appendingPathComponent(book.id.uuidString).appendingPathComponent(page)
            XCTAssertEqual(try Data(contentsOf: copy), originals[index])
        }
    }

    func testArchiveImportAndUnsafePathRollback() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let bytes = try png()
        let archiveURL = root.appendingPathComponent("safe.cbz")
        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for name in ["2.png", "1.png"] {
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                    bytes.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
        }
        let importer = ComicImporter()
        let book = try await importer.importBook(from: archiveURL, into: library)
        XCTAssertEqual(book.pages.count, 2)
        let unsafeURL = root.appendingPathComponent("unsafe.cbz")
        do {
            let archive = try Archive(url: unsafeURL, accessMode: .create)
            try archive.addEntry(with: "../escape.png", type: .file, uncompressedSize: Int64(bytes.count)) {
                position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        do {
            _ = try await importer.importBook(from: unsafeURL, into: library)
            XCTFail("Unsafe archive must fail")
        } catch { XCTAssertEqual(error as? ImportFailure, .invalidArchive) }
        let contents = try FileManager.default.contentsOfDirectory(atPath: library.path)
        XCTAssertEqual(contents, [book.id.uuidString])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.png").path))
    }

    func testPDFImport() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("comic.pdf")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var bounds = CGRect(x: 0, y: 0, width: 120, height: 180)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(bounds)
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: source)
        let book = try await ComicImporter().importBook(from: source, into: library)
        XCTAssertEqual(book.pages, ["0.jpg", "1.jpg"])
    }

    func testChecksumMismatchRollsBackImport() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("corrupt.cbz")
        let bytes = try png()
        do {
            let archive = try Archive(url: source, accessMode: .create)
            try archive.addEntry(with: "0.png", type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                bytes.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        var archiveBytes = try Data(contentsOf: source)
        // Find the payload from the local header; retain all ZIP metadata while
        // corrupting a stored entry's checksum.
        let nameLength = Int(archiveBytes[26]) | Int(archiveBytes[27]) << 8
        let extraLength = Int(archiveBytes[28]) | Int(archiveBytes[29]) << 8
        let payload = 30 + nameLength + extraLength
        archiveBytes[payload + bytes.count - 1] ^= 1
        try archiveBytes.write(to: source)
        do {
            _ = try await ComicImporter().importBook(from: source, into: library)
            XCTFail("Corrupt archive must fail")
        } catch { XCTAssertEqual(error as? ImportFailure, .invalidArchive) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.path).isEmpty)
    }

    @MainActor func testReadersKeepIndependentStateAndLibraryFailurePreservesFile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let first = ComicBook(title: "First", pages: ["0.png", "1.png"], sourceIdentity: "first")
        let second = ComicBook(title: "Second", pages: ["0.png", "1.png"], sourceIdentity: "second")
        library.commit { $0.books = [first, second] }
        let readerA = ReaderSession(book: first, library: library)
        let readerB = ReaderSession(book: second, library: library)
        readerA.seek(1)
        readerA.zoom = .custom(2)
        XCTAssertEqual(readerB.position.page, 0)
        XCTAssertEqual(readerB.zoom, .page)
        XCTAssertEqual(library.book(first.id)?.currentPage, 1)
        XCTAssertEqual(library.book(second.id)?.currentPage, 0)
        let index = root.appendingPathComponent("library.json")
        let corrupted = Data("corrupted".utf8)
        try corrupted.write(to: index)
        let broken = LibraryStore(root: root)
        broken.commit { $0.books.append(first) }
        XCTAssertTrue(broken.loadFailed)
        XCTAssertEqual(try Data(contentsOf: index), corrupted)
    }
}
