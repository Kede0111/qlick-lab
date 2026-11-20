// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// An import as it runs, and its account once it's done. Two ways to watch it: the Film Lab, where the roll passes
/// through the gate and its contact sheet builds up underneath, and a compact list for large imports. Either way
/// the figures stay in sight: how many, how much, how fast, how long, how many errors.
struct ImportProgressView: View {
    let model: EditorModel
    let run: ImportRun
    private var session: ImportSession { model.lab.importer }

    /// The compact list above a few hundred frames, with Reduce Motion or on low power; else the Film Lab.
    private var compact: Bool {
        switch session.progressStyle {
        case .compact: return true
        case .filmLab: return false
        case .automatic:
            return run.total > ImportProgressStyle.compactAbove || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.title(15)).foregroundStyle(Theme.paper)
                    if let waiting = run.waitingFor {
                        Text("Waiting for “\(waiting)”. Put it back and the import goes on where it stopped.").font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                    } else if let name = run.currentName, !run.finished {
                        Text(run.paused ? "Paused" : "\(run.adding ? "Adding" : "Copying") \(name)").font(Theme.value(11.5)).foregroundStyle(Theme.dim)
                    }
                }
                Spacer(minLength: 8)
                if !run.finished {
                    Picker("", selection: $session.progressStyle) { ForEach(ImportProgressStyle.allCases, id: \.self) { Text($0.title).tag($0) } }
                        .labelsHidden().controlSize(.small).fixedSize().help("How the import is shown")
                    if !run.adding {
                        Button(run.paused ? "Resume" : "Pause") { session.togglePause() }.buttonStyle(QPillButtonStyle())
                            .help("Waits after the file being copied")
                    }
                    Button("Stop") { session.stop() }.buttonStyle(QPillButtonStyle())
                        .help(run.adding ? "Stops after the photographs being added. Those added stay in the Archive."
                                         : "Stops after the file being copied. What’s copied stays, and the rest can be taken up later.")
                }
            }
            .padding(.horizontal, 18).frame(height: 54)
            .background(Color(white: 0.04))

            // The safelight: the one red line.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Rectangle().fill(Theme.accent).frame(width: geometry.size.width * run.fraction)
                }
            }
            .frame(height: 2)
            .animation(.linear(duration: 0.15), value: run.fraction)

            ZStack(alignment: .top) {
                if run.finished { ImportAccount(model: model, run: run) }
                else if compact { ImportList(run: run) }
                else { FilmLabView(run: run) }
                // Always in sight.
                Text(run.figures).font(Theme.value(12.5)).foregroundStyle(Theme.paper)
                    .padding(.horizontal, 16).frame(height: 32)
                    .glass(Capsule())
                    .padding(.top, 14)
                    .accessibilityLabel("Import progress: \(run.figures)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var title: String {
        if run.adding {
            if run.finished { return run.stopped ? "Adding stopped" : run.failed > 0 ? "Added, with errors" : "Added" }
            return "Adding from “\(run.sourceName)”"
        }
        if run.finished { return run.stopped ? "Import stopped" : run.failed > 0 ? "Imported, with errors" : "Imported" }
        return "Importing from “\(run.sourceName)”"
    }
}

// MARK: Film Lab

/// The roll through the gate. Each frame shows the state its file is really in:
/// dark and numbered while it waits, a negative on its orange base while it's copied, and its positive once the
/// copy has been read back and matches. The negative is only how the camera's preview is shown, never a rendering.
private struct FilmLabView: View {
    let run: ImportRun

    /// The frame at the gate: the one being copied, or the first that waits.
    private var gate: Int {
        run.order.firstIndex { run.state(of: $0) == .copying } ?? run.order.firstIndex { run.state(of: $0) == .waiting } ?? max(run.order.count - 1, 0)
    }

    var body: some View {
        GeometryReader { geometry in
            let frameWidth = min(max(geometry.size.width / 5.2, 150), 300)
            let stripHeight = frameWidth / 1.5 + frameWidth * 0.26
            VStack(spacing: 0) {
                Spacer().frame(height: 64)
                FilmGate(run: run, gate: gate, frameWidth: frameWidth, width: geometry.size.width)
                    .frame(height: stripHeight)
                ImportSheet(run: run)
                    .padding(.top, 22)
            }
        }
        .background(Color(white: 0.03))
    }
}

/// The strip of film at the gate: a few frames either side of the one being copied.
private struct FilmGate: View {
    let run: ImportRun
    let gate: Int
    let frameWidth: CGFloat
    let width: CGFloat

    var body: some View {
        let pitch = frameWidth * (38.0 / 36.0)
        let reach = Int((width / pitch / 2).rounded(.up)) + 1
        let range = max(gate - reach, 0)...min(gate + reach, max(run.order.count - 1, 0))
        ZStack {
            Rectangle().fill(Color.black)
            Perforations(pitch: pitch, shift: CGFloat(gate) * pitch).fill(Color(white: 0.13))
            if !run.order.isEmpty {
                ForEach(Array(range), id: \.self) { index in
                    let id = run.order[index]
                    FilmFrame(source: id, written: run.written[id], state: run.state(of: id), number: index + 1)
                        .frame(width: frameWidth, height: frameWidth / 1.5)
                        .offset(x: CGFloat(index - gate) * pitch)
                }
            }
            // The gate: the frame the light is on.
            RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.5)
                .frame(width: frameWidth + 10, height: frameWidth / 1.5 + 10)
        }
        .clipped()
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: gate)
    }
}

