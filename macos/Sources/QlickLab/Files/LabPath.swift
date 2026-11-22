// Qlick Lab — GPL-3.0-only.
import Foundation

extension URL {
    /// `standardizedFileURL` without asking the disk. Foundation's, on a URL that came from AppKit or the file system,
    /// checks that the file can be reached, and on a NAS whose server has gone that check never returns: the lab froze
    /// at launch on the folder it had open (2026-11-22). This one works on the path's words alone: `.` and `..` and
    /// doubled slashes go, and the system's own links (/private/var, /private/tmp, /private/etc) read as their short
    /// names, as Foundation's would.
    var labStandardized: URL {
        guard isFileURL else { return standardizedFileURL }
        return URL(fileURLWithPath: Self.labStandardizing(path), isDirectory: hasDirectoryPath)
    }

    static func labStandardizing(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        var standard = "/" + parts.joined(separator: "/")
        for link in ["/private/var", "/private/tmp", "/private/etc"] where standard == link || standard.hasPrefix(link + "/") {
            standard.removeFirst("/private".count)
            break
        }
        return standard
    }
}
