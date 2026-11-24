import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import QlickLab

/// What an export file is: each format's own quality, its estimated weight, the lab's XMP inside it, the finishing
/// step's lossless files.
final class ExportFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-exportfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func image(bits: Int = 16, width: Int = 64, height: Int = 48) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let info = bits == 16 ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info))
        for y in 0..<height { for x in 0..<width {
            context.setFillColor(CGColor(colorSpace: space, components: [CGFloat(x) / CGFloat(width), CGFloat(y) / CGFloat(height), CGFloat((x * y) % 97) / 97, 1])!)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage, as type: UTType, to url: URL, properties: [CFString: Any] = [:]) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func decoded(_ url: URL) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try XCTUnwrap(image.dataProvider?.data as Data?)
    }

    // MARK: Qualities

    func testHEIFHasItsOwnQualityThatStopsAt95() {
        let save = SaveSettings(jpegQuality: 100, heifQuality: 90)
        XCTAssertEqual(save.quality(of: .jpeg), 100)
        XCTAssertEqual(save.quality(of: .heif), 90)
        XCTAssertNil(save.quality(of: .tiff))
        XCTAssertEqual(SaveSettings.heifQualityRange.upperBound, 95)
        XCTAssertEqual(SaveSettings.heifQualities.max(), 95)
        XCTAssertEqual(SaveSettings().jpegQuality, 92)
        XCTAssertEqual(SaveSettings().heifQuality, 90)
        XCTAssertEqual(SaveSettings().ppi, 300)
    }

    func testSaveOptionsCarryResolutionAndTheLabsName() {
        let save = SaveSettings(ppi: 240)
        let json = save.json
        XCTAssertEqual(json["ppi"].double, 240)
        XCTAssertTrue(json["software"].string.hasPrefix("Qlick Lab "))
        XCTAssertTrue(save.arguments.contains("--ppi") && save.arguments.contains("240"))
        XCTAssertTrue(save.arguments.contains("--software"))
    }

    func testSaveSettingsRoundTripThroughABatchJournal() throws {
        var options = BatchOptions()
        options.saveSettings = SaveSettings(bitDepth: 8, colorSpace: 1, jpegQuality: 88, heifQuality: 85, ppi: 360, sharpening: .matte,
                                            sharpeningAmount: .high, metadata: .noLocation)
        let decoded = try JSONDecoder().decode(BatchOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(decoded.save, options.saveSettings)
        // A journal from before keeps its fields.
        let old = try JSONDecoder().decode(BatchOptions.self, from: Data(#"{"format":"jpeg","engine":"fast","edge":"full","pixels":2048,"colorSpace":0,"jpegQuality":80,"naming":"name","custom":"","existing":"skip","lowMemory":false}"#.utf8))
        XCTAssertEqual(old.save.jpegQuality, 80)
        XCTAssertEqual(old.save.sharpening, .none)
    }

    // MARK: Estimate

    func testEstimateFollowsQualityPixelsAndSharpening() {
        let pixels = CGSize(width: 9528, height: 6328)
        let jpeg92 = ExportEstimate.table(.jpeg, SaveSettings(jpegQuality: 92))
        XCTAssertEqual(jpeg92, 0.375, accuracy: 1e-9)
        XCTAssertEqual(ExportEstimate.interpolate(ExportEstimate.jpeg, 93), 0.375 + (0.53 - 0.375) / 3, accuracy: 1e-9)
        XCTAssertEqual(ExportEstimate.interpolate(ExportEstimate.heif, 100), 2.33)
        XCTAssertLessThan(ExportEstimate.table(.heif, SaveSettings(heifQuality: 85)), ExportEstimate.table(.heif, SaveSettings(heifQuality: 90)))
        let plain = SaveSettings(heifQuality: 90), sharp = SaveSettings(heifQuality: 90, sharpening: .glossy)
        XCTAssertGreaterThan(ExportEstimate.sharpeningFactor(sharp), ExportEstimate.sharpeningFactor(plain))
        XCTAssertNil(ExportEstimate.bytes(format: .jpeg, save: SaveSettings(), pixels: .zero))
        XCTAssertNotNil(ExportEstimate.bytes(format: .tiff, save: SaveSettings(bitDepth: 8), pixels: pixels))
        XCTAssertEqual(ExportEstimate.format(38_000_000), "38 MB")
        XCTAssertEqual(ExportEstimate.format(8_650_000), "8.7 MB")
        XCTAssertEqual(ExportEstimate.format(866_000), "866 KB")
        XCTAssertEqual(ExportSize(edge: .long, pixels: 2048).fitted(pixels), CGSize(width: 2048, height: 1360))
        XCTAssertEqual(ExportSize(edge: .long, pixels: 20_000).fitted(pixels), pixels, "Never enlarged")
    }

    // MARK: The lab's XMP

    func testLabXMPGoesInsideEveryFormatWithoutChangingPixels() throws {
        let photo = dir.appendingPathComponent("L1000001.DNG")
        try Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator><rdf:Seq><rdf:li>A. Photographer</rdf:li></rdf:Seq></dc:creator><dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© A. 2026</rdf:li></rdf:Alt></dc:rights></rdf:Description></rdf:RDF></x:xmpmeta>"#.utf8)
            .write(to: dir.appendingPathComponent("L1000001.xmp"))
        let xmp = LabXMP(film: "Kodak Portra 400", paper: "Kodak Portra Endura", recipe: "Golden <hour> & co", rating: 4,
                         keywords: ["Texas", "texas", "Trailer"], title: "Gol’ee’s", caption: "", photo: photo)
        let files: [(UTType, Int, String)] = [(.jpeg, 8, "jpg"), (.png, 8, "png"), (.png, 16, "png"), (.tiff, 16, "tif"), (.tiff, 8, "tif"), (.heic, 8, "heic")]
        for (type, bits, ext) in files {
            let source = dir.appendingPathComponent("source-\(bits).\(ext)"), output = dir.appendingPathComponent("out-\(bits).\(ext)")
            try write(try image(bits: bits), as: type, to: source)
            try LabXMP.write(source, to: output, xmp: xmp)
            let found = LabXMP.read(output)
            XCTAssertEqual(found["qlick:Film"], "Kodak Portra 400", "\(ext) \(bits)")
            XCTAssertEqual(found["qlick:Paper"], "Kodak Portra Endura", "\(ext) \(bits)")
            XCTAssertEqual(found["qlick:Recipe"], "Golden <hour> & co", "\(ext) \(bits)")
            XCTAssertEqual(found["xmp:Rating"], "4", "\(ext) \(bits)")
            XCTAssertTrue(found["xmp:CreatorTool"]?.hasPrefix("Qlick Lab") ?? false, "\(ext) \(bits)")
            XCTAssertEqual(found["dc:subject"], "Texas, Trailer", "\(ext) \(bits)")
            XCTAssertEqual(found["dc:creator"], "A. Photographer", "\(ext) \(bits)")
            XCTAssertNotNil(found["dc:rights"], "\(ext) \(bits)")
            XCTAssertEqual(try decoded(output), try decoded(source), "\(ext) \(bits): the image is copied as it is")
        }
        // Metadata › None: the lab's fields stay, the photographer's words go.
        var bare = xmp; bare.personal = false
        let source = dir.appendingPathComponent("source-16.tif"), output = dir.appendingPathComponent("bare.tif")
        try LabXMP.write(source, to: output, xmp: bare)
        let found = LabXMP.read(output)
        XCTAssertEqual(found["qlick:Film"], "Kodak Portra 400")
        XCTAssertNil(found["dc:creator"]); XCTAssertNil(found["dc:subject"])
        // No XMP: the file as it is.
        let copy = dir.appendingPathComponent("copy.tif")
        try LabXMP.write(source, to: copy, xmp: nil)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
    }

    // MARK: Finishing

    /// A TIFF that is sharpened is written again by the finishing step: three samples, compressed, the resolution
    /// kept; and placed onto the destination with the lab's XMP, nothing left beside it.
    func testFinishedTIFFIsCompressedOpaqueAndPlaced() throws {
        let written = dir.appendingPathComponent("engine.tif")
        try write(try image(bits: 8, width: 300, height: 200), as: .tiff, to: written,
                  properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFXResolution: 300, kCGImagePropertyTIFFYResolution: 300,
                                                                kCGImagePropertyTIFFResolutionUnit: 2]])
        let destination = dir.appendingPathComponent("print.tif")
        let save = SaveSettings(bitDepth: 8, sharpening: .glossy)
        XCTAssertTrue(ExportFinisher.needed(save, destination: destination))
        try ExportFinisher.deliver(written, to: destination, save: save, xmp: LabXMP(film: "Kodak Gold 200"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCompression] as? Int, 8)
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double, 300)
        XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool ?? false, false)
        XCTAssertEqual(LabXMP.read(destination)["qlick:Film"], "Kodak Gold 200")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".qlick") }
        XCTAssertEqual(left, [], "No hidden file left beside the destination")
    }

    func testHEIFUsesItsOwnQuality() throws {
        let written = dir.appendingPathComponent("engine.tif")
        try write(try image(bits: 16, width: 400, height: 300), as: .tiff, to: written)
        var sizes: [Int: Int] = [:]
        for quality in [60, 95] {
            let destination = dir.appendingPathComponent("scan-\(quality).heic")
            try ExportFinisher.deliver(written, to: destination, save: SaveSettings(jpegQuality: 100, heifQuality: quality), xmp: nil)
            sizes[quality] = try XCTUnwrap(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }
        XCTAssertLessThan(sizes[60]!, sizes[95]!, "HEIF follows its own quality, not the JPEG's 100")
    }
}
