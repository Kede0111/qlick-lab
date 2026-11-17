import Darwin
import Foundation

// Qlick Lab: a DNG keeps its own rating, mark and edits in its XMP, as other
// photo apps keep theirs, so it needs no `.qlick` file beside it. The XMP holds
// the standard fields other apps read (`xmp:Rating`, `xmpDM:pick`), a few
// readable ones of the lab's (film, paper, white balance, exposure) and the
// whole sidecar, as JSON, in `qlick:Sidecar`: what `SidecarStore` reads back.
// The format is in docs/sidecar-format.md.

/// Where ratings, marks and edits of DNG photographs are saved. Other
/// photographs always have a `.qlick` file; reading looks in both places.
enum SidecarStorage: String, CaseIterable, Sendable {
    case insideDNG = "dng", qlickFiles = "qlick"

    static let defaultsKey = "sidecarStorage"
    static var current: SidecarStorage {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SidecarStorage.init(rawValue:)) ?? .insideDNG
    }

    var title: String {
        switch self {
        case .insideDNG: "Inside DNG files"
        case .qlickFiles: ".qlick files"
        }
    }
}

enum DNGMetadata {
    static let namespace = "http://ns.jackfrom.be/qlicklab/1.0/"
    static let prefix = "qlick"
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let dynamicMediaNS = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"
    /// A variant made up for a DNG rated or marked by another app.
    static let derivedVariant = "dng00000"
    /// Room left in a packet the lab writes, so later changes fit in place.
    static let padding = 16 * 1024

    struct Unsupported: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func isDNG(_ url: URL) -> Bool { url.pathExtension.lowercased() == "dng" }

    // MARK: TIFF

    /// What a write needs of a DNG's structure: its first directory and where its XMP is.
    struct Layout: Equatable {
        struct Entry: Equatable {
            var tag: UInt16
            var type: UInt16
            var count: UInt32
            var value: UInt32
            /// The entry's 12 bytes, as in the file.
            var raw: [UInt8]
            /// Where they are.
            var at: Int
        }
        var little: Bool
        var size: Int
        var ifd0: Int
        var entries: [Entry]
        var next: [UInt8]

        var isDNG: Bool { entries.contains { $0.tag == 0xC612 } }
        /// The XMP entry, when its packet is stored apart from it.
        var xmp: Entry? { entries.first { $0.tag == 700 && ($0.type == 1 || $0.type == 7) && $0.count > 4 } }

