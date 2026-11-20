// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// A print format the photographer keeps: the file's format, quality, colour space and size, chosen in one click
/// before an export ("Web", "Archive TIFF"). Applying it sets what the export offers first.
struct PrintFormat: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var format: String
    var quality: Int
    var colorSpace: String
    /// 8 or 16 for PNG and TIFF; nil for JPEG and HEIF.
    var bitDepth: Int?
    var edge: String
    var pixels: Int

    var output: OutputFormat { OutputFormat(rawValue: format) ?? .jpeg }
    var size: ExportSize { ExportSize(edge: ExportSize.Edge(rawValue: edge) ?? .full, pixels: pixels) }
    var spaceIndex: Int { SaveSettings.colorSpaces.firstIndex(of: colorSpace) ?? 0 }

    static let key = "qlick.printFormats"

    /// The three a lab starts with.
    static let first: [PrintFormat] = [
        PrintFormat(name: "Web", format: OutputFormat.jpeg.rawValue, quality: 90, colorSpace: "sRGB", bitDepth: nil, edge: ExportSize.Edge.long.rawValue, pixels: 2048),
        PrintFormat(name: "Full Size JPEG", format: OutputFormat.jpeg.rawValue, quality: 95, colorSpace: "sRGB", bitDepth: nil, edge: ExportSize.Edge.full.rawValue, pixels: 2048),
        PrintFormat(name: "Archive TIFF", format: OutputFormat.tiff.rawValue, quality: 95, colorSpace: "Adobe RGB (1998)", bitDepth: 16, edge: ExportSize.Edge.full.rawValue, pixels: 2048),
    ]

    static func load(_ defaults: UserDefaults = .standard) -> [PrintFormat] {
        guard let data = defaults.data(forKey: key), let formats = try? JSONDecoder().decode([PrintFormat].self, from: data) else { return first }
        return formats
    }
    static func save(_ formats: [PrintFormat], _ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(formats) { defaults.set(data, forKey: key) }
    }

    /// What the export offers now, as a format named `name`.
    static func current(named name: String) -> PrintFormat {
        let output = OutputFormat.last, size = ExportSize.last
        let depth: Int? = output == .png || output == .tiff ? SaveSettings.bitDepth(for: output) : nil
        return PrintFormat(name: name, format: output.rawValue, quality: SaveSettings.lastQuality,
                           colorSpace: SaveSettings.colorSpaces[min(max(SaveSettings.chosenSpace, 0), SaveSettings.colorSpaces.count - 1)],
                           bitDepth: depth, edge: size.edge.rawValue, pixels: size.pixels)
    }

    /// Makes it what the export offers first.
    func apply() {
        OutputFormat.last = output
        SaveSettings.lastQuality = quality
        SaveSettings.chosenSpace = spaceIndex
        if let bitDepth { SaveSettings.setBitDepth(bitDepth, for: output) }
        ExportSize.last = size
    }

    /// Whether the export offers this now.
    var isCurrent: Bool { Self.current(named: name).sameSettings(as: self) }

    func sameSettings(as other: PrintFormat) -> Bool {
        let lossy = output == .jpeg || output == .heif
        return format == other.format && colorSpace == other.colorSpace && edge == other.edge
            && (edge == ExportSize.Edge.full.rawValue || pixels == other.pixels)
            && (!lossy || quality == other.quality) && (lossy || bitDepth == other.bitDepth)
    }

    /// "JPEG 90 · sRGB · 2048 px long edge".
    var summary: String {
        let kind = switch output {
        case .jpeg: "JPEG \(quality)"
        case .heif: "HEIF \(quality)"
        case .png: "PNG \(bitDepth ?? 8)-bit"
        case .tiff: "TIFF \(bitDepth ?? 16)-bit"
        }
        let fit = size.edge == .full ? "full size" : "\(pixels) px \(size.edge == .long ? "long" : "short") edge"
        return [kind, colorSpace, fit].joined(separator: " · ")
    }
}