/// A 135 film's perforations: eight to a frame, along both edges.
private struct Perforations: Shape {
    var pitch: CGFloat
    var shift: CGFloat
    var animatableData: CGFloat { get { shift } set { shift = newValue } }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = pitch / 8, hole = CGSize(width: step * 0.42, height: rect.height * 0.062)
        let start = rect.midX - shift.truncatingRemainder(dividingBy: step) - step * ceil(rect.width / step / 2 + 1)
        var x = start
        while x < rect.maxX + step {
            for y in [rect.minY + rect.height * 0.035, rect.maxY - rect.height * 0.035 - hole.height] {
                path.addRoundedRect(in: CGRect(x: x - hole.width / 2 + step / 2, y: y, width: hole.width, height: hole.height), cornerSize: CGSize(width: 1.5, height: 1.5))
            }
            x += step
        }
        return path
    }
}

private struct FilmFrame: View {
    let source: URL
    let written: URL?
    let state: ImportFrameState
    let number: Int
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.045))
            if let image, state != .waiting {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .colorInvert()
                    .colorMultiply(Color(red: 1.0, green: 0.62, blue: 0.36))
                    .opacity(state == .copying ? 1 : 0)
                Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .opacity(state == .verified ? 1 : state == .failed ? 0.25 : 0)
            }
            if state == .failed { ImportMark(flag: .reject, seed: source.lastPathComponent) }
            if state == .waiting { Text("\(number)").font(Theme.value(13)).foregroundStyle(Color(white: 0.22)) }
        }
        .animation(.easeInOut(duration: 0.55), value: state)
        .help(help)
        .task(id: source) {
            // The grid's own thumbnail, already read: the card isn't asked again while it's being copied.
            let file = PhotoFile(url: source)
            let loaded = await PhotoThumbnails.shared.image(for: file, size: .medium)
            if !Task.isCancelled { image = loaded }
        }
    }

    private var help: String {
        switch state {
        case .waiting: "\(source.lastPathComponent): waiting"
        case .copying: "\(source.lastPathComponent): being copied"
        case .verified: "\(source.lastPathComponent): copied and checked" + (written.map { "\n\($0.path)" } ?? "")
        case .failed: "\(source.lastPathComponent): failed"
        }
    }
}

/// The contact sheet as it builds up: every frame whose copy is checked, on strips of six, read from the copy.
private struct ImportSheet: View {
    let run: ImportRun

    var body: some View {
        let done = run.order.filter { run.state(of: $0) == .verified }
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 4), count: 6), spacing: 14) {
                    ForEach(done, id: \.self) { id in
                        SheetThumb(url: run.written[id] ?? id)
                            .frame(width: 96, height: 64)
                            .id(id)
                            .transition(.scale(scale: 1.35).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.black)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: done.count)
            }
            .onChange(of: done.count) { if let last = done.last { proxy.scrollTo(last, anchor: .bottom) } }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SheetThumb: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color(white: 0.06)
            if let image { Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit) }
        }
        .task(id: url) {
            let file = PhotoFile(url: url)
            let loaded = await PhotoThumbnails.shared.image(for: file, size: .medium)
            if !Task.isCancelled { image = loaded }
        }
    }
}

// MARK: Compact

