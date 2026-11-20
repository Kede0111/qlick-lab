import CoreGraphics
import IOSurface
import XCTest
@testable import QlickLab

final class RenderAheadTests: XCTestCase {
    func testNeighboursFollowTheDirectionOfTravel() {
        XCTAssertEqual(RenderAhead.neighbours(of: 5, count: 12, direction: 1), [6, 7, 4])
        XCTAssertEqual(RenderAhead.neighbours(of: 5, count: 12, direction: -1), [4, 3, 6])
        // At either end, only what's there.
        XCTAssertEqual(RenderAhead.neighbours(of: 11, count: 12, direction: 1), [10])
        XCTAssertEqual(RenderAhead.neighbours(of: 0, count: 1, direction: 1), [])
    }

    func testWalkOrderPutsWhatsAheadFirst() {
        let items = (0..<9).map { ($0, $0) }
        // No direction: nearest first, the one before on a tie.
        XCTAssertEqual(RenderAhead.walkOrder(items, from: 4, direction: nil), [4, 3, 5, 2, 6, 1, 7, 0, 8])
        // Forward: three ahead before the first behind (behind counts three times as far).
        XCTAssertEqual(Array(RenderAhead.walkOrder(items, from: 4, direction: 1).prefix(5)), [4, 5, 6, 3, 7])
        XCTAssertEqual(Array(RenderAhead.walkOrder(items, from: 4, direction: -1).prefix(5)), [4, 3, 2, 1, 5])
        XCTAssertEqual(EditorModel.outward(items, from: 4), [4, 3, 5, 2, 6, 1, 7, 0, 8], "Unchanged without a direction")
    }

    func testProxyOrderLeansAheadAndKeepsTheUnlisted() {
        let all = (0..<7).map { URL(fileURLWithPath: "/tmp/p\($0).dng") }
        XCTAssertEqual(ProxyMaker.order(all, around: all[3], in: all, direction: 1), [all[3], all[4], all[5], all[2], all[6], all[1], all[0]])
        let stranger = URL(fileURLWithPath: "/tmp/elsewhere.dng")
        XCTAssertEqual(ProxyMaker.order([stranger, all[4]], around: all[3], in: all, direction: -1), [all[4], stranger])
    }

    func testHoldsWhatsWantedAndLetsTheRestGo() throws {
        let ahead = RenderAhead(capacity: 2)
        let image = try XCTUnwrap(Self.image())
        let entry = RenderAhead.Entry(image: image, photoSize: CGSize(width: 40, height: 30))
        ahead.prefetch([("a", { entry }), ("b", { entry }), ("c", { nil })])
        ahead.settle()
        XCTAssertNotNil(ahead.take("a")); XCTAssertNotNil(ahead.take("b"))
        XCTAssertNil(ahead.take("c"), "No kept develop, nothing held")
        XCTAssertEqual(ahead.take("a")?.photoSize, CGSize(width: 40, height: 30))
        // A new walk: what's no longer wanted goes, the one kept stays.
        ahead.prefetch([("d", { entry })], keeping: ["a"])
        ahead.settle()
        XCTAssertNil(ahead.take("b"))
        XCTAssertNotNil(ahead.take("a")); XCTAssertNotNil(ahead.take("d"))
        // The photograph just left, held before its file is written; never more than the capacity.
        ahead.keep(image, photoSize: .init(width: 1, height: 1), as: "e")
        XCTAssertEqual(ahead.count, 2)
        XCTAssertNotNil(ahead.take("e"))
        XCTAssertGreaterThan(ahead.bytes, 0)
        ahead.removeAll()
        XCTAssertEqual(ahead.count, 0)
    }

    func testMachineStateSavesEnergyWhenHot() {
        XCTAssertFalse(MachineState(lowPower: false, thermal: .nominal).saving)
        XCTAssertFalse(MachineState(lowPower: false, thermal: .fair).saving)
        XCTAssertTrue(MachineState(lowPower: false, thermal: .serious).saving)
        XCTAssertTrue(MachineState(lowPower: true, thermal: .nominal).saving)
        XCTAssertEqual(ProxyMaker.helpers(cores: 16, memory: 64 << 30, lowPower: MachineState(lowPower: false, thermal: .critical).saving), 1)
    }

    /// The launch frame is written once the lab rests on it, or at quit, not for every frame settled.
    func testLaunchFrameIsWrittenOnceTheLabRests() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = RenderedPreviewCache(file: dir.appendingPathComponent("frame.cache"), writeDelay: 0.3)
        let surface = try EditorModel.previewSurface(Data(repeating: 128, count: 16), width: 2, height: 2)
        for index in 0..<5 {
            cache.save(surface, photoSize: CGSize(width: 2, height: 2), sourceSize: CGSize(width: 2, height: 2),
                       workingSize: CGSize(width: 2, height: 2), raw: false, key: "frame \(index)")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.file.path), "Still walking: nothing written yet")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.file.path))
        await cache.flush()
        XCTAssertEqual(cache.writes, 1, "Only the last frame is written")
        // An edit after it: the frame waiting is dropped, and the file goes.
        cache.save(surface, photoSize: CGSize(width: 2, height: 2), sourceSize: CGSize(width: 2, height: 2),
                   workingSize: CGSize(width: 2, height: 2), raw: false, key: "edited")
        cache.invalidate()
        await cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.file.path))
        XCTAssertEqual(cache.writes, 1)
    }

    private static func image() -> CGImage? {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        return context?.makeImage()
    }
}

final class EngineSettingsTests: XCTestCase {
    /// A setting the helpers read at launch (Make proxies) changes: the one running is replaced before its next request.
    func testHelpersStartAgainWhenTheirSettingsChange() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let helper = dir.appendingPathComponent("helper")
        try Data("""
        #!/usr/bin/python3
        import json, os, sys
        for line in sys.stdin:
            c = json.loads(line)
            print(json.dumps({'id': c['id'], 'result': {'pid': os.getpid()}}), flush=True)
        """.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let engine = try EngineClient(paths: EnginePaths(helper: helper, exporter: helper, data: dir))
        defer { engine.stop() }
        let first = try await engine.request(["command": .string("catalog")]).1["pid"].double
        let same = try await engine.request(["command": .string("catalog")]).1["pid"].double
        XCTAssertEqual(first, same)
        EngineClient.settingsChanged()
        let next = try await engine.request(["command": .string("catalog")]).1["pid"].double
        XCTAssertNotEqual(first, next, "Started again with the new settings")
        let after = try await engine.request(["command": .string("catalog")]).1["pid"].double
        XCTAssertEqual(next, after)
    }
}