/// Print, the lab's third part, beside the photograph as it will be printed: the print format, the print's size
/// and border, the contact sheet and the LUT, the exports under way, and the export itself.
struct PrintPanel: View {
    let model: EditorModel
    @State private var formats = PrintFormat.load()
    @State private var naming = false
    @State private var name = ""
    /// Moves when a format is applied, so the rows read the export's settings again.
    @State private var applied = 0

    var body: some View {
        let count = model.exportsSingle ? (model.source == nil ? 0 : 1) : model.exportTargets.count
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                CapsLabel("Print", color: Theme.paper)
                Spacer()
                Text(count == 0 ? "No photograph" : count == 1 ? "1 photograph" : "\(count) photographs").font(Theme.value(12)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, Theme.Size.gutter).frame(height: Theme.Size.paneHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    formatsSection
                    if model.source != nil {
                        ImageSizeSection(model: model)
                        PrintFrameSection(model: model)
                    } else {
                        HintText("Open a photograph in the Lab, or choose frames on the contact sheet: their size and border are set here.")
                            .padding(.top, 12)
                    }
                    InkSection(title: "The lab’s other prints") {
                        ButtonRow {
                            Text("The contact sheet, on paper").font(Theme.serif(14.5)).foregroundStyle(Theme.label)
                        } button: {
                            Button("Print Contact Sheet…") { model.lab.printing = true }.buttonStyle(OutlinedButtonStyle())
                                .inkDisabled(model.library.files.isEmpty)
                        }
                        ButtonRow {
                            Text("The development as a LUT").font(Theme.serif(14.5)).foregroundStyle(Theme.label)
                        } button: {
                            Button("Export LUT…", action: model.exportLUTPanel).buttonStyle(OutlinedButtonStyle())
                                .inkDisabled(!model.canExportLUT || model.source == nil)
                        }
                    }
                    if let run = model.batch {
                        InkSection(title: "Exports") {
                            BatchProgressView(run: run, retry: model.retryBatch, showInFinder: model.showBatchInFinder)
                                .padding(.horizontal, Theme.Size.gutter).padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            ExportFoot(model: model).id(applied)
        }
        .disabled(!model.hasCatalog)
    }

    @ViewBuilder private var formatsSection: some View {
        InkSection(title: "Print format") {
            ForEach(formats) { format in
                PrintFormatRow(format: format, chosen: format.isCurrent) {
                    format.apply(); applied += 1
                } remove: {
                    formats.removeAll { $0.id == format.id }; PrintFormat.save(formats)
                }
                .id("\(format.id)-\(applied)")
            }
            if naming {
                ButtonRow {
                    TextField("Name of the format", text: $name)
                        .textFieldStyle(.plain).font(Theme.serif(14.5)).foregroundStyle(Theme.paper)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.07)))
                        .onSubmit(saveFormat)
                } button: {
                    Button("Keep", action: saveFormat).buttonStyle(OutlinedButtonStyle())
                        .inkDisabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                ButtonRow {
                    Text(formats.contains(where: \.isCurrent) ? "" : PrintFormat.current(named: "").summary)
                        .font(Theme.serif(13, italic: true)).foregroundStyle(Theme.dim).lineLimit(1)
                } button: {
                    Button("Keep as a Format…") { name = ""; naming = true }.buttonStyle(OutlinedButtonStyle())
                        .inkDisabled(formats.contains(where: \.isCurrent))
                }
            }
            HintText("The export offers the format chosen first: its file, colour space and size. The save panel can still change them.")
        }
    }

    private func saveFormat() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        formats.append(PrintFormat.current(named: trimmed))
        PrintFormat.save(formats)
        naming = false
    }
}

/// One print format: its name and what it makes; the chosen one marked in red.
private struct PrintFormatRow: View {
    let format: PrintFormat
    let chosen: Bool
    let choose: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Circle().strokeBorder(chosen ? Theme.accent : Theme.track, lineWidth: 1.5)
                    .overlay { if chosen { Circle().fill(Theme.accent).padding(3.5) } }
                    .frame(width: 13, height: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(format.name).font(Theme.serif(14.5, weight: chosen ? 600 : 400)).foregroundStyle(chosen ? Theme.paper : Theme.label)
                    Text(format.summary).font(Theme.value(11)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Size.gutter).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu { Button("Remove the Format “\(format.name)”", action: remove) }
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .help("Export as \(format.summary)")
    }
}

