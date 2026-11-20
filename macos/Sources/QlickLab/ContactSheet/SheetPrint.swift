// Qlick Lab — GPL-3.0-only.
import AppKit
import PDFKit
import SwiftUI

/// How a contact sheet goes on paper. Kept between launches.
struct SheetPrintOptions: Codable, Equatable, Sendable {
    enum Paper: String, Codable, CaseIterable, Sendable {
        case a4, a3, letter, tenByEight, twentyFourByThirty
        var title: String {
            switch self {
            case .a4: "A4"
            case .a3: "A3"
            case .letter: "US Letter"
            case .tenByEight: "8 × 10 pouces"
            case .twentyFourByThirty: "24 × 30 cm"
            }
        }
        /// Millimetres, upright.
        var millimetres: CGSize {
            switch self {
            case .a4: CGSize(width: 210, height: 297)
            case .a3: CGSize(width: 297, height: 420)
            case .letter: CGSize(width: 215.9, height: 279.4)
            case .tenByEight: CGSize(width: 203.2, height: 254)
            case .twentyFourByThirty: CGSize(width: 240, height: 300)
            }
        }
    }
    enum Background: String, Codable, CaseIterable, Sendable {
        case black, white
        var title: String { self == .black ? "Black paper" : "White paper" }
    }
    enum Frames: String, Codable, CaseIterable, Sendable {
        case all, shown, picks
        var title: String {
            switch self {
            case .all: "Every frame on the sheet"
            case .shown: "The frames shown"
            case .picks: "The picked frames"
            }
        }
    }

    var paper = Paper.a4
    var landscape = false
    var columns = 6
    var compact = false
    var background = Background.black
    var frames = Frames.all
    var marks = true
    var numbers = true
    var names = true
    var heading = true
    var sidewaysVerticals = false

    static let columnRange = 3...9
    static let key = "qlick.printOptions"

    static func load(_ defaults: UserDefaults = .standard) -> SheetPrintOptions {
        guard let data = defaults.data(forKey: key), let options = try? JSONDecoder().decode(SheetPrintOptions.self, from: data) else { return SheetPrintOptions() }
        return options
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// The page in points.
    var page: CGSize {
        let mm = paper.millimetres
        let size = CGSize(width: mm.width * 72 / 25.4, height: mm.height * 72 / 25.4)
        return landscape ? CGSize(width: size.height, height: size.width) : size
    }
}

/// The pages of a printed sheet: how many frames go on each, laid out by the same `ContactSheetLayout` as the window's.
struct SheetPagination: Equatable {
    static let margin: CGFloat = 28      // 10 mm
    static let footer: CGFloat = 16

    let page: CGSize
    let style: ContactSheetLayout.Style
    let columns: Int
    let header: CGFloat
    let showsNames: Bool
    let count: Int
    let rowsPerPage: Int

    init(options: SheetPrintOptions, count: Int, notes: Bool) {
        page = options.page
        style = options.compact ? .compact : .classic
        columns = min(max(options.columns, SheetPrintOptions.columnRange.lowerBound), SheetPrintOptions.columnRange.upperBound)
        header = options.heading ? (notes ? 62 : 46) : 0
        showsNames = options.names
        self.count = count
        let probe = ContactSheetLayout(style: style, count: columns, width: page.width, frameWidth: 100, header: header, showsNames: showsNames, columns: columns, margin: Self.margin)
        let room = page.height - probe.top - Self.margin - Self.footer
        rowsPerPage = max(Int(((room + probe.gap) / probe.rowPitch).rounded(.down)), 1)
    }

    var perPage: Int { rowsPerPage * columns }
    var pages: Int { max((count + perPage - 1) / max(perPage, 1), 1) }
    func range(_ page: Int) -> Range<Int> { min(page * perPage, count)..<min((page + 1) * perPage, count) }
    func layout(_ page: Int) -> ContactSheetLayout {
        ContactSheetLayout(style: style, count: range(page).count, width: self.page.width, frameWidth: 100, header: header, showsNames: showsNames,
                           columns: columns, margin: Self.margin)
    }
}

/// Makes the printed sheet: a PDF drawn by the sheet's own renderer, vector for the film, the type and the pencil,
/// with each frame as developed. Not a picture of the window.
@MainActor struct SheetPrinter {
    let model: EditorModel
    var options: SheetPrintOptions

    struct Frame {
        var file: PhotoFile
        var number: String
        var summary: LibrarySummary
    }

