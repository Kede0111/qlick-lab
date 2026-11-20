// Qlick Lab — GPL-3.0-only.
import XCTest
@testable import QlickLab

/// The import's choices of 0.4: the structures and names offered, the tags a custom form inserts, the Archive and the
/// Box it goes to, the Folder card, and what the source holds twice or can't read.
final class ImportOptionsTests: XCTestCase {
    private func frame(_ path: String, _ exif: String?, size: Int = 100) -> ImportFrame {
        ImportFrame(file: ImportFile(url: URL(fileURLWithPath: path), size: size, modified: nil), captured: exif.flatMap(CaptureTime.init(exif:)))
    }

    func testStructuresAreTheFormsOffered() {
        let values = ImportTemplate.Values(time: CaptureTime(year: 2026, month: 9, day: 19, hour: 11), job: "Rue")
        XCTAssertEqual(ImportTemplate.folders(ImportStructure.byDay.template!, values), ["2026", "2026-09-19"])
        XCTAssertEqual(ImportTemplate.folders(ImportStructure.byMonth.template!, values), ["2026", "2026-09"])
        XCTAssertEqual(ImportTemplate.folders(ImportStructure.byYear.template!, values), ["2026"])
        XCTAssertEqual(ImportTemplate.folders(ImportStructure.byDayAndJob.template!, values), ["2026", "2026-09-19 Rue"])
        XCTAssertEqual(ImportStructure.oneFolder.template, "")
        XCTAssertNil(ImportStructure.custom.template)
        for structure in ImportStructure.allCases where structure != .custom {
            XCTAssertEqual(ImportStructure(template: structure.template!), structure)
        }
        XCTAssertEqual(ImportStructure(template: "{yyyy}/{month}"), .custom)
        XCTAssertEqual(ImportStructure(template: ImportTemplate.defaultFolders), .byDay, "the default is By Day")
    }

    func testFileNamesAreTheFormsOffered() {
        let values = ImportTemplate.Values(time: CaptureTime(year: 2026, month: 9, day: 19, hour: 11, minute: 38, second: 56), name: "L1004394", sequence: 1, job: "Rue")
        XCTAssertEqual(ImportTemplate.expand(ImportNaming.dateSequence.template!, values), "20260919_0001")
        XCTAssertEqual(ImportTemplate.expand(ImportNaming.jobSequence.template!, values), "Rue_001")
        XCTAssertEqual(ImportTemplate.expand(ImportNaming.dateName.template!, values), "20260919-L1004394")
        XCTAssertEqual(ImportTemplate.expand(ImportNaming.dateTime.template!, values), "20260919_113856")
        XCTAssertEqual(ImportNaming.camera.template, "")
        for naming in ImportNaming.allCases where naming != .custom { XCTAssertEqual(ImportNaming(template: naming.template!), naming) }
        XCTAssertEqual(ImportNaming(template: "{camera}_{seq:4}"), .custom)
    }

    func testEveryTagButtonInsertsAKnownTag() {
        for files in [false, true] {
            for tag in ImportTemplate.tags(forFiles: files) {
                XCTAssertNil(ImportTemplate.problem(tag.token, folders: !files), tag.title)
            }
        }
        XCTAssertTrue(ImportTemplate.tags(forFiles: true).contains { $0.token.hasPrefix("{seq") })
        XCTAssertFalse(ImportTemplate.tags(forFiles: false).contains { $0.token.hasPrefix("{seq") }, "a folder has no sequence")
        XCTAssertEqual(Set(ImportTemplate.tags(forFiles: false).map(\.title)), ["year", "month", "day", "month name", "job", "camera", "lens", "card"])
        XCTAssertNotNil(ImportTemplate.problem("{yyyy}/{camra}", folders: true), "an unknown tag is flagged")
    }

