// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// Import from an iPhone's QLab folder ("iPhone · QLab").
@MainActor final class PhoneImportTests: XCTestCase {
    /// A transport that answers as an iPhone would, from memory.
    final class FakeTransport: PhoneTransport, @unchecked Sendable {
        var state: PhoneDevice.State = .ready
        var files: [PhoneFile] = []
        func watch(_ event: @escaping @Sendable (PhoneTransportEvent) -> Void) -> @Sendable () -> Void { {} }
        func probe(_ udid: String) async -> PhoneDevice { PhoneDevice(udid: udid, deviceID: 0, name: "Quentin’s iPhone", state: state) }
        func pair(_ udid: String) async -> PhoneDevice { await probe(udid) }
        func list(_ udid: String) async throws -> [PhoneFile] { files }
        func pull(_ udid: String, paths: [String], into folder: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> [String] { paths }
    }

    func testOnlyIPhonesOnTheCableAreOfferedAndLeaveWhenUnplugged() async throws {
        let fake = FakeTransport()
        let phones = PhoneImport(transport: fake, watch: false)
        phones.handle(.attached(udid: "A", deviceID: 3, usb: true))
        phones.handle(.attached(udid: "B", deviceID: 4, usb: false))
        XCTAssertEqual(phones.devices.map(\.udid), ["A"], "a phone over the network isn't offered")
        // Its name and state come from the probe.
        for _ in 0..<50 where phones.devices.first?.state != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(phones.devices.first?.title, "Quentin’s iPhone · QLab")
        phones.handle(.detached(deviceID: 3))
        XCTAssertTrue(phones.devices.isEmpty)
    }

    func testWhatToDoIsSaidPlainly() {
        var phone = PhoneDevice(udid: "A", deviceID: 1)
        phone.state = .locked
        XCTAssertEqual(phone.advice, "Unlock the iPhone, then click again.")
        phone.state = .untrusted
        XCTAssertTrue(phone.advice?.contains("Trust") == true)
        phone.state = .ready
        XCTAssertNil(phone.advice)
    }

    /// The photographs, each with its `.qsidecar` (or its former `.qlab.json` when it has none), and the recipes.
    func testTheFilesAnImportTakes() {
        let files = [
            "2026-11-15/QLB_0130.DNG", "2026-11-15/QLB_0130.DNG.qsidecar", "2026-11-15/QLB_0130.DNG.qlab.json",
            "2026-11-12/QLB_0058.DNG", "2026-11-12/QLB_0058.DNG.qlab.json",
            "2026-11-12/QLB_0059.DNG",
            "Recipes/Portra.qrecipe", "Recipes/notes.txt", "Diagnostics/x.json",
        ].map { PhoneFile(path: $0, size: 10, modified: nil) }
        let (photos, companions, recipes) = PhoneImport.wanted(files)
        XCTAssertEqual(photos.map(\.path), ["2026-11-15/QLB_0130.DNG", "2026-11-12/QLB_0058.DNG", "2026-11-12/QLB_0059.DNG"])
        XCTAssertEqual(companions.map(\.path), ["2026-11-15/QLB_0130.DNG.qsidecar", "2026-11-12/QLB_0058.DNG.qlab.json"])
        XCTAssertEqual(recipes.map(\.path), ["Recipes/Portra.qrecipe"])
    }

    /// A recipe from the iPhone never writes over the lab's: same revision, nothing; changed, both are kept.
    func testRecipesFromTheIPhoneNeverReplaceTheLabs() {
        let local: [String: [String: Any]] = ["ID1": ["id": "ID1", "revision": "sha256:a"]]
        XCTAssertEqual(PhoneRecipeDecision.decide(remote: ["id": "ID2", "revision": "sha256:b", "name": "Gold"], local: local, taken: []), .add)
        XCTAssertEqual(PhoneRecipeDecision.decide(remote: ["id": "ID1", "revision": "sha256:a", "name": "Portra"], local: local, taken: []), .same)
        XCTAssertEqual(PhoneRecipeDecision.decide(remote: ["id": "ID1", "revision": "sha256:c", "name": "Portra"], local: local,
                                                  taken: [PresetName.key("Portra (iPhone)")]), .keepBoth(name: "Portra (iPhone) 2"))
        XCTAssertEqual(PhoneRecipeDecision.decide(remote: ["name": "No id"], local: local, taken: []), .add)
    }

    /// A photograph's development travels with it into the Archive: its `.qsidecar`, else its former `.qlab.json`;
    /// a sidecar already beside the copy stays.
    func testTheSidecarIsCopiedBesideThePhotograph() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-phone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("in"), out = dir.appendingPathComponent("out")
        for folder in [source, out] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let a = source.appendingPathComponent("A.DNG"), b = source.appendingPathComponent("B.DNG"), c = source.appendingPathComponent("C.DNG")
        for photo in [a, b, c] { try Data("raw".utf8).write(to: photo) }
        try Data(#"{"qsidecar": 1}"#.utf8).write(to: URL(fileURLWithPath: a.path + ".qsidecar"))
        try Data(#"{"qsidecar": 1, "x": 1}"#.utf8).write(to: URL(fileURLWithPath: a.path + ".qlab.json"))
        try Data(#"{"format": "qlab-sidecar"}"#.utf8).write(to: URL(fileURLWithPath: b.path + ".qlab.json"))
        let a2 = out.appendingPathComponent("A.DNG"), b2 = out.appendingPathComponent("B.DNG"), c2 = out.appendingPathComponent("C.DNG")
        ImportRunner.copyCompanion(of: a, beside: a2, verify: true)
        ImportRunner.copyCompanion(of: b, beside: b2, verify: true)
        ImportRunner.copyCompanion(of: c, beside: c2, verify: true)
        XCTAssertEqual(try String(contentsOfFile: a2.path + ".qsidecar", encoding: .utf8), #"{"qsidecar": 1}"#)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a2.path + ".qlab.json"), "the .qsidecar is enough")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b2.path + ".qlab.json"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasPrefix("C") }, [])
        // Never over one there.
        try Data("mine".utf8).write(to: URL(fileURLWithPath: a2.path + ".qsidecar"))
        ImportRunner.copyCompanion(of: a, beside: a2, verify: true)
        XCTAssertEqual(try String(contentsOfFile: a2.path + ".qsidecar", encoding: .utf8), "mine")
    }

    /// Writing to a helper that has ended is an error to handle, not SIGPIPE ending the lab (seen on CI: "signal 13").
    func testWritingToAnEndedHelperIsAnErrorNotACrash() throws {
        _ = BrokenPipes.ignored
        let process = Process(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true", isDirectory: false)
        process.standardInput = stdin
        try process.run()
        process.waitUntilExit()
        XCTAssertThrowsError(try {
            for _ in 0..<64 { try stdin.fileHandleForWriting.write(contentsOf: Data(repeating: 0x41, count: 65_536)) }
        }())
    }

    func testTransitIsPerIPhoneInTheCaches() {
        let folder = PhoneImport.transit(for: "00008150-000854312244401C")
        XCTAssertTrue(folder.path.contains("/Caches/"))
        XCTAssertEqual(folder.lastPathComponent, "00008150-000854312244401C")
    }
}
