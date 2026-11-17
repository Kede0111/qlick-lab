import Foundation
import XCTest
@testable import QlickLab

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qlick-dng-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

/// A small little-endian DNG: a first directory with DNGVersion, one strip
/// of "image" bytes and, when given, an XMP packet.
private func makeDNG(at url: URL, xmp: Data? = nil) throws -> (strip: Range<Int>, bytes: Data) {
    var data = Data()
    func u16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    func u32(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]) }
    let image = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    let entries = xmp == nil ? 4 : 5
    let ifdSize = 2 + entries * 12 + 4
    let stripAt = 8 + ifdSize
    let xmpAt = stripAt + image.count
    data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00]); u32(8)
    u16(entries)
    u16(256); u16(4); u32(1); u32(64)                  // ImageWidth
    u16(273); u16(4); u32(1); u32(stripAt)             // StripOffsets
    u16(279); u16(4); u32(1); u32(image.count)         // StripByteCounts
    if let xmp { u16(700); u16(1); u32(xmp.count); u32(xmpAt) }
    u16(0xC612); u16(1); u32(4); data.append(contentsOf: [1, 4, 0, 0])  // DNGVersion
    u32(0)
    data.append(image)
    if let xmp { data.append(xmp) }
    try data.write(to: url)
    return (stripAt..<stripAt + image.count, data)
}

