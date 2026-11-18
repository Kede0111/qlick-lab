// Qlick Lab — GPL-3.0-only.
import AppKit
import XCTest
@testable import QlickLab

/// Qlick Lab: the photographs' own pictures kept on this Mac, read once.
final class EmbeddedThumbnailsTests: XCTestCase {
    private func fixture(in dir: URL, _ name: String, width: Int = 1200, height: Int = 800) throws -> URL {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
                                      hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24)!
        for i in 0..<(width * height * 3) { bitmap.bitmapData![i] = UInt8(i % 251) }
        let url = dir.appendingPathComponent(name)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testAPhotographsPictureIsKeptAndReadFromTheCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-embedded-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try (0..<6).map { PhotoFile(url: try fixture(in: dir, "p\($0).png")) }

        XCTAssertNil(EmbeddedThumbnails.cached(photos[0], maxPixels: 384), "nothing kept before it's read")
        let counted = Counter()
        await EmbeddedThumbnails.extract(photos + [photos[0]]) { await counted.set($0) }
        let finished = await counted.value
        XCTAssertEqual(finished, 6, "each photograph once")

        // The copy answers without the file: gone, its picture still shows, at the size asked.
        try FileManager.default.removeItem(at: photos[1].url)
        let small = try XCTUnwrap(EmbeddedThumbnails.cached(photos[1], maxPixels: 384))
        XCTAssertEqual(max(small.width, small.height), 384)
        let large = try XCTUnwrap(EmbeddedThumbnails.cached(photos[1], maxPixels: EmbeddedThumbnails.side))
        XCTAssertEqual(max(large.width, large.height), EmbeddedThumbnails.side)

        // A changed file isn't answered by its old copy.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: photos[2].url.path)
        // A new URL, as a new listing reads it: one already read keeps its values.
        XCTAssertNil(EmbeddedThumbnails.cached(PhotoFile(url: URL(fileURLWithPath: photos[2].url.path)), maxPixels: 384))
    }

    func testPastTheLimitTheLeastRecentlyUsedGo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-embedded-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try (0..<3).map { PhotoFile(url: try fixture(in: dir, "q\($0).png")) }
        for (index, photo) in photos.enumerated() {
            XCTAssertTrue(EmbeddedThumbnails.extract(photo))
            let copy = try XCTUnwrap(EmbeddedThumbnails.file(for: photo))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index) * 10 - 1000)], ofItemAtPath: copy.path)
        }
        let sizes = try photos.map { try XCTUnwrap(EmbeddedThumbnails.file(for: $0)).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0 }
        let others = try FileManager.default.contentsOfDirectory(at: EmbeddedThumbnails.directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            .filter { url in !photos.contains { EmbeddedThumbnails.file(for: $0)?.lastPathComponent == url.lastPathComponent } }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        EmbeddedThumbnails.prune(limit: others + sizes[1] + sizes[2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(EmbeddedThumbnails.file(for: photos[0])).path), "the oldest goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(EmbeddedThumbnails.file(for: photos[2])).path))
    }
}

private actor Counter {
    var value = 0
    func set(_ value: Int) { self.value = value }
}
