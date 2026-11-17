// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// The import's core, without its room: where files go, how they're copied, and what survives an interruption.
final class ImportPlanTests: XCTestCase {
    private func file(_ path: String, size: Int = 100) -> ImportFile { ImportFile(url: URL(fileURLWithPath: path), size: size, modified: nil) }
    private func frame(_ path: String, _ exif: String?, size: Int = 100) -> ImportFrame {
        ImportFrame(file: file(path, size: size), captured: exif.flatMap(CaptureTime.init(exif:)))
    }
    private let empty = ImportPlan.World(size: { _ in nil }, folderExists: { _ in false }, imported: { _, _ in nil })
    private var options: ImportOptions {
        var options = ImportOptions()
        options.destination = URL(fileURLWithPath: "/dest", isDirectory: true)
        return options
    }

    func testCaptureTimeIsAWallClock() {
        let time = CaptureTime(exif: "2026:09:19 23:50:07")
        XCTAssertEqual(time, CaptureTime(year: 2026, month: 9, day: 19, hour: 23, minute: 50, second: 7))
        XCTAssertNil(CaptureTime(exif: "0000:00:00 00:00:00"))
        XCTAssertNil(CaptureTime(exif: "nonsense"))
        // A clock nine hours behind: the frame belongs to the next day.
        XCTAssertEqual(time?.shifted(minutes: 9 * 60), CaptureTime(year: 2026, month: 9, day: 20, hour: 8, minute: 50, second: 7))
        // A day that starts at four: half past two belongs to the evening before; the month's first to the month before.
        XCTAssertEqual(CaptureTime(exif: "2026:10:01 02:30:00")?.filingDay(startingAt: 4).day, 30)
        XCTAssertEqual(CaptureTime(exif: "2026:10:01 02:30:00")?.filingDay(startingAt: 4).month, 9)
        XCTAssertEqual(CaptureTime(exif: "2026:10:01 05:00:00")?.filingDay(startingAt: 4).day, 1)
    }

    func testTemplatesExpandAndRefuseWhatTheyDontKnow() {
        var values = ImportTemplate.Values(time: CaptureTime(exif: "2026:09:19 11:38:56"), name: "L1004394", sequence: 7, job: "Lisbon")
        XCTAssertEqual(ImportTemplate.expand("{yyyy}/{yyyy}-{mm}-{dd} {job}", values), "2026/2026-09-19 Lisbon")
        XCTAssertEqual(ImportTemplate.expand("{date}_{seq:4}", values), "20260919_0007")
        XCTAssertEqual(ImportTemplate.expand("{job}_{seq:3}-{time}", values), "Lisbon_007-113856")
        XCTAssertEqual(ImportTemplate.expand("{mm} {month}", values), "09 September")
        XCTAssertEqual(ImportTemplate.expand("{typo}-{name}", values), "{typo}-L1004394")
        XCTAssertNotNil(ImportTemplate.problem("{typo}", folders: true))
        XCTAssertNotNil(ImportTemplate.problem("{yyyy", folders: true))
        XCTAssertNotNil(ImportTemplate.problem("{date}/{seq}", folders: false))
        XCTAssertNil(ImportTemplate.problem("{yyyy}/{mm}/{dd}", folders: true))
        XCTAssertEqual(ImportTemplate.component("a/b:c  d."), "a-b-c d")
        XCTAssertEqual(ImportTemplate.component(" . "), "Untitled")
        values.time = nil
        XCTAssertEqual(ImportTemplate.folders("{yyyy}/{mm}", values), ["Undated"])
        XCTAssertEqual(ImportTemplate.folders("{job}", values), ["Lisbon"])
    }

    func testFramesPairARawWithItsJpeg() {
        let frames = ImportFrame.frames(from: [file("/c/L1.DNG"), file("/c/L1.JPG"), file("/c/L2.DNG"), file("/c/IMG.jpg"), file("/d/L2.JPG")])
        XCTAssertEqual(frames.map(\.file.name), ["IMG.jpg", "L1.DNG", "L2.DNG", "L2.JPG"])
        XCTAssertEqual(frames[1].companion?.name, "L1.JPG")
        // The same name in another folder is another photograph.
        XCTAssertNil(frames[2].companion)
    }

