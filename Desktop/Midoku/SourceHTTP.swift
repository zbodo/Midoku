import AidokuRunner
import AppKit
import Foundation
import WebKit

enum SourceFailure: LocalizedError {
    case response(Int)
    case tooLarge, invalidPackage
    case noSource(String)
    case noPages, unsupportedPage
    var errorDescription: String? {
        switch self {
        case .response(let status):
            "The server returned HTTP \(status). Open the source website to sign in or complete verification, then retry."
        case .tooLarge: "The response exceeds the supported size limit."
        case .invalidPackage:
            "The package is not a valid modern Aidoku source, or its identity, version or checksum does not match the repository."
        case .noSource(let key): "Source \(key) is not installed. Reinstall it from Sources to read this chapter."
        case .noPages: "The source returned no pages for this chapter."
        case .unsupportedPage: "The source returned a page that is not an image."
        }
    }
}

enum SourceHTTP {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    static func request(_ original: URLRequest, sourceKey: String) async throws -> (Data, URLResponse) {
        guard let url = original.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw RepositoryError.invalidURL
        }
        var request = original
        let cookies = await cookies(for: sourceKey)
        addCookies(cookies, to: &request)
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.timeoutInterval = min(max(request.timeoutInterval, 15), 60)
        let (file, response) = try await session.download(
            for: request, delegate: SourceRequestDelegate(sourceKey: sourceKey, original: original))
        defer { try? FileManager.default.removeItem(at: file) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1024 * 1024 else { throw SourceFailure.tooLarge }
        if let http = response as? HTTPURLResponse { await saveCookies(http, for: sourceKey) }
        // WASM sources inspect non-2xx responses themselves. Image and catalog
        // callers apply status validation before interpreting the body.
        return (try Data(contentsOf: file), response)
    }

    static func addCookies(_ cookies: [HTTPCookie], to request: inout URLRequest) {
        guard let url = request.url else { return }
        let providedNames = Set(
            (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";").compactMap { field -> String? in
                guard let separator = field.firstIndex(of: "=") else { return nil }
                return String(field[..<separator]).trimmingCharacters(in: .whitespaces)
            })
        let matched = cookies.filter { cookie in
            let host = url.host?.lowercased() ?? ""
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matchesDomain = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let path = url.path.isEmpty ? "/" : url.path
            let matchesPath =
                path == cookie.path
                || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            return !providedNames.contains(cookie.name) && matchesDomain && matchesPath
                && (!cookie.isSecure || url.scheme?.lowercased() == "https")
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        if !matched.isEmpty {
            let existing = request.value(forHTTPHeaderField: "Cookie")
            let fields = HTTPCookie.requestHeaderFields(with: matched)
            request.setValue(
                [existing, fields["Cookie"]].compactMap { $0 }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
    }

    static func saveCookies(_ response: HTTPURLResponse, for key: String) async {
        guard let url = response.url else { return }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String { result[name] = String(describing: field.value) }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) { await save(cookie, for: key) }
    }

    @MainActor private static func save(_ cookie: HTTPCookie, for key: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.forSource(key: key).httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    @MainActor static func cookies(for key: String) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.forSource(key: key).httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    static func requireSuccess(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw SourceFailure.response(0) }
        guard (200..<300).contains(response.statusCode) else { throw SourceFailure.response(response.statusCode) }
    }
}

// Bound temporary downloads before allocating their response bodies in memory.
class SizeLimitedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
}

private final class SourceRequestDelegate: SizeLimitedDownloadDelegate, @unchecked Sendable {
    let sourceKey: String
    let original: URLRequest
    init(sourceKey: String, original: URLRequest) {
        self.original = original
        self.sourceKey = sourceKey
        super.init(limit: 256 * 1024 * 1024)
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        Task {
            await SourceHTTP.saveCookies(response, for: sourceKey)
            var redirected = request
            let sameHost = original.url?.host?.lowercased() == redirected.url?.host?.lowercased()
            let downgrade =
                original.url?.scheme?.lowercased() == "https" && redirected.url?.scheme?.lowercased() == "http"
            redirected.setValue(
                sameHost && !downgrade ? original.value(forHTTPHeaderField: "Cookie") : nil,
                forHTTPHeaderField: "Cookie")
            if response.url?.host != redirected.url?.host
                || (response.url?.scheme?.lowercased() == "https" && redirected.url?.scheme?.lowercased() == "http")
            {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            SourceHTTP.addCookies(await SourceHTTP.cookies(for: sourceKey), to: &redirected)
            completionHandler(redirected)
        }
    }
}
