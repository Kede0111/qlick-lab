// Qlick Lab — GPL-3.0-only.
import Foundation

/// Runs an import's journal: every waiting file copied and checked, one at a time, off the main thread, with no
/// engine and no GPU, so it works the same on a Mac of 8 GB. It says what happens as it happens; the journal is
/// written as it goes, so whatever stops it (Stop, quitting, a card pulled out, a crash) the next run takes up
/// where this one left.
final class ImportRunner: @unchecked Sendable {
    enum Event: Sendable {
        /// Bytes read and written since the last one.
        case bytes(Int)
        /// A file is being copied.
        case started(item: Int, name: String)
        /// A photograph's files are all settled (copied, already there or failed).
        case settled(item: Int, ImportJournal.Item)
        /// The source or the destination is away; the import waits for it.
        case waiting(String?)
        case finished(ImportJournal)
    }

    private let lock = NSLock()
    private var cancelFlag = false
    private var pauseFlag = false

    var cancelled: Bool { lock.withLock { cancelFlag } }
    var paused: Bool {
        get { lock.withLock { pauseFlag } }
        set { lock.withLock { pauseFlag = newValue } }
    }
    func cancel() { lock.withLock { cancelFlag = true } }

    /// Copies what's waiting in `journal`. Returns it as it stands when everything is settled or the run is stopped.
    func run(_ start: ImportJournal, journalURL: URL? = ImportJournal.url, ledger: ImportLedger?, events: @escaping @Sendable (Event) -> Void) -> ImportJournal {
        var journal = start
        var lastSave = Date(), unsaved = 0
        func save(force: Bool = false) {
            guard let journalURL, force || unsaved >= 25 || Date().timeIntervalSince(lastSave) > 2 else { return }
            try? journal.write(to: journalURL)
            lastSave = Date(); unsaved = 0
        }
        // Halves an interrupted run left behind.
        for folder in Set(journal.items.flatMap { $0.files.flatMap { [$0.planned.destination, $0.planned.backup].compactMap { $0?.deletingLastPathComponent() } } }) {
            ImportCopier.removeParts(in: folder)
        }
        save(force: true)
        let verify = journal.options.verify
        outer: for index in journal.items.indices where !journal.items[index].settled {
            for fileIndex in journal.items[index].files.indices where journal.items[index].files[fileIndex].status == .waiting {
                while paused && !cancelled { Thread.sleep(forTimeInterval: 0.2) }
                if cancelled { break outer }
                var file = journal.items[index].files[fileIndex]
                let planned = file.planned
                events(.started(item: index, name: planned.source.name))
                var attempt = 0
                while true {
                    attempt += 1
                    var sent = 0
                    do {
                        let result = try ImportCopier.copy(planned.source.url, to: planned.destination, verify: verify,
                                                           progress: { sent += $0; events(.bytes($0)) }, cancelled: { self.cancelled })
                        file.written = result.url
                        file.hash = result.hash
                        if case .alreadyThere = result.outcome { file.status = .present } else { file.status = .done }
                        // The second copy, from the source again, never from the first copy.
                        if let backup = planned.backup {
                            _ = try ImportCopier.copy(planned.source.url, to: backup, verify: verify, knownHash: result.hash, cancelled: { self.cancelled })
                            file.backupDone = true
                        }
                        break
                    } catch is CancellationError {
                        events(.bytes(-sent))
                        break outer
                    } catch {
                        events(.bytes(-sent))
                        // A card pulled out or a disk gone to sleep: wait for it rather than fail every file after.
                        if let away = missingVolume(journal, planned) {
                            events(.waiting(away))
                            while missingVolume(journal, planned) != nil && !cancelled { Thread.sleep(forTimeInterval: 1) }
                            events(.waiting(nil))
                            if cancelled { break outer }
                            attempt = 0
                            continue
                        }
                        // Once more, for a read that failed in passing.
                        if attempt < 2 { continue }
                        file.status = .failed
                        file.error = error.localizedDescription
                        break
                    }
                }
                journal.items[index].files[fileIndex] = file
                if file.status == .done || file.status == .present, let written = file.written {
                    Self.copyCompanion(of: planned.source.url, beside: written, verify: verify)
                }
                if file.status == .done || file.status == .present, let written = file.written {
                    ledger?.record(planned.source, captured: journal.items[index].captured, hash: file.hash, destination: written)
                }
                unsaved += 1
            }
            let item = journal.items[index]
            // Move: the source goes to the Trash once every copy of it is checked. Never deleted outright.
            if journal.options.mode == .move, item.done, item.files.allSatisfy({ $0.planned.backup == nil || $0.backupDone }) {
                for file in item.files { try? FileManager.default.trashItem(at: file.planned.source.url, resultingItemURL: nil) }
            }
            events(.settled(item: index, item))
            save()
        }
        save(force: true)
        events(.finished(journal))
        return journal
    }

    /// Qlick Lab: a photograph's development from QLab travels with it: its `.qsidecar` beside it in the source, or its
    /// former `.qlab.json` when it has none, is copied beside the copy (never over a sidecar there already).
    static func copyCompanion(of source: URL, beside written: URL, verify: Bool) {
        let fm = FileManager.default
        for suffix in [PhotoSidecar.fileExtension, "qlab.json"] {
            let companion = URL(fileURLWithPath: source.path + "." + suffix)
            guard fm.fileExists(atPath: companion.path) else { continue }
            let target = URL(fileURLWithPath: written.path + "." + suffix)
            if !fm.fileExists(atPath: target.path) { _ = try? ImportCopier.copy(companion, to: target, verify: verify) }
            return
        }
    }

    /// The name of the source or destination that isn't there any more, if that's why a copy failed.
    private func missingVolume(_ journal: ImportJournal, _ planned: PlannedFile) -> String? {
        let fm = FileManager.default
        if let root = journal.sourceRoot, !fm.fileExists(atPath: root.path) { return journal.sourceName }
        for url in [journal.options.destination, journal.options.secondCopy].compactMap({ $0 }) {
            let parts = url.labStandardized.pathComponents
            // /Volumes/Name/…: the disk itself.
            if parts.count >= 3, parts[1] == "Volumes", !fm.fileExists(atPath: "/Volumes/\(parts[2])") { return parts[2] }
        }
        return nil
    }
}