    func testBurstsAreRunsOfFramesSecondsApart() {
        let times = ["10:00:00", "10:00:01", "10:00:02", "10:00:30", "10:05:00", "10:05:02"].map { CaptureTime(exif: "2026:09:19 \($0)") }
        XCTAssertEqual(ImportBursts.groups(times, gap: 2), [0..<3, 4..<6])
        XCTAssertEqual(ImportBursts.groups([], gap: 2), [])
        XCTAssertEqual(ImportBursts.groups([times[0], nil, times[1]], gap: 2), [])
    }

    func testFramesGoToDatedFoldersUnderTheirOwnNames() {
        let plan = ImportPlan.make([frame("/card/L2.DNG", "2026:09:20 09:00:00", size: 30), frame("/card/L1.DNG", "2026:09:19 23:50:00", size: 20)],
                                   options: options, world: empty)
        XCTAssertEqual(plan.frames.map(\.files.first!.destination.path), ["/dest/2026/2026-09-19/L1.DNG", "/dest/2026/2026-09-20/L2.DNG"])
        XCTAssertEqual(plan.folders.map(\.path), ["2026/2026-09-19", "2026/2026-09-20"])
        XCTAssertEqual(plan.folders.map(\.count), [1, 1])
        XCTAssertEqual(plan.bytes, 50)
        XCTAssertTrue(plan.problems.isEmpty)
    }

    func testClockOffsetAndDayStartDecideTheFolder() {
        var options = options
        options.clockOffset = 9 * 60
        XCTAssertEqual(ImportPlan.make([frame("/card/L1.DNG", "2026:09:19 23:50:00")], options: options, world: empty).frames[0].folder, "2026/2026-09-20")
        options.clockOffset = 0; options.dayStart = 4
        XCTAssertEqual(ImportPlan.make([frame("/card/L1.DNG", "2026:09:20 02:10:00")], options: options, world: empty).frames[0].folder, "2026/2026-09-19")
    }

    func testAFrameWithoutAnyDateIsFiledApart() {
        let plan = ImportPlan.make([frame("/card/L1.DNG", nil)], options: options, world: empty)
        XCTAssertEqual(plan.frames[0].folder, "Undated")
    }

    func testRenamingNumbersInShootingOrderAndKeepsAPairTogether() {
        var options = options
        options.rename = "{job}_{seq:3}"; options.job = "Lisbon"; options.folders = ""
        var paired = frame("/card/B.DNG", "2026:09:19 10:00:00")
        paired.companion = file("/card/B.JPG")
        let plan = ImportPlan.make([frame("/card/A.DNG", "2026:09:19 11:00:00"), paired], options: options, world: empty)
        XCTAssertEqual(plan.frames.map { $0.files.map(\.destination.lastPathComponent) }, [["Lisbon_001.DNG", "Lisbon_001.JPG"], ["Lisbon_002.DNG"]])
        options.pairs = .rawOnly
        XCTAssertEqual(ImportPlan.make([paired], options: options, world: empty).frames[0].files.count, 1)
    }

    func testNothingIsEverPlannedOverAnotherFile() {
        // Two cards with the same file name, and a file of that name already at the destination.
        var world = empty
        world.size = { $0.path == "/dest/2026/2026-09-19/L1.DNG" ? 999 : nil }
        let plan = ImportPlan.make([frame("/a/L1.DNG", "2026:09:19 10:00:00", size: 10), frame("/b/L1.DNG", "2026:09:19 10:00:01", size: 11)],
                                   options: options, world: world)
        XCTAssertEqual(plan.frames.map(\.files.first!.destination.lastPathComponent), ["L1-2.DNG", "L1-3.DNG"])
        XCTAssertTrue(plan.frames.allSatisfy(\.renamed))
    }