/// The print's frame: the border (mat, keyline or film frame), the 3:4 portrait extension, and whether exports carry it.
struct PrintFrameSection: View {
    let model: EditorModel

    /// The size and frame of the finished print. Tone and colour edits live in the Lab, before the film, where
    /// nothing has clipped yet.
    var body: some View {
        InkSection(title: "Border", edited: model.border.enabled) {
            TickRow(title: "Add border", isOn: model.border(\.enabled), changed: model.border.enabled,
                    help: "Frames the photograph in a mat or a film frame. The preview always shows it; Include in export decides whether files get it.")
            Group {
                let photo = model.photoSize == .zero ? nil : model.photoSize
                BorderStylePicker(selection: model.border(\.style), photo: photo, colors: (model.border.color, model.border.lineColor))
                    .padding(.horizontal, Theme.Size.gutter).padding(.vertical, 6)
                if let photo, !BorderStyle.film35.fits(photo) {
                    HintText("35mm needs a 3:2 or 3:4 photograph. This one is \(Self.ratio(photo)); crop it to 3:2 or 4:3 to use it.")
                }
                borderControls
                TickRow(title: "Extend to 3:4 portrait", isOn: model.border(\.instagram), changed: model.border.instagram != BorderSettings().instagram,
                        help: "Adds white above and below, or at the sides, so the whole photograph fits a 3:4 portrait frame.")
                TickRow(title: "Include in export", isOn: model.border(\.export), changed: model.border.export != BorderSettings().export,
                        help: "Adds the border to exported photographs and saved previews.")
            }
            .inkDisabled(!model.border.enabled)
        }
    }

    /// The chosen style's width and colours. Solid and Keyline share the
    /// mat; the film frame's width adds black around it.
    @ViewBuilder private var borderControls: some View {
        switch model.border.style {
        case .solid, .keyline:
            let keyline = model.border.style == .keyline
            borderSlider("Width", \.width, 0...15, step: 0.1, help: "The mat’s width, in percent of the photograph’s long edge.")
            if keyline { borderSlider("Line width", \.line, 0.05...2, step: 0.05, help: "The line’s width, in percent of the photograph’s long edge.") }
            ColourWellRow(title: "Color", color: model.borderColor(\.color), help: "The mat’s colour.")
            if keyline { ColourWellRow(title: "Line color", color: model.borderColor(\.lineColor), help: "The line’s colour.") }
        case .film:
            borderSlider("Width", \.filmWidth, 0...15, step: 0.1, help: "Adds black around the film frame, in percent of the photograph’s long edge.")
        case .film35:
            EmptyView()
        }
    }

    /// A border width in percent of the photograph's long edge.
    private func borderSlider(_ title: String, _ setting: WritableKeyPath<BorderSettings, Double>, _ range: ClosedRange<Double>, step: Double,
                              help: String) -> some View {
        let initial = BorderSettings()[keyPath: setting]
        return LabeledSlider(title: title, value: model.borderPercent(setting, range: range, step: step), range: range, step: step, unit: "%",
                             defaultValue: initial * 100, modified: abs(model.border[keyPath: setting] - initial) > 1e-9,
                             reset: { model.border(setting).wrappedValue = initial },
                             editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change Border") },
                             help: help)
    }


    /// A photograph's aspect ratio as people name it, such as 16:9.
    static func ratio(_ size: CGSize) -> String {
        let ratio = max(size.width, size.height) / min(size.width, size.height)
        let named = [(1.0, "1:1"), (5.0 / 4, "5:4"), (7.0 / 5, "7:5"), (16.0 / 9, "16:9"), (2.0, "2:1"), (21.0 / 9, "21:9")]
        if let (_, name) = named.first(where: { abs(ratio / $0.0 - 1) <= 0.01 }) { return name }
        return String(format: "%.2f:1", Double(ratio))
    }
}
