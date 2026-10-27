import UIKit
import CryptoKit

/// On-disk locations the app owns.
enum LocalFiles {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Decant", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let cache: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("DecantImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Writes data under the app's support directory and returns a `file:` path.
    static func write(_ data: Data, folder: String, name: String) throws -> String {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return "file:\(folder)/\(name)"
    }

    static func url(forFilePath path: String) -> URL? {
        guard path.hasPrefix("file:") else { return nil }
        return root.appendingPathComponent(String(path.dropFirst(5)))
    }
}

/// Two-level (memory + disk) image cache with request coalescing.
///
/// Image paths are opaque strings:
/// - `file:<relative>` – stored in Application Support
/// - `http(s)://…` – downloaded and cached on disk
/// - anything else – handed to the backend resolver (e.g. a Supabase storage path)
actor ImageLoader {
    static let shared = ImageLoader()

    typealias Resolver = @Sendable (String) async -> URL?

    // NSCache is internally thread-safe.
    nonisolated(unsafe) private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var resolver: Resolver?

    init() {
        memory.countLimit = 300
        memory.totalCostLimit = 120 * 1024 * 1024
    }

    func setResolver(_ resolver: Resolver?) {
        self.resolver = resolver
    }

    nonisolated func cachedImage(for path: String) -> UIImage? {
        memory.object(forKey: path as NSString)
    }

    func image(for path: String, maxPixel: CGFloat = 1200) async -> UIImage? {
        let key = "\(path)#\(Int(maxPixel))"
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }

        let resolver = self.resolver
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            await Self.load(path: path, maxPixel: maxPixel, resolver: resolver)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key as NSString, cost: cost)
            memory.setObject(image, forKey: path as NSString, cost: cost)
        }
        return image
    }

    private static func load(path: String, maxPixel: CGFloat, resolver: Resolver?) async -> UIImage? {
        if let fileURL = LocalFiles.url(forFilePath: path) {
            return downsample(url: fileURL, maxPixel: maxPixel)
        }
        let diskURL = LocalFiles.cache.appendingPathComponent(diskKey(path))
        if FileManager.default.fileExists(atPath: diskURL.path) {
            return downsample(url: diskURL, maxPixel: maxPixel)
        }
        let remote: URL?
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            remote = URL(string: path)
        } else {
            remote = await resolver?(path)
        }
        guard let remote,
              let (data, response) = try? await URLSession.shared.data(from: remote),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        try? data.write(to: diskURL, options: .atomic)
        return downsample(url: diskURL, maxPixel: maxPixel)
    }

    private static func diskKey(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes at display size using ImageIO, avoiding full-resolution decode.
    private static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension UIImage {
    func jpegForUpload(maxDimension: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
