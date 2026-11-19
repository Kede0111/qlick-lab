import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import QlickLab

/// The app and the engine's helper name the same commands: `EngineCommand` against
/// crates/spektrafilm-native/commands.txt, which the helper's own test reads too.
final class EngineContractTests: XCTestCase {
    func testCommandsMatchTheSharedList() throws {
        let list = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("crates/spektrafilm-native/commands.txt")
        let names = try String(contentsOf: list, encoding: .utf8).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(EngineCommand.allCases.map(\.rawValue), names)
    }

    /// A typed reply reads a missing key as the lab always has; decoded strictly, it's an error.
    func testRepliesReadLenientlyAndDecodeStrictly() throws {
        let partial: JSONValue = .object(["width": .number(4), "region": .array([.number(1), .number(2), .number(3), .number(4)])])
        let reply = RenderReply(partial)
        XCTAssertEqual(reply.width, 4)
        XCTAssertEqual(reply.height, 0)
        XCTAssertEqual(reply.region, [1, 2, 3, 4])
        XCTAssertEqual(reply.backend, "")
        XCTAssertEqual(reply.filmHistogram, .null)
        XCTAssertThrowsError(try JSONDecoder().decode(RenderReply.self, from: JSONEncoder().encode(partial)))
        XCTAssertThrowsError(try JSONDecoder().decode(ThumbnailReply.self, from: Data(#"{"source_width": "wide", "source_height": 2}"#.utf8)))
        let decoded = try JSONDecoder().decode(ThumbnailReply.self, from: Data(#"{"source_width": 3, "source_height": 2}"#.utf8))
        XCTAssertEqual(decoded.sourceSize, CGSize(width: 3, height: 2))
    }

    /// The real helper's render and thumbnail replies have every key the lab reads, with its type.
    func testTheHelpersRepliesDecode() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent("target/release/spektrafilm-native")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Build spektrafilm-native in release mode before the integration test")
        }
        let client = try EngineClient(paths: EnginePaths(helper: helper, exporter: root.appendingPathComponent("target/release/spektrafilm-f64"), data: root.appendingPathComponent("data")))
        defer { client.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-replies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appendingPathComponent("photo.png")
        let (width, height) = (64, 48)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = UInt8(i % 251); pixels[i + 1] = 128; pixels[i + 2] = UInt8((i / 4) % 200) }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let (_, catalog) = try await client.request(["command": EngineCommand.catalog.json])
        let common: [String: JSONValue] = [
            "input": .string(photo.path), "source_generation": .number(1), "film": .string("kodak_portra_400"),
            "paper": .string("kodak_portra_endura"), "params": catalog["defaults"],
        ]
        func decode<Reply: EngineReply>(_ type: Reply.Type, _ command: EngineCommand, _ extra: [String: JSONValue]) async throws -> Reply {
            let (_, result) = try await client.request(common.merging(extra) { $1 }.merging(["command": command.json]) { $1 })
            return try JSONDecoder().decode(Reply.self, from: JSONEncoder().encode(result))
        }
        let render = try await decode(RenderReply.self, .render, [
            "limit_preview": .bool(false), "preview_path": .string(directory.appendingPathComponent("render.rgba").path),
        ])
        XCTAssertEqual(render.sourceWidth, Double(width))
        XCTAssertGreaterThan(render.width, 0)
        XCTAssertNotEqual(render.filmHistogram, .null)
        let thumbnail = try await decode(ThumbnailReply.self, .thumbnail, [
            "long_side": .number(32), "preview_path": .string(directory.appendingPathComponent("thumbnail.rgba").path),
        ])
        XCTAssertEqual(thumbnail.sourceSize, CGSize(width: width, height: height))
        XCTAssertGreaterThan(thumbnail.width, 0)
        XCTAssertFalse(thumbnail.displayColorSpace.isEmpty)
        let decoded = try await decode(ThumbnailReply.self, .thumbnail, [
            "long_side": .number(16), "preview_path": .string(directory.appendingPathComponent("decode.rgba").path),
            "decode_only": .bool(true), "preview_colour_space": .bool(true),
        ])
        XCTAssertEqual(decoded.sourceSize, CGSize(width: width, height: height))
        XCTAssertFalse(decoded.raw)
    }
}