/// Every file and its state, plainly: for imports of thousands, and for whoever wants no animation.
private struct ImportList: View {
    let run: ImportRun

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(run.order.enumerated()), id: \.element) { index, id in
                        let state = run.state(of: id)
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(Theme.value(10.5)).foregroundStyle(Theme.faint).frame(width: 44, alignment: .trailing)
                            Image(systemName: symbol(state)).font(.system(size: 11)).foregroundStyle(state == .failed ? Theme.warn : state == .verified ? Theme.paper : Theme.dim).frame(width: 16)
                            Text(id.lastPathComponent).font(Theme.value(11.5)).foregroundStyle(state == .waiting ? Theme.dim : Theme.paper).frame(width: 190, alignment: .leading).lineLimit(1)
                            Text(run.adding ? "" : run.written[id].map { $0.deletingLastPathComponent().lastPathComponent + " / " + $0.lastPathComponent } ?? "").font(Theme.value(11)).foregroundStyle(Theme.dim)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(word(state, adding: run.adding)).font(.system(size: 11)).foregroundStyle(state == .failed ? Theme.warn : Theme.dim)
                        }
                        .padding(.horizontal, 16).frame(height: 24)
                        .background(state == .copying ? Color.white.opacity(0.06) : .clear)
                        .id(id)
                    }
                }
                .padding(.top, 60).padding(.bottom, 16)
            }
            .onChange(of: run.done) {
                if let current = run.order.first(where: { run.state(of: $0) == .copying }) { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    private func symbol(_ state: ImportFrameState) -> String {
        switch state {
        case .waiting: "circle"
        case .copying: "arrow.down.circle"
        case .verified: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
    private func word(_ state: ImportFrameState, adding: Bool) -> String {
        switch state {
        case .waiting: "Waiting"
        case .copying: adding ? "Adding" : "Copying"
        case .verified: adding ? "Added" : "Copied and checked"
        case .failed: adding ? "Added, marks not saved" : "Failed"
        }
    }
}

// MARK: The account

/// What the import did, in plain words, and what can be done next.
private struct ImportAccount: View {
    let model: EditorModel
    let run: ImportRun
    private var session: ImportSession { model.lab.importer }

    var body: some View {
        let session = session
        let good = run.done - run.failed
        let left = run.total - run.done
        let checked = session.options.verify
        let project = session.options.project.trimmingCharacters(in: .whitespaces)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: run.failed > 0 || run.stopped ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(run.failed > 0 ? Theme.warn : Theme.paper)
                    VStack(alignment: .leading, spacing: 3) {
                        if run.adding {
                            Text("\(run.done) \(run.done == 1 ? "photograph" : "photographs") added").font(Theme.title(18)).foregroundStyle(Theme.paper)
                            Text("in \(ImportRun.duration(run.elapsed)), from \(run.folders.count) \(run.folders.count == 1 ? "folder" : "folders")\(project.isEmpty ? "" : ", in “\(project)”")").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        } else {
                            Text("\(good) \(good == 1 ? "photograph" : "photographs") copied\(checked ? " and checked" : "")").font(Theme.title(18)).foregroundStyle(Theme.paper)
                            Text("in \(ImportRun.duration(run.elapsed)), to \(run.folders.count) \(run.folders.count == 1 ? "folder" : "folders")").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                        }
                    }
                }
                if run.stopped, left > 0 {
                    line(run.adding ? "\(left) not added. Add them again whenever you like: those already in the Archive are left as they are."
                                    : "\(left) still to copy. Nothing is lost: take the import up again whenever you like.")
                }
                if !run.adding, !run.stopped, run.failed == 0, session.source?.kind == .card {
                    let skipped = session.frames.count - run.total
                    line(checked
                         ? "Every photograph you chose has a copy that was read back and matches the card." + (skipped > 0 ? " \(skipped) on the card were left out." : " The card can be formatted in the camera.")
                         : "The copies weren’t checked against the card (Check every copy is off).")
                    if run.ejected { line("“\(run.sourceName)” was ejected.") }
                }
                if !run.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        CapsLabel(run.adding ? "Marks not saved" : "Not copied", color: Theme.warn)
                        ForEach(Array(run.failures.prefix(50).enumerated()), id: \.offset) { _, failure in
                            Text("\(failure.name): \(failure.reason)").font(.system(size: 11.5)).foregroundStyle(Theme.paper).fixedSize(horizontal: false, vertical: true)
                        }
                        if run.failures.count > 50 { Text("and \(run.failures.count - 50) more, listed in the import report").font(.system(size: 11)).foregroundStyle(Theme.dim) }
                    }
                }
                if !run.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        CapsLabel("Notes")
                        ForEach(Array(run.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !run.adding { line("An import report with every file’s SHA-256 is in each folder.") }
                HStack(spacing: 8) {
                    if !run.folders.isEmpty {
                        Button { session.openImported() } label: { Label("Open the Contact Sheet", systemImage: "film") }.buttonStyle(QPrimaryButtonStyle())
                            .help("The photographs just imported, on their contact sheet. Their previews are developed in the background.")
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(run.folders) }.buttonStyle(QPillButtonStyle())
                    }
                    if session.unfinished != nil { Button("Resume") { session.run = nil; session.resume() }.buttonStyle(QPillButtonStyle()) }
                    if session.source?.volume != nil, !run.ejected { Button("Eject") { session.eject(); session.dismissRun() }.buttonStyle(QPillButtonStyle()) }
                    Button("Done") { session.dismissRun() }.buttonStyle(QPillButtonStyle())
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.top, 78).padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.82)).fixedSize(horizontal: false, vertical: true)
    }
}

/// The import under way, wherever you are in the lab: in the sidebar, with a way back to it.
struct ImportSidebarProgress: View {
    let model: EditorModel
    var body: some View {
        let session = model.lab.importer
        if let run = session.run, !run.finished {
            Button { model.lab.show(.importer) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(run.waitingFor != nil ? "Import waiting" : run.paused ? "Import paused" : run.adding ? "Adding" : "Importing").font(.system(size: 10.5)).foregroundStyle(run.waitingFor != nil ? Theme.warn : Theme.dim)
                        Spacer()
                        Text("\(run.done) / \(run.total)").font(Theme.value(10.5)).foregroundStyle(Theme.dim)
                    }
                    ProgressView(value: run.fraction).progressViewStyle(.linear).tint(Theme.accent).controlSize(.mini)
                }
                .padding(.horizontal, 20).padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(run.figures)
        }
    }
}
