// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// Print, the lab's third part, beside the photograph as it will be printed: its colour (the output space, the
/// proof, what's out of gamut), its size and border, the contact sheet and the LUT, the exports under way, and the
/// export itself, whose panel holds the file's format, quality and size.
struct PrintPanel: View {
    let model: EditorModel

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
                    if model.source != nil {
                        PrintColourSection(model: model)
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
            ExportFoot(model: model)
        }
        .disabled(!model.hasCatalog)
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

/// The print's colour: the output colour space (the one place it's chosen; each print format carries its own), its
/// curve, the proof, the colours out of the space, and where the photograph's colours lie.
struct PrintColourSection: View {
    let model: EditorModel
    private var lab: LabState { model.lab }

    var body: some View {
        let space = model.previewSpace
        InkSection(title: "Colour", edited: InspectorEdits.outputCount(model) > 0) {
            ChoiceRow(title: "Colour space", items: SaveSettings.colorSpaces.map { .option($0, tag: $0) }, selection: space,
                      changed: space != SaveSettings.colorSpaces[0],
                      help: "The space the print is made in, with its ICC profile. The preview develops in it.",
                      choose: model.choosePreviewSpace)
            TickRow(title: "Encode with the colour space’s curve", isOn: model.toggle("io.output_cctf_encoding"),
                    changed: model.isModified("io.output_cctf_encoding"), help: "Off writes linear values, for further processing.")
            TickRow(title: "Proof", isOn: Binding(get: { model.proofing }, set: { model.proofing = $0 }), changed: !model.proofing,
                    help: "The preview develops in the output colour space itself, so it shows only what a print in it holds.")
            HintText(model.proofing
                     ? "The preview is the print in \(space): every colour shown is one the file holds."
                     : "The preview develops in ProPhoto RGB, as wide as the screen shows: not what a print in \(space) holds.")
            TickRow(title: "Show out-of-gamut", isOn: Binding(get: { lab.showGamut }, set: { lab.showGamut = $0 }), changed: lab.showGamut,
                    help: "Marks in cyan the colours \(space) can't hold, which the print's gamut compression brings inside it.")
            if lab.showGamut {
                if let check = lab.gamutCheck {
                    HintText(check.fraction < 0.0005 ? "Every colour fits in \(space)."
                             : "\(Self.percent(check.fraction)) of the photograph is out of \(space), marked in cyan\(model.border.enabled ? " (on the photograph without its border, fitted)" : " (fitted)").")
                } else {
                    HintText("Checking the colours…")
                }
            }
            GamutDiagram(space: space, cloud: lab.gamutCheck?.cloud ?? [])
                .frame(maxWidth: 220).frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Size.gutter).padding(.vertical, 6)
            HintText("The visible colours, \(space) (white), the screen’s Display P3 (dashed), and the photograph’s colours.")
        }
        // The check: another develop of the photograph, in ProPhoto RGB, by the Lab's second helper, a moment after
        // each new preview (an edit, another space). The cloud is taken from it too.
        .task(id: "\(model.sourceItem?.path ?? "")|\(model.image.map { ObjectIdentifier($0).hashValue } ?? 0)|\(space)|\(lab.showGamut)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await lab.checkGamut()
        }
    }

    static func percent(_ fraction: Double) -> String {
        fraction < 0.01 ? "Less than 1 %" : "\(Int((fraction * 100).rounded())) %"
    }
}

extension LabState {
    /// With Show out-of-gamut: develops the open photograph in ProPhoto RGB at 900 pixels (`LabDeveloper`, never the
    /// editor's helper) and checks it against the output space. Without: only the diagram's cloud, sampled on the
    /// preview itself.
    func checkGamut() async {
        guard let item = model.sourceItem, workspace == .print else { return }
        let space = model.previewSpace
        let check: Gamut.Check?
        if showGamut {
            let request = LabDeveloper.Request(item: item, longSide: 900, space: SaveSettings.colorSpaces[SaveSettings.prophoto])
            guard let image = await compareModel.developer.image(request) else { return }
            check = await Task.detached(priority: .userInitiated) { Gamut.check(image, against: space, marking: true) }.value
        } else {
            guard let surface = model.image else { return }
            let preview = Gamut.picture(surface, longSide: 400)
            check = await Task.detached(priority: .userInitiated) { preview.map { Gamut.Check(marks: nil, fraction: 0, cloud: Gamut.cloud($0)) } }.value
        }
        guard model.sourceItem == item, model.previewSpace == space else { return }
        gamutCheck = check
    }
}
