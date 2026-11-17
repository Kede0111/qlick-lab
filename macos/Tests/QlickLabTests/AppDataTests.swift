import AppKit
import XCTest
@testable import QlickLab

@MainActor final class AppDataLifecycleTests: XCTestCase {
    func testShutdownDuringStartupPreventsRestorationAndSessionRecreation() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = EnginePaths(helper: root.appendingPathComponent("target/release/spektrafilm-native"),
                                exporter: root.appendingPathComponent("target/release/spektrafilm-f64"), data: root.appendingPathComponent("data"))
        guard FileManager.default.isExecutableFile(atPath: paths.helper.path) else { throw XCTSkip("Build the release helper first") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("photo.png")
        try Data("photograph".utf8).write(to: photo)
        let cache = RenderedPreviewCache(file: dir.appendingPathComponent("cache/preview"))
        let model = EditorModel(previewCache: cache)
        defer { model.shutdown() }
        let restoration = Task<EditorSession?, Error> {
            try await Task.sleep(for: .milliseconds(200))
            return EditorSession(source: photo, state: EditState())
        }
        let startup = Task { await model.start(paths: paths, restoration: restoration) }
        try await Task.sleep(for: .milliseconds(100))
        model.shutdown()
        await model.flushPreviewCache()
        await startup.value
        model.open(photo)
        XCTAssertNil(model.source)
        XCTAssertNil(model.session, "Normal termination must not re-save the discarded session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.file.path))
        XCTAssertEqual(try Data(contentsOf: photo), Data("photograph".utf8))
    }
}