    /// The frames to print, in roll order, each with its number on the roll.
    var frames: [Frame] {
        let library = model.library
        var numbers: [URL: String] = [:]
        var count = 0
        for item in library.items {
            if item.url.variantID != nil { numbers[item.url] = String(format: "%02d", count) + "b" } else { count += 1; numbers[item.url] = String(format: "%02d", count) }
        }
        let items: [PhotoFile] = switch options.frames {
        case .all: library.items
        case .shown: model.shownPhotos
        case .picks: library.items.filter { library.summary(for: $0.url).flag == .pick }
        }
        return items.map { Frame(file: $0, number: numbers[$0.url] ?? "", summary: library.summary(for: $0.url)) }
    }

    var heading: SheetHeading {
        let lab = model.lab
        var heading = lab.sheetHeading
        if heading.title.isEmpty { heading.title = model.library.directory.map { PhotoFolder.isList($0) ? "" : $0.lastPathComponent } ?? "" }
        if heading.title.isEmpty { heading.title = "Contact Sheet" }
        return heading
    }

    var suggestedName: String {
        let heading = heading
        let parts = [model.lab.current?.project.name ?? model.lab.workingArchive?.name, heading.title].compactMap { $0 }.filter { !$0.isEmpty }
        return (parts.isEmpty ? "Contact Sheet" : "Contact sheet — " + parts.joined(separator: " — ")) + ".pdf"
    }

