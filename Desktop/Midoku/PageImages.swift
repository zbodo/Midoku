import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct PagePreview: Sendable {
    let data: Data
    let width: Double
    let height: Double
    @MainActor func image() -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: width, height: height)
        return image
    }
}

private final class PreviewBox: NSObject {
    let preview: PagePreview
    init(_ preview: PagePreview) { self.preview = preview }
}

actor PageImages {
    static let shared = PageImages()
    private let cache = NSCache<NSURL, PreviewBox>()
    init() { cache.totalCostLimit = 64 * 1024 * 1024 }

    func preview(for url: URL, maximumDimension: Int = 4000) async throws -> PagePreview {
        let cacheKey = url.appendingPathExtension("preview-\(maximumDimension)") as NSURL
        if let cached = cache.object(forKey: cacheKey) { return cached.preview }
        try await RemotePageCache.shared.ensureFile(at: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                    kCGImageSourceCreateThumbnailWithTransform as String: true,
                    kCGImageSourceThumbnailMaxPixelSize as String: maximumDimension,
                    kCGImageSourceShouldCacheImmediately as String: true,
                ] as CFDictionary)
        else { throw ImportFailure.empty }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw ImportFailure.empty }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportFailure.empty }
        let data = output as Data
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        var width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? Double(image.width)
        var height =
            (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? Double(image.height)
        if let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue,
            (5...8).contains(orientation)
        {
            swap(&width, &height)
        }
        let preview = PagePreview(data: data, width: width, height: height)
        cache.setObject(PreviewBox(preview), forKey: cacheKey, cost: data.count)
        return preview
    }
}

struct ComicImage: View {
    let url: URL?
    var maximumDimension = 4000
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .accessibilityLabel("Page could not be decoded")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            guard let url else {
                failed = true
                return
            }
            do {
                let preview = try await PageImages.shared.preview(for: url, maximumDimension: maximumDimension)
                try Task.checkCancellation()
                image = preview.image()
                failed = image == nil
            } catch is CancellationError {} catch { failed = true }
        }
        .onDisappear { image = nil }
    }
}
