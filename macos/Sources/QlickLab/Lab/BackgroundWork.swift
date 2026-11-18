// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// Qlick Lab: one piece of work the lab does in the background, as the activity pill, its panel and the sidebar
/// show it: what it is, how far it got, and how to stop it. Stopping stops the work itself (its helpers are quit),
/// not only its progress.
struct BackgroundTask: Identifiable {
    enum Kind: String, CaseIterable {
        case export, importing, recipe, reading, proxies, thumbnails, previews, saving
        /// One word, where there's little room: the pill and the sidebar.
        var word: String {
            switch self {
            case .export: "Export"
            case .importing: "Import"
            case .recipe: "Recipe"
            case .reading: "Thumbnails"
            case .proxies: "Proxies"
            case .thumbnails: "Thumbnails"
            case .previews: "Previews"
            case .saving: "Saving"
            }
        }
    }
    let kind: Kind
    var id: String { kind.rawValue }
    let title: String
    /// What it's on now (a file's name), or a word on what it leaves.
    var detail: String?
    let done: Int
    /// Nil when it's counted in what's left rather than done.
    let total: Int?
    var left: Int?
    /// Nil when it can't be stopped (edits being written).
    let stop: (() -> Void)?
    var stopHelp = "Stop"

    /// "12 of 340", "48 left": counted from 1, the one under way included.
    var figure: String {
        if let total { return "\(BackgroundWork.number(min(done + 1, total))) of \(BackgroundWork.number(total))" }
        return left.map { "\(BackgroundWork.number($0)) left" } ?? ""
    }

    var fraction: Double? { total.map { $0 > 0 ? Double(done) / Double($0) : 0 } }
}

/// Qlick Lab: every queue of background work, in one list, and Stop All.
@MainActor enum BackgroundWork {
    static func tasks(_ model: EditorModel) -> [BackgroundTask] {
        let lab = model.lab
        var tasks: [BackgroundTask] = []
        if let run = model.batch, run.running {
            tasks.append(BackgroundTask(kind: .export, title: "Exporting", detail: nil, done: run.finished, total: run.total,
                                        stop: { run.cancel() }, stopHelp: "Stop exporting: what's exported stays"))
        } else if model.exporting {
            tasks.append(BackgroundTask(kind: .export, title: "Exporting", detail: model.sourceItem.map { model.library.name(of: $0) },
                                        done: 0, total: 1, stop: { model.cancelExport() }, stopHelp: "Stop exporting"))
        }
        if let run = lab.importer.run, !run.finished {
            tasks.append(BackgroundTask(kind: .importing, title: run.adding ? "Adding photographs" : "Importing", detail: run.currentName,
                                        done: run.done, total: run.total, stop: { lab.importer.stop() },
                                        stopHelp: "Stop after the photograph under way: what's done stays, and the rest can be taken up later"))
        }
        if let work = model.backgroundWork, work.total > 0 {
            tasks.append(BackgroundTask(kind: .recipe, title: work.title, detail: nil, done: work.done, total: work.total,
                                        stop: { model.stopApplying() }, stopHelp: "Stop: what's done stays, and can be undone"))
        }
        if model.embeddedRead.total > 0 {
            tasks.append(BackgroundTask(kind: .reading, title: "Reading thumbnails", detail: "From the files, kept on this Mac",
                                        done: model.embeddedRead.done, total: model.embeddedRead.total,
                                        stop: { model.stopReadingThumbnails() },
                                        stopHelp: "Stop reading: those read stay, the rest are read as they're shown"))
        }
        let proxies = lab.proxyMaker
        if proxies.total > 0, proxies.busy {
            let names = proxies.current.map(\.lastPathComponent).sorted()
            var detail = names.isEmpty ? nil : names.joined(separator: ", ")
            if !proxies.leftOut.isEmpty {
                detail = (detail.map { $0 + " · " } ?? "") + "\(number(proxies.leftOut.count)) more as they're opened: the cache keeps no more"
            }
            tasks.append(BackgroundTask(kind: .proxies, title: "Making proxies", detail: detail, done: proxies.done, total: proxies.total,
                                        stop: { proxies.stop() },
                                        stopHelp: "Stop making this folder's proxies: those without one open from their RAW, and get theirs then"))
        }
        if model.thumbnailsAsked.total > 0 {
            tasks.append(BackgroundTask(kind: .thumbnails, title: "Building thumbnails", detail: nil, done: model.thumbnailsAsked.done,
                                        total: model.thumbnailsAsked.total, stop: { model.stopThumbnails() },
                                        stopHelp: "Stop building thumbnails: those on screen are still developed"))
        } else if model.thumbnailsLeft > 0 {
            tasks.append(BackgroundTask(kind: .thumbnails, title: "Developing thumbnails", detail: nil, done: 0, total: nil,
                                        left: model.thumbnailsLeft, stop: model.thumbnailsHeld ? nil : { model.stopThumbnails() },
                                        stopHelp: "Stop developing the folder's thumbnails: those on screen are still developed"))
        }
        let previews = lab.previewBuilder
        if previews.running, previews.total > 0 {
            tasks.append(BackgroundTask(kind: .previews, title: "Building previews", detail: previews.current?.lastPathComponent,
                                        done: previews.done, total: previews.total, stop: { previews.stop() },
                                        stopHelp: "Stop building this folder's previews: Build Previews starts them again"))
        }
        if model.savingLeft > 1 {
            tasks.append(BackgroundTask(kind: .saving, title: "Saving edits", detail: nil, done: 0, total: nil, left: model.savingLeft,
                                        stop: nil))
        }
        return tasks
    }

