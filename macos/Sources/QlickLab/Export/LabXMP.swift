// Qlick Lab — GPL-3.0-only.
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What an exported file says of its development, as XMP inside the file itself (never a second file beside it):
/// the film and the paper it was developed on, the recipe, the program, the stars, and the photographer's own words
/// (keywords, title, caption, and the creator and copyright an import wrote in a `.xmp` beside the photograph).
/// The lab's fields use its namespace (`qlick:Film`, `qlick:Paper`, `qlick:Recipe`); the others the standard ones,
/// which every photo program reads.
struct LabXMP: Codable, Equatable, Sendable {
    var film: String?
    var paper: String?
    var recipe: String?
    /// 1–5, or −1 rejected; nil writes none.
    var rating: Int?
    var keywords: [String] = []
    var title = ""
    var caption = ""
    /// The photograph exported, whose `.xmp` beside it gives the creator and copyright.
    var photo: URL?
    /// False leaves out the photographer's words, creator and copyright (Metadata › None): only the lab's own
    /// fields and the stars stay.
    var personal = true

    static let namespace = DNGMetadata.namespace

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The creator and copyright of the photograph's own `.xmp` (as an import writes it), if any.
    func sidecarRights() -> (creator: String?, rights: String?) {
        guard personal, let photo else { return (nil, nil) }
        let url = photo.deletingPathExtension().appendingPathExtension("xmp")
        guard let data = try? Data(contentsOf: url), data.count < 4 << 20,
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return (nil, nil) }
        func first(_ path: String) -> String? {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString), let value = CGImageMetadataTagCopyValue(tag) else { return nil }
            if let text = value as? String { return text.isEmpty ? nil : text }
            if let array = value as? [CGImageMetadataTag], let item = array.first, let text = CGImageMetadataTagCopyValue(item) as? String { return text }
            return nil
        }
        return (first("dc:creator"), first("dc:rights"))
    }

    /// The packet, read off the main thread (the `.xmp` beside the photograph is on its disk).
    func packet() -> String {
        var attributes = "xmp:CreatorTool=\"\(Self.escape(SaveSettings.software))\""
        if let rating { attributes += " xmp:Rating=\"\(rating)\"" }
        if let film, !film.isEmpty { attributes += " qlick:Film=\"\(Self.escape(film))\"" }
        if let paper, !paper.isEmpty { attributes += " qlick:Paper=\"\(Self.escape(paper))\"" }
        if let recipe, !recipe.isEmpty { attributes += " qlick:Recipe=\"\(Self.escape(recipe))\"" }
        var body = ""
        if personal {
            let words = PhotoWords.clean(keywords)
            if !words.isEmpty { body += "<dc:subject><rdf:Bag>\(words.map { "<rdf:li>\(Self.escape($0))</rdf:li>" }.joined())</rdf:Bag></dc:subject>" }
            if !title.isEmpty { body += "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(Self.escape(title))</rdf:li></rdf:Alt></dc:title>" }
            if !caption.isEmpty { body += "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(Self.escape(caption))</rdf:li></rdf:Alt></dc:description>" }
            let (creator, rights) = sidecarRights()
            if let creator { body += "<dc:creator><rdf:Seq><rdf:li>\(Self.escape(creator))</rdf:li></rdf:Seq></dc:creator>" }
            if let rights {
                body += "<dc:rights><rdf:Alt><rdf:li xml:lang=\"x-default\">\(Self.escape(rights))</rdf:li></rdf:Alt></dc:rights>"
                attributes += " xmpRights:Marked=\"True\""
            }
        }
        return "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\">"
            + "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:xmpRights=\"http://ns.adobe.com/xap/1.0/rights/\" xmlns:qlick=\"\(Self.namespace)\" \(attributes)>"
            + body + "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
    }

    /// Writes `source` to `output` with `xmp` inside it, the image's bytes copied as they are (ImageIO merges the
    /// metadata; a PNG gets an `iTXt` chunk). Without `xmp`, or for a file ImageIO can't copy, the file is copied
    /// as it is.
    static func write(_ source: URL, to output: URL, xmp: LabXMP?) throws {
        let fm = FileManager.default
        guard let xmp else { return try fm.copyItem(at: source, to: output) }
        let packet = xmp.packet()
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(image) else {
            return try fm.copyItem(at: source, to: output)
        }
        if type as String == UTType.png.identifier {
            let data = try Data(contentsOf: source)
            guard let tagged = withPNGPacket(data, packet: packet) else { return try fm.copyItem(at: source, to: output) }
            return try tagged.write(to: output)
        }
        guard let metadata = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            return try fm.copyItem(at: source, to: output)
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        var error: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(destination, image, options as CFDictionary, &error) {
            try? fm.removeItem(at: output)
            try fm.copyItem(at: source, to: output)
        }
    }

    /// Adds `xmp` to `file` in place (through a hidden file beside it).
    static func embed(_ xmp: LabXMP, in file: URL) throws {
        let staging = file.deletingLastPathComponent().appendingPathComponent(".qlick-xmp-\(UUID().uuidString).\(file.pathExtension)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try write(file, to: staging, xmp: xmp)
        guard rename(staging.path, file.path) == 0 else { throw EngineError(message: "Could not add the metadata: \(String(cString: strerror(errno)))") }
    }

    /// A PNG with `packet` as an `iTXt` chunk (`XML:com.adobe.xmp`) before its image data, replacing one already
    /// there; every other byte stays. Nil if `data` isn't a PNG.
    static func withPNGPacket(_ data: Data, packet: String) -> Data? {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard data.count > 8, data.prefix(8) == signature else { return nil }
        let keyword = Data("XML:com.adobe.xmp".utf8)
        var chunks: [(type: Data, range: Range<Int>)] = []
        var at = data.startIndex + 8
        while at + 12 <= data.endIndex {
            let length = data[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            guard at + 12 + length <= data.endIndex else { return nil }
            chunks.append((data[at + 4..<at + 8], at..<at + 12 + length))
            at += 12 + length
        }
        guard let image = chunks.firstIndex(where: { $0.type == Data("IDAT".utf8) }) else { return nil }
        var body = Data("iTXt".utf8)
        body += keyword + Data([0, 0, 0, 0, 0]) + Data(packet.utf8)
        var chunk = Data()
        let length = UInt32(body.count - 4)
        chunk += withUnsafeBytes(of: length.bigEndian) { Data($0) }
        chunk += body
        chunk += withUnsafeBytes(of: ExportRating.crc32(body).bigEndian) { Data($0) }
        var out = Data(signature)
        for (index, piece) in chunks.enumerated() {
            if index == image { out += chunk }
            let isXMP = piece.type == Data("iTXt".utf8) && data[piece.range.lowerBound + 8..<min(piece.range.upperBound, piece.range.lowerBound + 8 + keyword.count)] == keyword
            if !isXMP { out += data[piece.range] }
        }
        return out
    }

    /// The lab's fields a file carries, for tests and checks.
    static func read(_ file: URL) -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [:] }
        var found: [String: String] = [:]
        for path in ["qlick:Film", "qlick:Paper", "qlick:Recipe", "xmp:CreatorTool", "xmp:Rating", "dc:rights", "dc:creator", "dc:subject", "dc:title"] {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString), let value = CGImageMetadataTagCopyValue(tag) else { continue }
            if let array = value as? [CGImageMetadataTag] {
                found[path] = array.compactMap { CGImageMetadataTagCopyValue($0) as? String }.joined(separator: ", ")
            } else {
                found[path] = "\(value)"
            }
        }
        return found
    }
}