    func testAFileAlreadyThereOrAlreadyImportedIsNotCopiedAgain() {
        var world = empty
        world.size = { $0.path == "/dest/2026/2026-09-19/L1.DNG" ? 10 : nil }
        world.imported = { file, _ in file.name == "L2.DNG" ? "/elsewhere/L2.DNG" : nil }
        let frames = [frame("/a/L1.DNG", "2026:09:19 10:00:00", size: 10), frame("/a/L2.DNG", "2026:09:19 10:00:01"), frame("/a/L3.DNG", "2026:09:19 10:00:02")]
        let plan = ImportPlan.make(frames, options: options, world: world)
        XCTAssertEqual(plan.frames.map(\.status), [.present, .duplicate, .new])
        XCTAssertEqual(plan.toCopy.map(\.id.lastPathComponent), ["L3.DNG"])
        XCTAssertEqual(plan.duplicates, 2)
        var options = options
        options.skipDuplicates = false
        XCTAssertEqual(ImportPlan.make(frames, options: options, world: world).frames.map(\.status), [.present, .new, .new])
    }

    func testAddInPlaceMovesNothing() {
        var options = options
        options.mode = .add
        let plan = ImportPlan.make([frame("/photos/roll/L1.DNG", "2026:09:19 10:00:00")], options: options, world: empty)
        XCTAssertEqual(plan.frames[0].files[0].destination.path, "/photos/roll/L1.DNG")
        XCTAssertEqual(plan.frames[0].folder, "/photos/roll")
    }

    func testASecondCopyKeepsTheCamerasNames() {
        var options = options
        options.secondCopy = URL(fileURLWithPath: "/backup", isDirectory: true); options.rename = "{date}_{seq:4}"
        let plan = ImportPlan.make([frame("/card/L1.DNG", "2026:09:19 10:00:00")], options: options, world: empty)
        XCTAssertEqual(plan.frames[0].files[0].destination.path, "/dest/2026/2026-09-19/20260919_0001.DNG")
        XCTAssertEqual(plan.frames[0].files[0].backup?.path, "/backup/2026/2026-09-19/L1.DNG")
    }

    func testWithoutADestinationThePlanSaysSo() {
        XCTAssertFalse(ImportPlan.make([frame("/card/L1.DNG", nil)], options: ImportOptions(), world: empty).problems.isEmpty)
    }
}