    func testATagGoesWhereTheCursorIs() {
        XCTAssertEqual(ImportTemplate.insert("{dd}", into: "{yyyy}/", at: NSRange(location: 7, length: 0)).text, "{yyyy}/{dd}")
        let middle = ImportTemplate.insert("{mm}-", into: "{yyyy}-{dd}", at: NSRange(location: 7, length: 0))
        XCTAssertEqual(middle.text, "{yyyy}-{mm}-{dd}")
        XCTAssertEqual(middle.caret, 12)
        XCTAssertEqual(ImportTemplate.insert("{job}", into: "old name", at: NSRange(location: 0, length: 3)).text, "{job} name", "over the selection")
        XCTAssertEqual(ImportTemplate.insert("{dd}", into: "ab", at: NSRange(location: 40, length: 2)).text, "ab{dd}", "never past the end")
    }

    func testOptionsSavedBeforeStillRead() throws {
        // Saved Settings and journals written before 0.4 have none of its keys.
        let old = #"{"mode":"copy","folders":"{yyyy}","rename":"","job":"","sequenceStart":1,"clockOffset":0,"dayStart":0,"pairs":"both","skipDuplicates":true,"skipRejected":true,"verify":true,"ejectAfter":false,"keywords":"","creator":"","copyright":"","caption":"","project":"Leica","balanceEach":false}"#
        let options = try JSONDecoder().decode(ImportOptions.self, from: Data(old.utf8))
        XCTAssertEqual(options.project, "Leica")
        XCTAssertNil(options.holder)
        XCTAssertNil(options.card)
        let marks = try JSONDecoder().decode(ImportMarks.self, from: Data(#"{"rating":2,"rotation":0}"#.utf8))
        XCTAssertNil(marks.label)
    }

    func testTheBoxAndTheCardChosen() {
        var options = ImportOptions()
        let box = UUID(), roll = UUID()
        options.boxID = box
        XCTAssertEqual(options.holder, .box(box))
        options.boxRollID = roll
        XCTAssertEqual(options.holder, .roll(roll, box: box))
        XCTAssertEqual(Holder.roll(roll, box: box).view, .roll(roll, box: box))
        options.film = "  "
        XCTAssertNil(options.card, "nothing typed, no card")
        options.film = "Portra 400"
        options.notes = "Rue de Rivoli"
        XCTAssertEqual(options.card, RollCardFile(film: "Portra 400", notes: "Rue de Rivoli"))
        var marks = ImportMarks()
        marks.label = "red"
        XCTAssertFalse(marks.isEmpty, "a label alone is written")
    }

    func testAPhotographTwiceInTheSourceIsFound() {
        let frames = [frame("/card/100LEICA/L1.DNG", "2026:09:19 11:00:00"), frame("/card/101LEICA/L1.DNG", "2026:09:19 11:00:00"),
                      frame("/card/101LEICA/L2.DNG", "2026:09:19 11:00:00"), frame("/card/102LEICA/L1.DNG", "2026:09:19 12:00:00"),
                      frame("/card/103LEICA/L1.DNG", "2026:09:19 11:00:00", size: 99), frame("/a/X.DNG", nil), frame("/b/X.DNG", nil)]
        let twins = ImportSession.twins(of: frames)
        XCTAssertEqual(twins, [URL(fileURLWithPath: "/card/101LEICA/L1.DNG"): URL(fileURLWithPath: "/card/100LEICA/L1.DNG")],
                       "same name, size and time; another time, size or name is another photograph, and no time proves nothing")
    }

    func testLeaveInPlaceRegistersTheFolderChosenWithItsTree() {
        let photos = ["/Photos/Spain/Madrid/day 1/a.DNG", "/Photos/Spain/Madrid/day 2/b.DNG", "/Photos/Spain/Sevilla/c.DNG"].map { URL(fileURLWithPath: $0) }
        let chosen = URL(fileURLWithPath: "/Photos/Spain", isDirectory: true)
        XCTAssertEqual(ImportSession.placeRoot(of: photos, source: chosen, sourceIsFolder: true)?.path, "/Photos/Spain")
        // From a disk: the deepest folder holding them all, never the whole disk.
        let disk = URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true)
        let onDisk = ["/Volumes/Archive/2024/Spain/a.DNG", "/Volumes/Archive/2024/Spain/b/c.DNG"].map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(ImportSession.placeRoot(of: onDisk, source: disk, sourceIsFolder: false)?.path, "/Volumes/Archive/2024/Spain")
        XCTAssertNil(ImportSession.placeRoot(of: [], source: disk, sourceIsFolder: false))
    }
}
