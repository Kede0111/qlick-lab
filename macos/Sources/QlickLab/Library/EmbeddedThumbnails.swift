// Qlick Lab — GPL-3.0-only.
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Qlick Lab: the photographs' own small pictures, kept on this Mac: a RAW's embedded JPEG, or a JPEG, PNG or TIFF
/// reduced, at `side` pixels on the long side. A folder on another computer (a NAS) is otherwise read again over
/// the network for every cell shown; once kept, a cell shows at once, and the file is read again only when it
/// changes (its path, size and date name the copy).
///
/// Cells read them as they're shown (`PhotoThumbnails`), so only what's on screen is ever read; Build Thumbnails
/// reads a whole selection ahead (`extract`), several files at a time. Past `limit`, the least recently used go.
enum EmbeddedThumbnails {
    /// The grid's largest size: the smaller are read from this copy.
    static let side = PhotoThumbnails.Size.large.rawValue
    static let limit = 1024 * 1024 * 1024
    /// How many files Build Thumbnails reads at once: a network volume answers several requests in the time of one.
    static let width = 4

    /// The app's; under XCTest a temporary folder, never the user's Caches.
    static let directory: URL = {
        let folder = NSClassFromString("XCTestCase") != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("qlick-embedded-\(UUID().uuidString)", isDirectory: true)
            : AppDataLocations.cachesDirectory.appendingPathComponent("Embedded Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// The copy's file: named by the photograph's path, size and date, so a changed file is never found.
    static func file(for photo: PhotoFile) -> URL? {
        guard let modified = photo.modified else { return nil }
        let path = photo.url.photoFile.labStandardized.path
        let name = SHA256.hash(data: Data("1|\(path)|\(photo.size ?? -1)|\(modified.timeIntervalSince1970)".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg")
    }

    /// The kept copy at most `maxPixels` on its long side; nil if there's none.
    static func cached(_ photo: PhotoFile, maxPixels: Int) -> CGImage? {
        guard let url = file(for: photo), let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Its date says it was used: the least recently used go first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// The photograph's own picture, read from its file: a RAW's embedded preview only, never a development.
    static func read(_ photo: PhotoFile, maxPixels: Int = side) -> CGImage? {
        autoreleasepool {
            let url = photo.url.photoFile
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if !EditorModel.rawExtensions.contains(url.pathExtension.lowercased()) {
                options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
    }

    /// Keeps `image` as `photo`'s copy, written whole or not at all.
    static func store(_ image: CGImage, for photo: PhotoFile) {
        guard let url = file(for: photo) else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: temporary); return }
        if (try? FileManager.default.replaceItemAt(url, withItemAt: temporary)) == nil {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// Reads and keeps `photo`'s copy unless it's kept already. False if the file has no picture to give.
    @discardableResult
    static func extract(_ photo: PhotoFile) -> Bool {
        guard let url = file(for: photo) else { return false }
        if FileManager.default.fileExists(atPath: url.path) { return true }
        guard let image = read(photo) else { return false }
        store(image, for: photo)
        return true
    }

    /// Reads `photos`' copies, `width` at a time, off the main actor; `progress` gets how many are done. Stops when
    /// the task is cancelled.
    static func extract(_ photos: [PhotoFile], progress: @escaping @Sendable (Int) async -> Void) async {
        var seen = Set<URL>()
        let photos = photos.map(\.photo).filter { seen.insert($0.url).inserted }
        var next = 0, done = 0
        await withTaskGroup(of: Void.self) { group in
            func start() {
                guard next < photos.count, !Task.isCancelled else { return }
                let photo = photos[next]; next += 1
                group.addTask(priority: .utility) { _ = extract(photo) }
            }
            for _ in 0..<width { start() }
            while await group.next() != nil {
                done += 1
                await progress(done)
                start()
            }
        }
        prune()
    }

    /// Past `limit`, removes the least recently used copies.
    static func prune(limit: Int = limit) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.totalFileAllocatedSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