    /// Stops every queue that can be stopped: exports, imports, recipes, proxies, thumbnails off screen and
    /// previews. Edits being written are always finished.
    static func stopAll(_ model: EditorModel) {
        for task in tasks(model) { task.stop?() }
        // Those not under way now don't start by themselves either, until asked for or another folder opens.
        model.lab.previewBuilder.stop()
        model.lab.proxyMaker.stop()
        model.stopThumbnails()
    }

    /// 9,561: grouped as the interface's other counts are.
    nonisolated static func number(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }
}

/// Qlick Lab: the lab at work in the background, where you are (grid, contact sheet, Develop): a turning mark,
/// what it does first and how far it got. A click opens the list of all it does, each with its own Stop.
struct BackgroundActivity: View {
    let model: EditorModel
    @State private var open = false

    var body: some View {
        let tasks = BackgroundWork.tasks(model)
        if let first = tasks.first {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini).tint(Q.red)
                    Text(first.kind.word).font(.system(size: 11)).foregroundStyle(Color(white: 0.8)).lineLimit(1)
                    Text(first.figure).font(Q.value(11)).foregroundStyle(Q.dim).lineLimit(1)
                    if tasks.count > 1 {
                        Text("+\(tasks.count - 1)").font(Q.value(10.5, weight: .medium)).foregroundStyle(Q.text)
                            .padding(.horizontal, 5).frame(height: 15)
                            .background(Capsule().fill(Q.red.opacity(0.85)))
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Q.dim)
                }
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(open ? 0.12 : 0.07)))
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Background work: click to see it all, and stop any of it")
            .accessibilityLabel("Background work: \(first.title), \(first.figure)")
            .popover(isPresented: $open, arrowEdge: .bottom) { BackgroundWorkPanel(model: model) }
            .onChange(of: model.lab.workPanelAsked) { open = true }
            .transition(.opacity)
        } else if let note = model.lab.previewBuilder.note {
            Label(note, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.8))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .transition(.opacity)
        }
    }
}

/// Qlick Lab: everything the lab does in the background, each with its progress and its Stop, and Stop All.
struct BackgroundWorkPanel: View {
    let model: EditorModel

    var body: some View {
        let tasks = BackgroundWork.tasks(model)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CapsLabel("Background work")
                Spacer()
                if tasks.contains(where: { $0.stop != nil }) {
                    Button("Stop All") { BackgroundWork.stopAll(model) }
                        .buttonStyle(QPrimaryButtonStyle())
                        .help("Stop every piece of background work. Edits being written are always finished.")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            if tasks.isEmpty {
                Text("Nothing at work.").font(.system(size: 11.5)).foregroundStyle(Q.dim)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(tasks) { task in
                        BackgroundTaskRow(task: task, large: true)
                        if task.id != tasks.last?.id { Divider().overlay(Q.hairline).padding(.horizontal, 16) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: 340)
        // As tall as its rows: a row that gains a line, or a task that starts, grows the panel.
        .fixedSize(horizontal: false, vertical: true)
        // The lab's dark, as its window: the popover takes it from here.
        .preferredColorScheme(.dark)
    }
}

/// One piece of background work: its title and figure, what it's on, its progress in red, and its Stop.
struct BackgroundTaskRow: View {
    let task: BackgroundTask
    /// The panel's row; the sidebar's is smaller.
    var large = false
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 6 : 5) {
            HStack(spacing: 8) {
                Text(large ? task.title : task.kind.word).font(.system(size: large ? 12 : 10.5, weight: large ? .medium : .regular))
                    .foregroundStyle(large ? Q.text : Q.dim).lineLimit(1)
                Spacer(minLength: 6)
                Text(task.figure).font(Q.value(large ? 11.5 : 10.5)).foregroundStyle(Q.dim).lineLimit(1)
                if let stop = task.stop {
                    Button(action: stop) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: large ? 13 : 10))
                            .foregroundStyle(hovered ? Q.red : Q.dim)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
                    .help(task.stopHelp)
                    .accessibilityLabel("Stop \(task.title.lowercased())")
                }
            }
            if let fraction = task.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Q.red).controlSize(.mini)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Q.red).controlSize(.mini)
            }
            if large, let detail = task.detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Q.dim).lineLimit(2).truncationMode(.middle)
            }
        }
        .padding(.horizontal, large ? 16 : 20).padding(.vertical, large ? 9 : 0).padding(.bottom, large ? 0 : 8)
        .help(task.detail ?? "")
    }
}
