// Qlick Lab — GPL-3.0-only.
import CryptoKit
import Darwin
import Foundation

/// Copies one file so that the original is never at risk and nothing is ever written over:
///
/// 1. the source is read once, its SHA-256 taken as it passes;
/// 2. the bytes go to a hidden file in the destination folder (folder listings skip hidden files, so a copy under
///    way is never taken for a photograph);
/// 3. that file is forced to the disk, read back from the disk, and its hash compared with the source's;
/// 4. it takes its name by a rename that fails if the name is taken.
///
/// Nothing here touches the source. Blocking calls throughout: run it off the main thread.
enum ImportCopier {
    static let partExtension = "qnpart"
    static let chunk = 4 * 1024 * 1024

    struct Failure: Error, LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    enum Outcome: Equatable, Sendable {
        /// Written as `url` (numbered if the name was taken by another file).
        case copied(URL)
        /// The same bytes already lay there under that name: nothing was written.
        case alreadyThere(URL)
    }

    struct Result: Equatable, Sendable {
        var outcome: Outcome
        /// The source's SHA-256, in hex.
        var hash: String
        var bytes: Int
        var url: URL { switch outcome { case .copied(let url), .alreadyThere(let url): url } }
    }

    private static func fail(_ what: String, _ path: String) -> Failure {
        Failure(message: "\(what) “\((path as NSString).lastPathComponent)”: \(String(cString: strerror(errno))).")
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// A file's SHA-256, read from the disk rather than from memory when `uncached`.
    static func hash(of url: URL, uncached: Bool = false, cancelled: () -> Bool = { false }) throws -> String {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw fail("Couldn’t read", url.path) }
        defer { close(descriptor) }
        if uncached { _ = fcntl(descriptor, F_NOCACHE, 1) }
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        while true {
            if cancelled() { throw CancellationError() }
            let count = read(descriptor, buffer, chunk)
            if count < 0 { if errno == EINTR { continue }; throw fail("Couldn’t read", url.path) }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        return hex(hasher.finalize())
    }

    /// Copies `source` to `destination` as described above. `progress` is told of every chunk's bytes; `cancelled`
    /// is asked between chunks. A taken name whose file holds the same bytes is `alreadyThere`; one that holds
    /// others gets `-2`, `-3`… With `knownHash` (a second copy of a file already read), the source's hash must
    /// match it.
    static func copy(_ source: URL, to destination: URL, verify: Bool = true, knownHash: String? = nil,
                     progress: (Int) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> Result {
        let folder = destination.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            throw Failure(message: "Couldn’t make the folder “\(folder.lastPathComponent)”: \(error.localizedDescription)")
        }
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw fail("Couldn’t read", source.path) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw fail("Couldn’t read", source.path) }

        let part = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.prefix(8)).\(partExtension)")
        let output = open(part.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else { throw fail("Couldn’t write in", folder.path) }
        var finished = false
        defer { if !finished { unlink(part.path) } }

        var hasher = SHA256(), total = 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        do {
            defer { close(output) }
            while true {
                if cancelled() { throw CancellationError() }
                let count = read(input, buffer, chunk)
                if count < 0 { if errno == EINTR { continue }; throw fail("Couldn’t read", source.path) }
                if count == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
                var written = 0
                while written < count {
                    let done = write(output, buffer + written, count - written)
                    if done < 0 { if errno == EINTR { continue }; throw fail("Couldn’t write", destination.path) }
                    written += done
                }
                total += count
                progress(count)
            }
            // The file's dates, as the camera left them: the previews are named by them.
            var times = [info.st_atimespec, info.st_mtimespec]
            _ = futimens(output, &times)
            guard fsync(output) == 0 else { throw fail("Couldn’t write", destination.path) }
        }
        guard total == Int(info.st_size) else {
            throw Failure(message: "“\(source.lastPathComponent)” changed while it was read (\(total) of \(info.st_size) bytes).")
        }
        let sourceHash = hex(hasher.finalize())
        if let knownHash, knownHash != sourceHash {
            throw Failure(message: "“\(source.lastPathComponent)” didn’t read the same twice: the source may be failing.")
        }
        if verify {
            let copied = try hash(of: part, uncached: true, cancelled: cancelled)
            guard copied == sourceHash else {
                throw Failure(message: "The copy of “\(source.lastPathComponent)” doesn’t match its original. Nothing was kept; the original is untouched.")
            }
        }
        // Its name, never over another file.
        let stem = destination.deletingPathExtension().lastPathComponent, ext = destination.pathExtension
        var target = destination
        for number in 2..<10_000 {
            if renamex_np(part.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                finished = true
                return Result(outcome: .copied(target), hash: sourceHash, bytes: total)
            }
            guard errno == EEXIST else { throw fail("Couldn’t name", target.path) }
            if let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int, size == total,
               (try? hash(of: target, cancelled: cancelled)) == sourceHash {
                return Result(outcome: .alreadyThere(target), hash: sourceHash, bytes: total)
            }
            target = folder.appendingPathComponent("\(stem)-\(number)").appendingPathExtension(ext)
        }
        throw Failure(message: "Couldn’t find a free name for “\(destination.lastPathComponent)”.")
    }

    /// Removes what an interrupted import left in `folder`: its hidden half-written files.
    static func removeParts(in folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == partExtension && file.lastPathComponent.hasPrefix(".") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Bytes free for new files on the volume holding `url` (or its nearest existing parent).
    static func freeSpace(at url: URL) -> Int? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder = folder.deletingLastPathComponent() }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return Int(important) }
        return values?.volumeAvailableCapacity
    }
}
