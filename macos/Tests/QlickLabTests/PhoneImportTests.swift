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
        var requests: [Data] = []
        func requestDelete(_ udid: String, request: Data) async throws { requests.append(request) }
    }

    /// The deletion request names only photographs whose copy was checked, by QLab's id and the copy's SHA-256.
    func testTheDeletionRequestNamesOnlyCheckedCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("2026-11-15"), withIntermediateDirectories: true)
        var frames: [ImportFrame] = [], times: [URL: CaptureTime] = [:]
        for (index, name) in ["QLB_0001.DNG", "QLB_0002.DNG", "QLB_0003.DNG"].enumerated() {
            let url = dir.appendingPathComponent("2026-11-15/\(name)")
            try Data(repeating: UInt8(index), count: 1000 + index).write(to: url)
            if index < 2 {
                let sidecar = #"{"qsidecar": 1, "qlab": {"record": {"id": "ID-\#(index)"}}, "variants": []}"#
                try Data(sidecar.utf8).write(to: URL(fileURLWithPath: url.path + ".qsidecar", isDirectory: false))
            }
            let time = CaptureTime(exif: "2026:11:15 10:00:0\(index)")
            frames.append(ImportFrame(file: ImportFile(url: url, size: 1000 + index, modified: nil), captured: time)); times[url] = time
        }
        var options = ImportOptions(); options.destination = dir.appendingPathComponent("out", isDirectory: true)
        var journal = ImportJournal(plan: ImportPlan.make(frames, options: options), options: options, marks: [:], times: times, volume: nil,
                                    sourceName: "iPhone", sourceRoot: dir)
        for i in journal.items.indices {
            journal.items[i].files[0].status = .done
            journal.items[i].files[0].hash = i == 1 ? nil : "ABC\(i)"
        }
        let data = try XCTUnwrap(PhoneImport.deleteRequest(journal, mac: "Studio"))
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(request["format"] as? Int, 1); XCTAssertEqual(request["mac"] as? String, "Studio")
        let photos = try XCTUnwrap(request["photos"] as? [[String: Any]])
        // QLB_0002: no checked hash; QLB_0003: no QLab sidecar.
        XCTAssertEqual(photos.map { $0["id"] as? String }, ["ID-0"])
        XCTAssertEqual(photos.first?["sha256"] as? String, "abc0")
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

    /// What the catalogue imported already doesn't come over again (its ledger: name and size, where it went still there).
    func testWhatWasImportedIsntCopiedAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copied = dir.appendingPathComponent("20261115_0001.DNG")
        try Data("raw".utf8).write(to: copied)
        let ledger = ImportLedger(url: dir.appendingPathComponent("import-ledger.jsonl"))
        let source = dir.appendingPathComponent("QLB_0130.DNG")
        ledger.record(ImportFile(url: source, size: 1000, modified: nil), captured: nil, hash: nil, destination: copied)
        XCTAssertTrue(ledger.knows(name: "qlb_0130.dng", size: 1000))
        XCTAssertFalse(ledger.knows(name: "QLB_0130.DNG", size: 999))
        let files = ["2026-11-15/QLB_0130.DNG", "2026-11-15/QLB_0130.DNG.qsidecar", "2026-11-15/QLB_0131.DNG"]
            .map { PhoneFile(path: $0, size: 1000, modified: nil) }
        let (photos, companions, _) = PhoneImport.wanted(files) { ledger.knows(name: $0, size: $1) }
        XCTAssertEqual(photos.map(\.path), ["2026-11-15/QLB_0131.DNG"])
        XCTAssertEqual(companions, [])
        // The copy gone from where it went: it's wanted again.
        try FileManager.default.removeItem(at: copied)
        XCTAssertFalse(ledger.knows(name: "QLB_0130.DNG", size: 1000))
    }

    func testTheTransitFolderIsEmptiedOnRequest() async throws {
        let udid = "TEST-\(UUID().uuidString)"
        let folder = PhoneImport.transit(for: udid)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("2026-11-15"), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: folder.appendingPathComponent("2026-11-15/QLB_0001.DNG"))
        PhoneImport(transport: FakeTransport(), watch: false).clearTransit(at: folder)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: folder.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// The transit folder chosen in Settings, or the caches' when none is chosen or its disk isn't there.
    func testTheTransitFolderCanBeChosen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-transit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chosen = PhoneImport.usableTransitRoot(chosen: dir)
        XCTAssertEqual(chosen.root, dir.appendingPathComponent("Qlick Lab iPhone Transit", isDirectory: true))
        XCTAssertNil(chosen.note)
        let gone = PhoneImport.usableTransitRoot(chosen: URL(fileURLWithPath: "/Volumes/No Such Disk \(UUID().uuidString)/Transit", isDirectory: true))
        XCTAssertEqual(gone.root, PhoneImport.defaultTransitRoot)
        XCTAssertTrue(gone.note?.contains("isn’t there") == true)
        XCTAssertEqual(PhoneImport.usableTransitRoot(chosen: nil).root, PhoneImport.defaultTransitRoot)
    }

    func testTransitIsPerIPhoneInTheCaches() {
        let folder = PhoneImport.transit(for: "00008150-000854312244401C")
        XCTAssertTrue(folder.path.contains("/Caches/"))
        XCTAssertEqual(folder.lastPathComponent, "00008150-000854312244401C")
    }
    /// The import's grid and loupe show what QLab developed: a frame whose `.qsidecar` holds a development, with the
    /// recipe its active version names.
    func testFramesDevelopedInQLabAreKnownBeforeTheImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-developed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func photo(_ name: String, sidecar: String?) throws -> URL {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            try Data([0]).write(to: url)
            if let sidecar { try Data(sidecar.utf8).write(to: dir.appendingPathComponent(name + ".qsidecar", isDirectory: false)) }
            return url
        }
        let withRecipe = try photo("QLB_0001.DNG", sidecar: """
            {"qsidecar": 1, "defaultsVersion": 1, "variants": [
              {"id": "a", "name": "Portra", "recipe": "Kodak Portra 400 (Quent)", "recipeRef": {"id": "403683E1"},
               "edits": {"film": "kodak_portra_400"}},
              {"id": "b", "name": "Trix", "recipe": "Trix", "edits": {"film": "kodak_trix400_d76_8min"}}]}
            """)
        let plain = try photo("QLB_0002.DNG", sidecar: """
            {"qsidecar": 1, "defaultsVersion": 1, "variants": [{"id": "a", "name": "Version 1", "recipe": "", "edits": {"film": "kodak_gold_200"}}]}
            """)
        let untouched = try photo("QLB_0003.DNG", sidecar: """
            {"qsidecar": 1, "defaultsVersion": 1, "variants": [{"id": "a", "rating": 3}]}
            """)
        let bare = try photo("QLB_0004.DNG", sidecar: nil)

        // The active version is the first: its recipe, not another version's.
        XCTAssertEqual(ImportDevelopment.read(photo: withRecipe), ImportDevelopment(recipe: "Kodak Portra 400 (Quent)", name: "Portra"))
        XCTAssertEqual(ImportDevelopment.read(photo: plain), ImportDevelopment(recipe: nil, name: "Version 1"))
        XCTAssertNil(ImportDevelopment.read(photo: untouched), "a rating alone isn't a development")
        XCTAssertNil(ImportDevelopment.read(photo: bare))
    }
}