final class ImportCopyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("card"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ name: String, bytes: Int, seed: UInt8 = 1) throws -> URL {
        let url = root.appendingPathComponent("card").appendingPathComponent(name)
        var data = Data(count: bytes)
        for index in 0..<bytes { data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(seed)) }
        try data.write(to: url)
        return url
    }
    private func visible(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }
    private func all(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    func testACopyIsTheSameBytesAndTheSourceIsUntouched() throws {
        let source = try write("L1.DNG", bytes: 9_000_000)
        let before = try Data(contentsOf: source)
        let destination = root.appendingPathComponent("dest/2026/L1.DNG")
        var progressed = 0
        let result = try ImportCopier.copy(source, to: destination, progress: { progressed += $0 })
        XCTAssertEqual(result.outcome, .copied(destination))
        XCTAssertEqual(progressed, 9_000_000)
        XCTAssertEqual(try Data(contentsOf: destination), before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(result.hash, try ImportCopier.hash(of: source))
        // Nothing half-written is left, and the file keeps the camera's date.
        XCTAssertEqual(all(destination.deletingLastPathComponent()), ["L1.DNG"])
        let dates = try [source, destination].map { try XCTUnwrap(try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        XCTAssertEqual(dates[0].timeIntervalSince1970, dates[1].timeIntervalSince1970, accuracy: 0.001)
    }

    func testATakenNameIsNeverWrittenOver() throws {
        let source = try write("L1.DNG", bytes: 5000)
        let destination = root.appendingPathComponent("dest/L1.DNG")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = Data("another photograph".utf8)
        try other.write(to: destination)
        let result = try ImportCopier.copy(source, to: destination)
        XCTAssertEqual(result.outcome, .copied(root.appendingPathComponent("dest/L1-2.DNG")))
        XCTAssertEqual(try Data(contentsOf: destination), other)
        // The same bytes under the same name: nothing is written.
        XCTAssertEqual(try ImportCopier.copy(source, to: root.appendingPathComponent("dest/L1-2.DNG")).outcome, .alreadyThere(root.appendingPathComponent("dest/L1-2.DNG")))
        XCTAssertEqual(visible(destination.deletingLastPathComponent()), ["L1-2.DNG", "L1.DNG"])
    }

    func testAStoppedCopyLeavesNothing() throws {
        let source = try write("L1.DNG", bytes: 20_000_000)
        let destination = root.appendingPathComponent("dest/L1.DNG")
        var chunks = 0
        XCTAssertThrowsError(try ImportCopier.copy(source, to: destination, progress: { _ in chunks += 1 }, cancelled: { chunks >= 2 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(all(destination.deletingLastPathComponent()), [])
    }

    func testAMissingSourceFailsWithoutLeavingAFile() throws {
        let destination = root.appendingPathComponent("dest/L1.DNG")
        XCTAssertThrowsError(try ImportCopier.copy(root.appendingPathComponent("card/none.DNG"), to: destination))
        XCTAssertEqual(all(destination.deletingLastPathComponent()), [])
    }

    func testASecondCopyMustReadAsTheFirstDid() throws {
        let source = try write("L1.DNG", bytes: 5000)
        XCTAssertThrowsError(try ImportCopier.copy(source, to: root.appendingPathComponent("backup/L1.DNG"), knownHash: "not its hash"))
        XCTAssertEqual(all(root.appendingPathComponent("backup")), [])
    }

    func testLeftoverPartsAreRemoved() throws {
        let folder = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: folder.appendingPathComponent(".L1.DNG.ab12cd34.qnpart"))
        try Data("whole".utf8).write(to: folder.appendingPathComponent("L0.DNG"))
        ImportCopier.removeParts(in: folder)
        XCTAssertEqual(all(folder), ["L0.DNG"])
    }

    // MARK: A whole run

    private func journal(_ count: Int, options change: (inout ImportOptions) -> Void = { _ in }) throws -> ImportJournal {
        var options = ImportOptions()
        options.destination = root.appendingPathComponent("dest", isDirectory: true)
        options.folders = "{yyyy}-{mm}-{dd}"
        change(&options)
        var frames: [ImportFrame] = [], times: [URL: CaptureTime] = [:]
        for index in 0..<count {
            let url = try write(String(format: "L%03d.DNG", index), bytes: 300_000 + index, seed: UInt8(index))
            let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            let time = CaptureTime(exif: String(format: "2026:09:19 10:00:%02d", index))
            frames.append(ImportFrame(file: ImportFile(url: url, size: size, modified: nil), captured: time))
            times[url] = time
        }
        let plan = ImportPlan.make(frames, options: options)
        return ImportJournal(plan: plan, options: options, marks: [:], times: times, volume: nil, sourceName: "card", sourceRoot: root.appendingPathComponent("card"))
    }

    func testARunCopiesEverythingAndRemembersIt() throws {
        let ledger = ImportLedger(url: root.appendingPathComponent("ledger.jsonl"))
        let journalURL = root.appendingPathComponent("journal.json")
        let start = try journal(6) { $0.secondCopy = self.root.appendingPathComponent("backup", isDirectory: true) }
        let end = ImportRunner().run(start, journalURL: journalURL, ledger: ledger) { _ in }
        XCTAssertEqual(end.remaining, 0)
        XCTAssertTrue(end.items.allSatisfy(\.done))
        XCTAssertEqual(visible(root.appendingPathComponent("dest/2026-09-19")).count, 6)
        XCTAssertEqual(visible(root.appendingPathComponent("backup/2026-09-19")).count, 6)
        XCTAssertEqual(visible(root.appendingPathComponent("card")).count, 6)
        XCTAssertEqual(ImportJournal.read(from: journalURL), end)
        // The ledger knows them again, from a fresh read of its file.
        let again = ImportLedger(url: ledger.url)
        XCTAssertEqual(again.count, 6)
        let first = start.items[0]
        XCTAssertNotNil(again.imported(first.files[0].planned.source, captured: first.captured))
        XCTAssertTrue(end.report(folder: "2026-09-19").contains("L000.DNG"))
    }

    func testAStoppedRunResumesWithoutCopyingTwice() throws {
        let journalURL = root.appendingPathComponent("journal.json")
        let start = try journal(8)
        let runner = ImportRunner()
        let settled = Counter()
        let stopped = runner.run(start, journalURL: journalURL, ledger: nil) { event in
            if case .settled = event, settled.increment() == 3 { runner.cancel() }
        }
        XCTAssertEqual(stopped.items.filter(\.done).count, 3)
        XCTAssertEqual(stopped.remaining, 5)
        // Nothing half-written, and what the journal says is what's on disk.
        let folder = root.appendingPathComponent("dest/2026-09-19")
        XCTAssertEqual(all(folder).count, 3)
        let kept = try XCTUnwrap(ImportJournal.read(from: journalURL))
        XCTAssertEqual(kept, stopped)
        let dates = try all(folder).map { try folder.appendingPathComponent($0).resourceValues(forKeys: [.creationDateKey]).creationDate }
        let end = ImportRunner().run(kept, journalURL: journalURL, ledger: nil) { _ in }
        XCTAssertEqual(end.remaining, 0)
        XCTAssertEqual(all(folder).count, 8)
        // The first three weren't written again.
        for (index, name) in all(folder).prefix(3).enumerated() {
            XCTAssertEqual(try folder.appendingPathComponent(name).resourceValues(forKeys: [.creationDateKey]).creationDate, dates[index])
        }
    }

    func testAnUnreadableFileFailsAloneAndTheRestIsCopied() throws {
        var start = try journal(3)
        try FileManager.default.removeItem(at: start.items[1].files[0].planned.source.url)
        start.sourceRoot = nil
        let end = ImportRunner().run(start, journalURL: nil, ledger: nil) { _ in }
        XCTAssertEqual(end.items.map(\.done), [true, false, true])
        XCTAssertEqual(end.failures.count, 1)
        XCTAssertEqual(end.remaining, 0)
    }

    func testMoveTrashesTheSourceOnlyOnceItsCopyIsChecked() throws {
        let start = try journal(2) { $0.mode = .move }
        let end = ImportRunner().run(start, journalURL: nil, ledger: nil) { _ in }
        XCTAssertTrue(end.items.allSatisfy(\.done))
        XCTAssertEqual(visible(root.appendingPathComponent("card")), [])
        XCTAssertEqual(visible(root.appendingPathComponent("dest/2026-09-19")).count, 2)
    }
}

final class ImportWordsTests: XCTestCase {
    func testKeywordsAndCopyrightGoToAStandardSidecarNeverOverOne() throws {
        var options = ImportOptions()
        XCTAssertTrue(ImportMetadata(options: options).isEmpty)
        options.keywords = "lisbon, street; colour & light"; options.copyright = "© 2026 <Me>"; options.creator = "Me"
        let metadata = ImportMetadata(options: options)
        XCTAssertEqual(metadata.keywords, ["lisbon", "street", "colour & light"])
        // Well-formed XML, with what other programs look for.
        let document = try XMLDocument(xmlString: metadata.packet)
        let text = document.xmlString
        XCTAssertTrue(text.contains("<rdf:li>colour &amp; light</rdf:li>"))
        XCTAssertTrue(text.contains("© 2026 &lt;Me&gt;"))
        XCTAssertTrue(text.contains("dc:creator"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-words-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("L1.DNG")
        XCTAssertTrue(metadata.write(beside: photo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("L1.xmp").path))
        // One that's already there is left as it is.
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("L2.xmp"))
        XCTAssertFalse(metadata.write(beside: folder.appendingPathComponent("L2.DNG")))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("L2.xmp"), encoding: .utf8), "theirs")
    }

    func testDurationsReadAsWords() {
        XCTAssertEqual(ImportRun.duration(0.2), "1 s")
        XCTAssertEqual(ImportRun.duration(59), "59 s")
        XCTAssertEqual(ImportRun.duration(185), "3 min")
        XCTAssertEqual(ImportRun.duration(3725), "1 h 2 min")
    }

    func testImportIsARoomWithItsOwnKeyAndTheOthersKeepTheirs() {
        XCTAssertEqual(Workspace.ordered.first, .importer)
        XCTAssertEqual(Set(Workspace.ordered), Set(Workspace.allCases))
        XCTAssertEqual(Workspace.importer.key, "0")
        XCTAssertEqual([Workspace.library, .contactSheet, .develop, .compare, .recipes, .films, .papers].map(\.key), ["1", "2", "3", "4", "5", "6", "7"])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
