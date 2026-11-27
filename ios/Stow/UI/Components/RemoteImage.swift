import ImageIO
import SwiftUI
import UIKit

/// Loads thumbnails and channel pictures, keeping them on disk (Caches/images, through URLCache)
/// and, decoded at the size shown, in memory. YouTube's image URLs don't change content, so a
/// cached copy is used however old it is.
nonisolated final class ImagePipeline: Sendable {
    static let shared = ImagePipeline()

    // NSCache is thread-safe.
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession

    init() {
        memory.totalCostLimit = 64 << 20
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 << 20,
                                          directory: caches.appending(path: "images", directoryHint: .isDirectory))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    /// Already decoded at this size, if so.
    func cached(_ url: URL, maxPixels: Int) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixels))
    }

    /// The image, scaled down so its longer side is at most `maxPixels`.
    func image(_ url: URL, maxPixels: Int) async throws -> UIImage {
        let key = Self.key(url, maxPixels)
        if let image = memory.object(forKey: key) { return image }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()
        guard let image = Self.decode(data, maxPixels: maxPixels) else { throw URLError(.cannotDecodeContentData) }
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    private static func key(_ url: URL, _ maxPixels: Int) -> NSString {
        "\(maxPixels)|\(url.absoluteString)" as NSString
    }

    /// Decodes straight to the size shown, so a list of thumbnails doesn't hold full-size bitmaps.
    private static func decode(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// An image from the web, filling its frame (cropped); nothing until it loads.
struct RemoteImage: View {
    let url: URL?
    /// The longer side to decode at, in pixels.
    var maxPixels = 720

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    init(url: URL?, maxPixels: Int = 720) {
        self.url = url
        self.maxPixels = maxPixels
        // From memory right away, so a list scrolling back doesn't flash empty frames.
        let cached = url.flatMap { ImagePipeline.shared.cached($0, maxPixels: maxPixels) }
        _image = State(initialValue: cached)
        _loadedURL = State(initialValue: cached == nil ? nil : url)
    }

    init(_ string: String?, maxPixels: Int = 720) {
        self.init(url: string.flatMap(URL.init(string:)), maxPixels: maxPixels)
    }

    var body: some View {
        Color.clear
            .overlay {
                if let image, loadedURL == url {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url, loadedURL != url else { return }
                if let cached = ImagePipeline.shared.cached(url, maxPixels: maxPixels) {
                    image = cached
                    loadedURL = url
                    return
                }
                guard let loaded = try? await ImagePipeline.shared.image(url, maxPixels: maxPixels) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    image = loaded
                    loadedURL = url
                }
            }
    }
}