        func u16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
            let a = UInt16(bytes[bytes.startIndex]), b = UInt16(bytes[bytes.startIndex + 1])
            return little ? a | b << 8 : a << 8 | b
        }
        func u32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
            let s = bytes.startIndex
            let v = (0..<4).map { UInt32(bytes[s + $0]) }
            return little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
        }
        func bytes16(_ v: UInt16) -> [UInt8] { little ? [UInt8(v & 0xff), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xff)] }
        func bytes32(_ v: UInt32) -> [UInt8] {
            let b = [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]
            return little ? b : b.reversed()
        }
    }

    static func read(_ fd: Int32, at offset: Int, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let read = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard read == count else { throw Unsupported(reason: "it ends too soon") }
        return buffer
    }

    static func write(_ fd: Int32, _ bytes: [UInt8], at offset: Int) throws {
        let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, off_t(offset)) }
        guard written == bytes.count else { throw EngineError(message: String(cString: strerror(errno))) }
    }

    static func layout(_ fd: Int32) throws -> Layout {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw EngineError(message: String(cString: strerror(errno))) }
        let size = Int(info.st_size)
        guard size >= 16 else { throw Unsupported(reason: "it isn’t a DNG") }
        let header = try read(fd, at: 0, count: 8)
        let little: Bool
        switch (header[0], header[1], header[2], header[3]) {
        case (0x49, 0x49, 0x2A, 0x00): little = true
        case (0x4D, 0x4D, 0x00, 0x2A): little = false
        default: throw Unsupported(reason: "it isn’t a DNG")
        }
        var layout = Layout(little: little, size: size, ifd0: 0, entries: [], next: [])
        layout.ifd0 = Int(layout.u32(header[4..<8]))
        guard layout.ifd0 >= 8, layout.ifd0 + 2 <= size else { throw Unsupported(reason: "its first directory is out of place") }
        let count = Int(layout.u16(try read(fd, at: layout.ifd0, count: 2)[...]))
        guard count > 0, count < 1000, layout.ifd0 + 2 + count * 12 + 4 <= size else { throw Unsupported(reason: "its first directory is damaged") }
        let table = try read(fd, at: layout.ifd0 + 2, count: count * 12 + 4)
        for index in 0..<count {
            let raw = Array(table[index * 12..<index * 12 + 12])
            layout.entries.append(Layout.Entry(tag: layout.u16(raw[0..<2]), type: layout.u16(raw[2..<4]), count: layout.u32(raw[4..<8]),
                                               value: layout.u32(raw[8..<12]), raw: raw, at: layout.ifd0 + 2 + index * 12))
        }
        layout.next = Array(table[count * 12..<count * 12 + 4])
        if let xmp = layout.xmp, Int(xmp.value) + Int(xmp.count) > size || Int(xmp.value) < 8 {
            throw Unsupported(reason: "its XMP is out of place")
        }
        return layout
    }

    /// The DNG's XMP packet; nil when it has none.
    static func packet(_ fd: Int32, _ layout: Layout) throws -> Data? {
        guard let xmp = layout.xmp else { return nil }
        guard xmp.count <= 16 * 1024 * 1024 else { throw Unsupported(reason: "its XMP is too large") }
        return Data(try read(fd, at: Int(xmp.value), count: Int(xmp.count)))
    }

    // MARK: XMP

    /// What the lab manages in a packet: the stored sidecar and the standard
    /// rating and mark (nil when absent).
    struct Managed: Equatable {
        var sidecar: JSONValue?
        var rating: Int?
        var pick: Int?
        /// The sidecar couldn't be read.
        var damaged = false
    }

    /// The XML inside the packet's `<?xpacket?>` wrapper, and the wrapper's head.
    private static func unwrap(_ packet: Data) -> (head: String?, xml: String) {
        var text = String(decoding: packet, as: UTF8.self)
        while text.hasSuffix("\0") { text.removeLast() }
        var head: String?
        if text.hasPrefix("<?xpacket begin"), let end = text.range(of: "?>") {
            head = String(text[..<end.upperBound])
            text = String(text[end.upperBound...])
        }
        if let trailer = text.range(of: "<?xpacket end", options: .backwards) { text = String(text[..<trailer.lowerBound]) }
        return (head, text)
    }

    private static func document(_ xml: String) throws -> XMLDocument {
        try XMLDocument(xmlString: xml, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
    }

    private static func rdfRoot(_ document: XMLDocument) -> XMLElement? {
        guard let root = document.rootElement() else { return nil }
        if root.localName == "RDF", root.uri == rdf { return root }
        return root.elements(forLocalName: "RDF", uri: rdf).first
    }

    /// A property's value in any description, as an attribute or a simple element.
    private static func value(_ name: String, _ uri: String, in descriptions: [XMLElement]) -> String? {
        for description in descriptions {
            if let attribute = description.attribute(forLocalName: name, uri: uri) { return attribute.stringValue }
            if let element = description.elements(forLocalName: name, uri: uri).first { return element.stringValue }
        }
        return nil
    }

    static func managed(in packet: Data) -> Managed {
        // Most packets hold nothing of the lab's: skip parsing them.
        let markers = [namespace, "Rating", "pick"].map { Data($0.utf8) }
        guard markers.contains(where: { packet.range(of: $0) != nil }) else { return Managed() }
        guard let document = try? document(unwrap(packet).xml), let rdfRoot = rdfRoot(document) else { return Managed() }
        let descriptions = rdfRoot.elements(forLocalName: "Description", uri: rdf)
        var managed = Managed()
        managed.rating = value("Rating", xmpNS, in: descriptions).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { Int($0.rounded()) }
        managed.pick = value("pick", dynamicMediaNS, in: descriptions).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let json = value("Sidecar", namespace, in: descriptions) {
            if let raw = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) { managed.sidecar = raw } else { managed.damaged = true }
        }
        return managed
    }

    /// The standard rating and mark that stand for `raw`'s first variant.
    static func standard(for raw: JSONValue?) -> (rating: Int, pick: Int) {
        guard let first = raw?["variants"].array.first else { return (0, 0) }
        let rating = min(max(first["rating"].integer ?? 0, 0), 5)
        switch first["flag"] {
        case .string("reject"): return (-1, -1)
        case .string("pick"): return (rating, 1)
        default: return (rating, 0)
        }
    }

    /// The sidecar a packet stands for: the stored one, with the rating and
    /// mark another app set since laid over its first variant; or one made
    /// up from them when the lab never wrote the file.
    static func sidecar(from managed: Managed) throws -> JSONValue? {
        if managed.damaged { throw PhotoSidecar.Problem.unreadable("its XMP isn’t Qlick Lab’s") }
        let expected = standard(for: managed.sidecar)
        let rating = managed.rating ?? 0, pick = managed.pick ?? 0
        guard managed.sidecar == nil || (rating, pick) != expected else { return managed.sidecar }
        guard managed.sidecar != nil || rating != 0 || pick != 0 else { return nil }
        var top = managed.sidecar?.object ?? ["qlick": .number(Double(PhotoSidecar.schema)), "defaultsVersion": .number(Double(SidecarDefaults.latest))]
        var variants = top["variants"]?.array ?? []
        if variants.isEmpty { variants = [.object(["id": .string(derivedVariant)])] }
        var first = variants[0].object ?? [:]
        let flag: PhotoSidecar.Flag? = rating == -1 || pick == -1 ? .reject : pick == 1 ? .pick : nil
        let stars = (0...5).contains(rating) ? rating : rating == -1 ? first["rating"]?.integer ?? 0 : 0
        first["rating"] = stars > 0 ? .number(Double(stars)) : nil
        first["flag"] = flag.map { .string($0.rawValue) }
        variants[0] = .object(first)
        top["variants"] = .array(variants)
        return .object(top)
    }

    /// The packet with the lab's fields set for `raw` (removed for nil), every
    /// other property kept. The rating and mark are rewritten only when they
    /// change, so a photograph the lab never rated keeps another app's.
    static func updated(_ packet: Data?, raw: JSONValue?, now: Date = Date()) throws -> Data {
        let (head, xml) = packet.map(unwrap) ?? (nil, "")
        let document: XMLDocument
        if xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document = try self.document("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"\(rdf)\"></rdf:RDF></x:xmpmeta>")
        } else {
            document = try self.document(xml)
        }
        guard let rdfRoot = rdfRoot(document) else { throw Unsupported(reason: "its XMP has no RDF") }
        let descriptions = rdfRoot.elements(forLocalName: "Description", uri: rdf)
        let about = descriptions.first?.attribute(forLocalName: "about", uri: rdf)?.stringValue ?? ""

        var managed: [(String, String)] = [("Rating", xmpNS), ("pick", dynamicMediaNS), ("MetadataDate", xmpNS)]
        for description in descriptions {
            // The lab's own description goes whole; it's written again below.
            let ours = description.namespaces?.contains { $0.stringValue == namespace } == true
                || (description.children ?? []).contains { ($0 as? XMLElement)?.uri == namespace }
            if ours { description.detach(); continue }
            for (name, uri) in managed {
                if let attribute = description.attribute(forLocalName: name, uri: uri), let qualified = attribute.name {
                    description.removeAttribute(forName: qualified)
                }
                for element in description.elements(forLocalName: name, uri: uri) { element.detach() }
            }
        }
        managed.removeAll()

        let description = XMLElement(name: "rdf:Description", uri: rdf)
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", uri: rdf, stringValue: about) as! XMLNode)
        for (name, uri) in [("xmp", xmpNS), ("xmpDM", dynamicMediaNS), (prefix, namespace)] {
            description.addNamespace(XMLNode.namespace(withName: name, stringValue: uri) as! XMLNode)
        }
        func add(_ name: String, _ uri: String, _ prefix: String, _ value: String) {
            let element = XMLElement(name: "\(prefix):\(name)", uri: uri)
            element.stringValue = value
            description.addChild(element)
        }
        let standard = standard(for: raw)
        add("Rating", xmpNS, "xmp", String(standard.rating))
        add("pick", dynamicMediaNS, "xmpDM", String(standard.pick))
        add("MetadataDate", xmpNS, "xmp", ISO8601DateFormatter.string(from: now, timeZone: .current,
                                                                       formatOptions: [.withInternetDateTime]))
        if let raw {
            let edits = raw["variants"].array.first?["edits"]
            if case .string(let film)? = edits?["film"] { add("Film", namespace, prefix, film) }
            if case .string(let paper)? = edits?["paper"] { add("Paper", namespace, prefix, paper) }
            let balance = edits?["params.io.raw_white_balance"]
            if case .string(let mode)? = balance?["mode"] { add("WhiteBalance", namespace, prefix, mode) }
            if case .number(let kelvin)? = balance?["temperature"] { add("Temperature", namespace, prefix, number(kelvin)) }
            if case .number(let tint)? = balance?["tint"] { add("Tint", namespace, prefix, number(tint)) }
            if case .number(let ev)? = edits?["params.prep.exposure_ev"] { add("Exposure", namespace, prefix, number(ev)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            add("Sidecar", namespace, prefix, String(decoding: try encoder.encode(raw), as: UTF8.self))
        }
        rdfRoot.addChild(description)

        let body = (document.rootElement()?.xmlString(options: [.nodePreserveAll]) ?? "")
        let opening = head ?? "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
        return Data((opening + "\n" + body + "\n").utf8)
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// `body` padded with whitespace and closed to exactly `length` bytes; nil when it doesn't fit.
    static func padded(_ body: Data, to length: Int) -> Data? {
        let trailer = Data("<?xpacket end=\"w\"?>".utf8)
        let room = length - body.count - trailer.count
        guard room >= 0 else { return nil }
        var data = body
        var left = room
        while left > 0 {
            let line = min(left, 100)
            data.append(contentsOf: [UInt8](repeating: 0x20, count: line - 1) + [line == 1 ? 0x20 : 0x0A])
            left -= line
        }
        data.append(trailer)
        return data
    }

    // MARK: Reading

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: (signature: [Int], value: Result<JSONValue?, PhotoSidecar.Problem>)] = [:]
    }
    private static let cache = Cache()

    private static func signature(_ info: stat) -> [Int] {
        [Int(info.st_dev), Int(info.st_ino), Int(info.st_size), Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec),
         Int(info.st_ctimespec.tv_sec), Int(info.st_ctimespec.tv_nsec)]
    }

    /// The sidecar a DNG holds, as `SidecarStore` reads a `.qlick` file; nil
    /// when it holds nothing of the lab's or isn't a DNG the lab can read.
    static func sidecar(of photo: URL) throws -> JSONValue? {
        let fd = open(photo.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let key = photo.standardizedFileURL.path, signature = signature(info)
        cache.lock.lock()
        if let cached = cache.entries[key], cached.signature == signature { cache.lock.unlock(); return try cached.value.get() }
        cache.lock.unlock()
        let value: Result<JSONValue?, PhotoSidecar.Problem>
        do {
            let layout = try layout(fd)
            let managed = try packet(fd, layout).map(managed(in:)) ?? Managed()
            value = .success(try sidecar(from: managed))
        } catch let problem as PhotoSidecar.Problem {
            value = .failure(problem)
        } catch {
            value = .success(nil)
        }
        cache.lock.lock()
        if cache.entries.count > 4000 { cache.entries.removeAll() }
        cache.entries[key] = (signature, value)
        cache.lock.unlock()
        return try value.get()
    }

    // MARK: Writing

    /// The hidden copy a write goes through, which folder scans and the watcher skip.
    static func temporaryURL(for photo: URL) -> URL {
        photo.deletingLastPathComponent().appendingPathComponent(".\(photo.lastPathComponent).qlick-tmp")
    }

    /// Writes `raw` into the DNG's XMP (removes the lab's fields for nil).
    /// Returns false when the file already says so and is left untouched.
    ///
    /// The change is made on a copy (an APFS clone, sharing the image's
    /// blocks), which is checked byte for byte against the original outside
    /// the XMP before it replaces it with a rename. The packet is rewritten in
    /// its own place when it fits, so the file keeps its size; otherwise it
    /// goes at the end of the file and only its directory entry changes. The
    /// file keeps its creation and modification dates.
    @discardableResult static func write(_ raw: JSONValue?, to photo: URL, now: Date = Date()) throws -> Bool {
        // Another app changing the file meanwhile gets one more try.
        do { return try attempt(raw, photo, now) } catch is Changed { return try attempt(raw, photo, now) }
    }

    private struct Changed: Error, LocalizedError {
        var errorDescription: String? { "It changed while it was being written." }
    }

    private static func attempt(_ raw: JSONValue?, _ photo: URL, _ now: Date) throws -> Bool {
        guard isDNG(photo) else { throw Unsupported(reason: "it isn’t a DNG") }
        let file = photo.resolvingSymlinksInPath()
        var before = stat()
        guard lstat(file.path, &before) == 0 else { throw EngineError(message: String(cString: strerror(errno))) }
        guard before.st_mode & S_IFMT == S_IFREG else { throw Unsupported(reason: "it isn’t a regular file") }
        guard before.st_nlink == 1 else { throw Unsupported(reason: "it has other hard links") }
        guard access(file.path, W_OK) == 0, before.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) == 0 else {
            throw Unsupported(reason: "it is locked or read-only")
        }

        // What the file holds now, and what it should.
        let source = open(file.path, O_RDONLY)
        guard source >= 0 else { throw EngineError(message: String(cString: strerror(errno))) }
        let layout: Layout, old: Data?
        do {
            defer { close(source) }
            layout = try self.layout(source)
            guard layout.isDNG else { throw Unsupported(reason: "it isn’t a DNG") }
            old = try packet(source, layout)
        }
        let current = old.map(managed(in:)) ?? Managed()
        if current.damaged { throw EngineError(message: "\(photo.lastPathComponent) holds edits this version can’t read; they are left as they are.") }
        let wanted = standard(for: raw)
        if current.sidecar == raw, (current.rating ?? 0, current.pick ?? 0) == wanted { return false }
        let body = try updated(old, raw: raw, now: now)

        // The copy, changed and checked.
        let temporary = temporaryURL(for: file)
        unlink(temporary.path)
        guard copyfile(file.path, temporary.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) == 0 else {
            throw EngineError(message: String(cString: strerror(errno)))
        }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        let fd = open(temporary.path, O_RDWR)
        guard fd >= 0 else { throw EngineError(message: String(cString: strerror(errno))) }
        var changed: [Range<Int>] = []
        do {
            defer { close(fd) }
            guard try self.layout(fd) == layout else { throw Changed() }
            if let xmp = layout.xmp, let fitted = padded(body, to: Int(xmp.count)) {
                try write(fd, Array(fitted), at: Int(xmp.value))
                changed.append(Int(xmp.value)..<Int(xmp.value) + Int(xmp.count))
            } else {
                // At the end of the file, word aligned, with room to grow in place.
                var end = layout.size
                if end % 2 == 1 { try write(fd, [0], at: end); end += 1 }
                guard let fitted = padded(body, to: body.count + 32 + padding), end + fitted.count < Int(UInt32.max) else {
                    throw Unsupported(reason: "it is too large")
                }
                try write(fd, Array(fitted), at: end)
                var after = end + fitted.count
                if let xmp = layout.xmp {
                    try write(fd, layout.bytes32(UInt32(fitted.count)) + layout.bytes32(UInt32(end)), at: xmp.at + 4)
                    changed.append(xmp.at + 4..<xmp.at + 12)
                } else {
                    // A new first directory with the XMP entry, written after the packet.
                    if after % 2 == 1 { try write(fd, [0], at: after); after += 1 }
                    let entry = layout.bytes16(700) + layout.bytes16(7) + layout.bytes32(UInt32(fitted.count)) + layout.bytes32(UInt32(end))
                    var raws = layout.entries.map(\.raw)
                    let index = layout.entries.firstIndex { $0.tag > 700 } ?? raws.count
                    raws.insert(entry, at: index)
                    let directory = layout.bytes16(UInt16(raws.count)) + raws.flatMap { $0 } + layout.next
                    try write(fd, directory, at: after)
                    try write(fd, layout.bytes32(UInt32(after)), at: 4)
                    changed.append(4..<8)
                }
            }
            guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw EngineError(message: String(cString: strerror(errno))) }
            try verify(original: file, copy: temporary, unchanged: layout.size, except: changed)
            let written = try self.layout(fd)
            guard managed(in: try packet(fd, written) ?? Data()) == Managed(sidecar: raw, rating: wanted.rating, pick: wanted.pick) else {
                throw EngineError(message: "The XMP written into \(photo.lastPathComponent) didn’t read back the same, so the photograph was left as it was.")
            }
        }

        // The photograph's own dates, then the swap, unless it changed meanwhile.
        var times = [before.st_birthtimespec, before.st_mtimespec]
        try times.withUnsafeMutableBytes { buffer in
            var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                                commonattr: attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME), volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
            guard setattrlist(temporary.path, &list, buffer.baseAddress, buffer.count, 0) == 0 else {
                throw EngineError(message: String(cString: strerror(errno)))
            }
        }
        var now = stat()
        guard lstat(file.path, &now) == 0, signature(now) == signature(before) else { throw Changed() }
        guard rename(temporary.path, file.path) == 0 else { throw EngineError(message: String(cString: strerror(errno))) }
        renamed = true
        let folder = open(file.deletingLastPathComponent().path, O_RDONLY)
        if folder >= 0 { fsync(folder); close(folder) }
        return true
    }

    /// Throws unless `copy`'s first `length` bytes are `original`'s, outside `ranges`.
    static func verify(original: URL, copy: URL, unchanged length: Int, except ranges: [Range<Int>]) throws {
        let a = try Data(contentsOf: original, options: .alwaysMapped)
        let b = try Data(contentsOf: copy, options: .alwaysMapped)
        guard a.count == length, b.count >= length else { throw Changed() }
        var start = 0
        let cuts = ranges.sorted { $0.lowerBound < $1.lowerBound }
        let same = a.withUnsafeBytes { x in
            b.withUnsafeBytes { y in
                func equal(_ from: Int, _ to: Int) -> Bool {
                    to <= from || memcmp(x.baseAddress! + from, y.baseAddress! + from, to - from) == 0
                }
                for cut in cuts {
                    if !equal(start, min(cut.lowerBound, length)) { return false }
                    start = max(start, cut.upperBound)
                }
                return equal(start, length)
            }
        }
        guard same else {
            throw EngineError(message: "Writing into \(original.lastPathComponent) would have changed more than its metadata, so it was left as it was.")
        }
    }
}