/// Another app's packet: its own properties, a rating and padding to grow into.
private func foreignPacket(rating: String? = nil, padding: Int = 4096) -> Data {
    let rated = rating.map { " xmp:Rating=\"\($0)\"" } ?? ""
    let body = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Test">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="Camera"
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"\(rated)
        crs:Temperature="5880" crs:Exposure2012="-0.05">
       <dc:subject><rdf:Bag><rdf:li>street</rdf:li><rdf:li>night &amp; rain</rdf:li></rdf:Bag></dc:subject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>

    """
    return DNGMetadata.padded(Data(body.utf8), to: body.utf8.count + padding + 20)!
}

private func dates(_ url: URL) throws -> (Date, Date) {
    let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return (values.creationDate!, values.contentModificationDate!)
}

private func setDates(_ url: URL) throws {
    try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                           .modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: url.path)
}

private let sidecar = """
{"qlick":1,"defaultsVersion":1,"app":"test","variants":[{"id":"v1","rating":4,"flag":"pick",
 "edits":{"film":"kodak_portra_400","paper":"kodak_portra_endura","params":{"prep":{"exposure_ev":1.33},
 "io":{"raw_white_balance":{"mode":"custom","temperature":4800,"tint":3}}}}},{"id":"v2","rating":1}]}
"""

final class DNGMetadataTests: XCTestCase {
    func testFirstWriteAddsAnXMPEntryAndKeepsTheImage() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("A.DNG")
        let (strip, before) = try makeDNG(at: photo)
        try setDates(photo)
        let raw = try json(sidecar)

        XCTAssertTrue(try DNGMetadata.write(raw, to: photo))
        let after = try Data(contentsOf: photo)
        XCTAssertEqual(after[strip], before[strip], "the image data is the same")
        XCTAssertEqual(after.prefix(4), before.prefix(4))
        XCTAssertEqual(after[8..<before.count], before[8...], "nothing before the end moved but the header's pointer")
        XCTAssertEqual(try DNGMetadata.sidecar(of: photo), raw)
        XCTAssertEqual(try dates(photo).0, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try dates(photo).1, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DNGMetadata.temporaryURL(for: photo).path))

        // The second write fits in the room the first left: same size, same image.
        var changed = raw
        changed["variants"] = .array([try json(#"{"id":"v1","rating":2,"flag":"reject"}"#)])
        XCTAssertTrue(try DNGMetadata.write(changed, to: photo))
        let again = try Data(contentsOf: photo)
        XCTAssertEqual(again.count, after.count)
        XCTAssertEqual(again[strip], before[strip])
        XCTAssertEqual(try DNGMetadata.sidecar(of: photo), changed)
        XCTAssertFalse(try DNGMetadata.write(changed, to: photo), "nothing to change, the file isn't touched")
    }

    func testAnotherAppsXMPIsKeptAndItsRatingRead() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("B.dng")
        let (strip, before) = try makeDNG(at: photo, xmp: foreignPacket(rating: "3"))

        // Rated elsewhere, never by the lab: the rating shows.
        let read = try XCTUnwrap(try DNGMetadata.sidecar(of: photo))
        XCTAssertEqual(read["variants"].array.first?["rating"], .number(3))
        XCTAssertEqual(try PhotoSidecar(raw: read).summary.rating, 3)

        let raw = try json(sidecar)
        XCTAssertTrue(try DNGMetadata.write(raw, to: photo))
        let after = try Data(contentsOf: photo)
        XCTAssertEqual(after.count, before.count, "the packet is rewritten in its own room")
        XCTAssertEqual(after[strip], before[strip])
        let text = String(decoding: after, as: UTF8.self)
        for kept in ["crs:Temperature=\"5880\"", "crs:Exposure2012=\"-0.05\"", "night &amp; rain", "<qlick:Film>kodak_portra_400</qlick:Film>",
                     "<qlick:Temperature>4800</qlick:Temperature>", "<qlick:Exposure>1.33</qlick:Exposure>", "<xmp:Rating>4</xmp:Rating>",
                     "<xmpDM:pick>1</xmpDM:pick>"] {
            XCTAssertTrue(text.contains(kept), kept)
        }
        XCTAssertFalse(text.contains("xmp:Rating=\"3\""), "one rating, the lab's")
        XCTAssertEqual(try DNGMetadata.sidecar(of: photo), raw)
    }

    func testRatingsChangedElsewhereWinOverTheStoredOnes() throws {
        let raw = try json(sidecar)
        var managed = DNGMetadata.Managed(sidecar: raw, rating: 4, pick: 1)
        XCTAssertEqual(try DNGMetadata.sidecar(from: managed), raw)
        managed.rating = -1; managed.pick = 0
        let rejected = try XCTUnwrap(try DNGMetadata.sidecar(from: managed))
        XCTAssertEqual(rejected["variants"].array.first?["flag"], .string("reject"))
        XCTAssertEqual(rejected["variants"].array.first?["rating"], .number(4), "the stars stay under a reject")
        XCTAssertEqual(rejected["variants"].array.count, 2)
        managed.rating = 5; managed.pick = 0
        let rated = try XCTUnwrap(try DNGMetadata.sidecar(from: managed))
        XCTAssertEqual(rated["variants"].array.first?["rating"], .number(5))
        XCTAssertEqual(rated["variants"].array.first?["flag"], .null)
        XCTAssertNil(try DNGMetadata.sidecar(from: DNGMetadata.Managed(rating: 0, pick: 0)))
    }

    func testRemovingEverythingLeavesTheRatingAtZero() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("C.DNG")
        _ = try makeDNG(at: photo, xmp: foreignPacket(rating: "2"))
        XCTAssertTrue(try DNGMetadata.write(nil, to: photo))
        XCTAssertNil(try DNGMetadata.sidecar(of: photo))
        let text = String(decoding: try Data(contentsOf: photo), as: UTF8.self)
        XCTAssertFalse(text.contains("qlick:Sidecar"))
        XCTAssertTrue(text.contains("crs:Temperature=\"5880\""))
    }

    func testOnlyDNGsAreWritten() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("D.CR3")
        try Data(repeating: 1, count: 64).write(to: raw)
        XCTAssertThrowsError(try DNGMetadata.write(try json(sidecar), to: raw))
        let tiff = dir.appendingPathComponent("E.dng")
        try Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, 1, 0, 0, 1, 4, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]).write(to: tiff)
        XCTAssertThrowsError(try DNGMetadata.write(try json(sidecar), to: tiff), "a TIFF without DNGVersion isn't written")
        XCTAssertEqual(try Data(contentsOf: raw), Data(repeating: 1, count: 64))
    }

    func testTheStoreWritesIntoTheDNGAndMovesAnyQlickFileIntoIt() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("F.DNG")
        let (strip, before) = try makeDNG(at: photo, xmp: foreignPacket())
        try Data(sidecar.utf8).write(to: PhotoSidecar.url(for: photo))
        let store = SidecarStore(storage: { .insideDNG })

        XCTAssertEqual(try store.read(photo: photo)?.summary.rating, 4, "the .qlick file is read while it's there")
        store.enqueue(SidecarPatch(variant: "v1", rating: 5, defaultsVersion: 1, app: "test"), for: photo)
        let failures = await store.flush()
        XCTAssertEqual(failures, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: PhotoSidecar.url(for: photo).path), "moved into the DNG")
        XCTAssertEqual(try store.read(photo: photo)?.summary.rating, 5)
        XCTAssertEqual(try store.read(photo: photo)?.variants.count, 2)
        XCTAssertEqual(try Data(contentsOf: photo)[strip], before[strip])

        // Unrated and unmarked, with no edits: nothing of the lab's stays.
        store.enqueue(SidecarPatch(variant: "v1", replacement: .some(nil), defaultsVersion: 1, app: "test"), for: photo)
        _ = await store.flush()
        XCTAssertNil(try store.read(photo: photo))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PhotoSidecar.url(for: photo).path))
    }

    func testWithQlickFilesADNGIsLeftAlone() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("G.DNG")
        _ = try makeDNG(at: photo)
        try DNGMetadata.write(try json(sidecar), to: photo)
        let inside = try Data(contentsOf: photo)
        let store = SidecarStore(storage: { .qlickFiles })

        XCTAssertEqual(try store.read(photo: photo)?.summary.rating, 4, "edits inside the DNG are still read")
        store.enqueue(SidecarPatch(variant: "v1", replacement: .some(nil), defaultsVersion: 1, app: "test"), for: photo)
        _ = await store.flush()
        XCTAssertEqual(try Data(contentsOf: photo), inside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PhotoSidecar.url(for: photo).path), "an empty .qlick file stands over them")
        XCTAssertEqual(try store.read(photo: photo)?.summary, LibrarySummary())
    }

    func testListingReadsADNGAsItsOwnSidecar() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeDNG(at: dir.appendingPathComponent("H.DNG"))
        try Data([0xFF, 0xD8]).write(to: dir.appendingPathComponent("I.jpg"))
        let listing = try PhotoFolder.listing(in: dir)
        XCTAssertEqual(listing.sidecars.count, 1)
        XCTAssertEqual(listing.sidecars[dir.appendingPathComponent("H.DNG").path]?.name, "H.DNG")
    }

    /// On a copy of a real DNG (`QLICK_TEST_DNG`): only its XMP changes, and
    /// every other XMP property is still there.
    func testARealDNG() throws {
        guard let path = ProcessInfo.processInfo.environment["QLICK_TEST_DNG"] else { throw XCTSkip("QLICK_TEST_DNG not set") }
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("real.DNG")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: photo)
        let before = try Data(contentsOf: photo)
        let fd = open(photo.path, O_RDONLY); defer { close(fd) }
        let layout = try DNGMetadata.layout(fd)
        let xmp = try XCTUnwrap(layout.xmp)
        let raw = try json(sidecar)
        XCTAssertTrue(try DNGMetadata.write(raw, to: photo))
        let after = try Data(contentsOf: photo)
        XCTAssertEqual(after.count, before.count)
        let start = Int(xmp.value), end = start + Int(xmp.count)
        XCTAssertEqual(after[..<start], before[..<start])
        XCTAssertEqual(after[end...], before[end...])
        XCTAssertEqual(try DNGMetadata.sidecar(of: photo), raw)
    }
}