    /// The sheet as a PDF. `progress` hears how many frames are read, of how many.
    func pdf(progress: (@MainActor (Int, Int) -> Void)? = nil) async -> Data? {
        let frames = frames
        guard !frames.isEmpty else { return nil }
        var heading = heading
        let pagination = SheetPagination(options: options, count: frames.count, notes: !heading.notes.isEmpty)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: options.page)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: "Qlick Lab", kCGPDFContextTitle: heading.title] as CFDictionary) else { return nil }
        let palette: SheetPalette = options.background == .black ? .blackPaper : .paper
        let date = Date().formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "en_GB")))
        var done = 0
        for page in 0..<pagination.pages {
            guard !Task.isCancelled else { return nil }
            let layout = pagination.layout(page)
            var renderer = ContactSheetRenderer(layout: layout, palette: palette, sidewaysVerticals: options.sidewaysVerticals,
                                                edgeLabel: model.lab.current?.roll.film ?? "")
            renderer.showsNumbers = options.numbers
            renderer.showsMarks = options.marks
            context.beginPDFPage(nil)
            // The renderer's sheet has its origin at the top left.
            context.translateBy(x: 0, y: options.page.height)
            context.scaleBy(x: 1, y: -1)
            renderer.drawSheet(context, in: box)
            if options.heading {
                let picks = frames.filter { $0.summary.flag == .pick }.count, rejects = frames.filter { $0.summary.flag == .reject }.count
                var counts = ["\(frames.count) frame\(frames.count > 1 ? "s" : "")"]
                if options.marks, picks > 0 { counts.append("\(picks) picked") }
                if options.marks, rejects > 0 { counts.append("\(rejects) rejected") }
                heading.counts = counts.joined(separator: " · ")
                renderer.drawHeading(context, heading, scale: 0.86)
            }
            let range = pagination.range(page)
            var contents: [(Int, SheetFrameContent)] = []
            for row in 0..<layout.rows { renderer.drawStrip(context, row: row) }
            for (slot, index) in range.enumerated() {
                let frame = frames[index]
                let edited = model.editedThumbnail(for: frame.file.url), file = frame.file
                let image = await Task.detached(priority: .userInitiated) {
                    await PhotoThumbnails.shared.image(for: file, size: .large, look: edited?.look, edited: edited?.store)
                }.value
                done += 1
                progress?(done, frames.count)
                let content = SheetFrameContent(name: frame.file.name, number: frame.number, image: image, flag: options.marks ? frame.summary.flag : nil,
                                                rating: frame.summary.rating, edited: frame.summary.edited, label: options.marks ? frame.summary.label : nil)
                renderer.drawFrame(context, index: slot, content)
                contents.append((slot, content))
            }
            for (slot, content) in contents { renderer.drawMark(context, index: slot, content) }
            let footerY = options.page.height - SheetPagination.margin + 4
            ContactSheetRenderer.draw("Qlick Lab  ·  \(date)", font: SheetFonts.text(7), color: palette.writingDim,
                                      at: CGPoint(x: layout.originX + 2, y: footerY), in: context)
            if pagination.pages > 1 {
                ContactSheetRenderer.draw("\(page + 1) / \(pagination.pages)", font: SheetFonts.text(7), color: palette.writingDim,
                                          at: CGPoint(x: layout.originX + layout.stripLength - 2, y: footerY), align: .right, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

// MARK: The dialog

struct SheetPrintDialog: View {
    let model: EditorModel
    @State private var options = SheetPrintOptions.load()
    @State private var document: PDFDocument?
    @State private var data: Data?
    @State private var progress: (done: Int, total: Int)?
    @State private var pages = 0
    @State private var frames = 0

    private var lab: LabState { model.lab }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(white: 0.16)
                if let document {
                    PDFPreview(document: document).padding(18)
                } else if frames == 0, progress == nil {
                    Text("No frames to print with this choice.").font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                }
                if let progress {
                    VStack(spacing: 8) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 180)
                        Text("Reading the frames… \(progress.done) / \(progress.total)").font(Theme.value(11)).foregroundStyle(Color(white: 0.8))
                    }
                    .padding(16).glass(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                }
            }
            .frame(width: 560, height: 620)

            VStack(alignment: .leading, spacing: 14) {
                Text("Printable Contact Sheet").font(Theme.title(16)).foregroundStyle(Theme.paper)
                Text(pages > 0 ? "\(frames) frame\(frames > 1 ? "s" : "") · \(pages) page\(pages > 1 ? "s" : "")" : " ").font(Theme.value(11.5)).foregroundStyle(Theme.dim)

                group("Paper") {
                    row("Format") {
                        Picker("", selection: $options.paper) { ForEach(SheetPrintOptions.Paper.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
                    }
                    row("Orientation") {
                        QSegmented(options: [(false, "Portrait", "Upright page"), (true, "Landscape", "Sideways page")], selection: $options.landscape)
                    }
                    row("Background") {
                        QSegmented(options: SheetPrintOptions.Background.allCases.map { ($0, $0.title, $0 == .black ? "The sheet as on screen: strips on black" : "Black strips on white paper: less ink") },
                                   selection: $options.background)
                    }
                }
                group("Sheet") {
                    row("Frames") {
                        Picker("", selection: $options.frames) { ForEach(SheetPrintOptions.Frames.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden()
                    }
                    row("Per strip") {
                        Stepper(value: $options.columns, in: SheetPrintOptions.columnRange) { Text("\(options.columns) frames").font(Theme.value(12)).foregroundStyle(Theme.paper) }
                    }
                    row("Strips") {
                        QSegmented(options: [(false, "Classic", "With file names"), (true, "Tight", "More frames a page")], selection: $options.compact)
                    }
                }
                group("Writing") {
                    Toggle("Red pencil marks", isOn: $options.marks)
                    Toggle("Frame numbers", isOn: $options.numbers)
                    Toggle("File names", isOn: $options.names).disabled(options.compact)
                    Toggle("Heading: folder, Archive, film, notes", isOn: $options.heading)
                    Toggle("Upright frames on their side", isOn: $options.sidewaysVerticals)
                }
                .toggleStyle(.checkbox).font(.system(size: 12))
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Cancel") { lab.printing = false }.buttonStyle(QPillButtonStyle()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("PDF…") { savePDF() }.buttonStyle(QPillButtonStyle()).disabled(data == nil)
                        .help("Save the Sheet as PDF")
                    Button("Print…") { printSheet() }.buttonStyle(QPrimaryButtonStyle()).disabled(document == nil).keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 330, height: 620, alignment: .topLeading)
            .background(Theme.panel)
        }
        .environment(\.colorScheme, .dark)
        .task(id: options) { await render() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel(title)
            content()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Color(white: 0.78)).frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func render() async {
        options.save()
        // A moment, so a run of changes makes one sheet.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let printer = SheetPrinter(model: model, options: options)
        let count = printer.frames.count
        frames = count
        pages = count == 0 ? 0 : SheetPagination(options: options, count: count, notes: !printer.heading.notes.isEmpty).pages
        guard count > 0 else { document = nil; data = nil; progress = nil; return }
        progress = (0, count)
        let made = await printer.pdf { done, total in progress = (done, total) }
        guard !Task.isCancelled else { return }
        progress = nil
        data = made
        document = made.flatMap(PDFDocument.init(data:))
    }

    private func savePDF() {
        guard let data else { return }
        let panel = NSSavePanel()
        panel.title = "Save the Contact Sheet"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = SheetPrinter(model: model, options: options).suggestedName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { MainActor.assumeIsolated { model.error = error.localizedDescription } }
            MainActor.assumeIsolated { lab.printing = false }
        }
    }

    private func printSheet() {
        guard let document else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = options.page
        info.orientation = options.landscape ? .landscape : .portrait
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit; info.verticalPagination = .fit
        guard let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false) else { return }
        operation.jobTitle = SheetPrinter(model: model, options: options).suggestedName
        lab.printing = false
        DispatchQueue.main.async {
            if let window = NSApp.mainWindow { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { operation.run() }
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(white: 0.16, alpha: 1)
        view.pageShadowsEnabled = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
