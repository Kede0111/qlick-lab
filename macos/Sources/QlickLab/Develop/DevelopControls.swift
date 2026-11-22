// Qlick Lab — GPL-3.0-only.
import AppKit
import CoreImage
import ImageIO
import simd
import SwiftUI

// What the lab adds to the Develop panel: the film and paper chosen in the panel itself, the white balance with its
// temperature and tint always at hand, the grain and the anti-halation layer as a photographer names them, and the
// curve where it is looked for. The engine's parameters are spektrafilm's; these are other handles on them.

extension EditorModel {
    /// Qlick Lab: no film: the image is taken as it is (the engine's `io.no_film`).
    static let noFilmPath = "io.no_film"

    /// Several parameters in one edit, one undo and one develop.
    func setParams(_ values: [(String, JSONValue)]) {
        var next = state
        for (path, value) in values { next.params[path] = value }
        guard next != state else { return }
        labApplyState(next)
    }

    /// A grain field of the film as a multiple of the stock's own, from its first lane.
    func stockScale(_ path: String) -> Double {
        let preset = stockDefaults(path)
        let saved = value(path).array.map(\.double)
        guard let own = preset.first, own > 0, let now = (saved.isEmpty ? preset : saved).first else { return 1 }
        return now / own
    }

    /// Every lane of a grain field at `factor` times the stock's own; back at 1, the film's preset applies again.
    func setStockScale(_ path: String, _ factor: Double, limits: ClosedRange<Double>) {
        let preset = stockDefaults(path)
        guard !preset.isEmpty else { return }
        let values = preset.map { min(max($0 * factor, limits.lowerBound), limits.upperBound) }
        set(path, abs(factor - 1) < 1e-6 ? .null : .array(values.map(JSONValue.number)))
    }
}

// MARK: White balance

/// The engine's custom white balance, as `crates/spektrafilm-io/src/white_balance.rs` applies it after a Daylight
/// (D65) read: a CAT02 adaptation from the temperature's white point, and a green scale in ACES2065-1 for the tint.
/// Ported so the panel can say which temperature and tint the camera's own balance comes to, and find the pair that
/// makes a given colour neutral (Auto).
enum WhiteBalanceMath {
    typealias M = simd_double3x3
    static let cat02 = M(rows: [.init(0.7328, 0.4296, -0.1624), .init(-0.7036, 1.6975, 0.0061), .init(0.0030, 0.0136, 0.9834)])
    static let srgbToXYZ = M(rows: [.init(0.4124, 0.3576, 0.1805), .init(0.2126, 0.7152, 0.0722), .init(0.0193, 0.1192, 0.9505)])
    static let acesToXYZ = M(rows: [.init(0.9525523959, 0, 0.0000936786), .init(0.3439664498, 0.7281660966, -0.0721325464), .init(0, 0, 1.0088251844)])
    static let d65 = xyz(x: 0.3127, y: 0.3290), d60 = xyz(x: 0.32168, y: 0.33767)

    static func xyz(x: Double, y: Double) -> SIMD3<Double> { .init(x / y, 1, (1 - x - y) / y) }

    /// CIE daylight locus from 4000 K, Kang's Planckian locus under it, as the engine.
    static func whitepoint(_ t: Double) -> SIMD3<Double> {
        let x: Double
        if t >= 4000 {
            x = t <= 7000 ? -4.607e9 / pow(t, 3) + 2.9678e6 / pow(t, 2) + 99.11 / t + 0.244063
                : -2.0064e9 / pow(t, 3) + 1.9018e6 / pow(t, 2) + 247.48 / t + 0.237040
        } else {
            x = -0.2661239e9 / pow(t, 3) - 0.2343589e6 / pow(t, 2) + 0.8776956e3 / t + 0.179910
        }
        let y: Double
        if t >= 4000 { y = -3 * x * x + 2.87 * x - 0.275 }
        else if t <= 2222 { y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2) + 2.18555832 * x - 0.20219683 }
        else { y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2) + 2.09137015 * x - 0.16748867 }
        return xyz(x: x, y: y)
    }

    static func adaptation(_ source: SIMD3<Double>, _ target: SIMD3<Double>) -> M {
        let s = cat02 * source, t = cat02 * target
        return cat02.inverse * M(diagonal: t / s) * cat02
    }

    /// Linear sRGB of a Daylight read to linear sRGB at `temperature` and `tint`.
    static func matrix(temperature: Double, tint: Double) -> M {
        let toACES = adaptation(d65, d60)
        let tintXYZ = acesToXYZ * M(diagonal: .init(1, tint, 1)) * acesToXYZ.inverse
        return srgbToXYZ.inverse * toACES.inverse * tintXYZ * adaptation(whitepoint(temperature), whitepoint(6504)) * toACES * srgbToXYZ
    }

    static let temperatures = 1667.0...25000.0

    /// The temperature and tint that make `colour` (linear sRGB of a Daylight read) neutral.
    static func neutralising(_ colour: SIMD3<Double>) -> (temperature: Double, tint: Double)? {
        guard colour.x > 0, colour.y > 0, colour.z > 0 else { return nil }
        let toACES = adaptation(d65, d60)
        // What neutral sRGB is in the ACES coordinates the tint scales.
        let neutral = acesToXYZ.inverse * toACES * srgbToXYZ * SIMD3<Double>(1, 1, 1)
        func aces(_ t: Double) -> SIMD3<Double> {
            acesToXYZ.inverse * adaptation(whitepoint(t), whitepoint(6504)) * toACES * srgbToXYZ * colour
        }
        // Red against blue falls as the temperature rises... or rises: find the side by the ends.
        func balance(_ t: Double) -> Double { let u = aces(t); return u.x / neutral.x - u.z / neutral.z }
        var low = temperatures.lowerBound, high = temperatures.upperBound
        let atLow = balance(low), atHigh = balance(high)
        guard atLow.isFinite, atHigh.isFinite else { return nil }
        if atLow * atHigh > 0 { return nil }
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if balance(middle) * atLow > 0 { low = middle } else { high = middle }
        }
        let t = (low + high) / 2, u = aces(t)
        let tint = (u.x / neutral.x) * neutral.y / u.y
        guard tint.isFinite, tint > 0.05, tint < 4 else { return nil }
        return (t, tint)
    }

    /// The camera's own balance as the engine's temperature and tint: the neutral the RAW records, as Core Image
    /// reads it (the engine's decoder on a Mac), seen in a Daylight read.
    nonisolated static func asShot(of url: URL) -> (temperature: Double, tint: Double)? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let neutral = filter.neutralChromaticity
        guard neutral.x > 0, neutral.y > 0 else { return nil }
        return neutralising(srgbToXYZ.inverse * xyz(x: neutral.x, y: neutral.y))
    }

    /// Auto: the balance that makes the photograph's middle tones grey on average, from the camera's own preview
    /// (balanced as shot), so it costs no develop.
    nonisolated static func auto(of url: URL, asShot: (temperature: Double, tint: Double)) -> (temperature: Double, tint: Double)? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func linear(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var sum = SIMD3<Double>(repeating: 0), count = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let c = SIMD3<Double>(linear(pixels[index]), linear(pixels[index + 1]), linear(pixels[index + 2]))
            let luminance = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            // Middle tones, and not the strongly coloured: a red wall isn't the light's colour.
            let spread = (c.max() - c.min()) / max(c.max(), 1e-6)
            guard luminance > 0.03, luminance < 0.7, spread < 0.6 else { continue }
            let weight = 1 - spread
            sum += c * weight; count += weight
        }
        guard count > 50 else { return nil }
        // That average as a Daylight read shows it, then the pair that makes it neutral.
        let seen = matrix(temperature: asShot.temperature, tint: asShot.tint).inverse * (sum / count)
        return neutralising(seen)
    }

    /// The panel's tint, −100 (green) to +100 (magenta), and the engine's green scale: ±100 is about ±15 % of green,
    /// as far as ±150; the engine's own 0…4 range is far past any photograph's need.
    static func tintValue(_ scale: Double) -> Double { -500 * log2(max(scale, 0.01)) + 0 }
    static func tintScale(_ value: Double) -> Double { pow(2, -value / 500) }
}

/// The camera's balance of the photographs looked at, read once each.
@MainActor @Observable final class AsShotBalances {
    private(set) var values: [URL: (temperature: Double, tint: Double)] = [:]
    @ObservationIgnored private var asked: Set<URL> = []

    /// Auto's balance in the engine's terms, once it has prepared the photograph's balance.
    private(set) var autos: [URL: (temperature: Double, tint: Double)] = [:]
    /// The engine's own answer (`prepare_balance`): what it renders As Shot as, which the decoder's guess only nears.
    func set(_ url: URL, _ pair: (temperature: Double, tint: Double), auto: (temperature: Double, tint: Double)?) {
        values[url] = pair; asked.insert(url)
        if let auto { autos[url] = auto }
    }

    func get(_ url: URL) -> (temperature: Double, tint: Double)? {
        if let known = values[url] { return known }
        guard asked.insert(url).inserted else { return nil }
        Task {
            let found = await Task.detached(priority: .userInitiated) { WhiteBalanceMath.asShot(of: url) }.value
            if let found { values[url] = found }
        }
        return nil
    }
}

/// White balance: the preset, and the temperature and tint under it, always. Moving either makes the balance Custom,
/// starting from what was shown.
struct WhiteBalanceSection: View {
    let model: EditorModel
    @State private var autoBusy = false

    static let mode = "io.raw_white_balance.mode", temperature = "io.raw_white_balance.temperature", tint = "io.raw_white_balance.tint"
    static let shownTemperatures = 2000.0...12000.0

    /// What the sliders show: the custom pair, or what the preset comes to.
    private var shown: (temperature: Double, tint: Double) {
        switch model.value(Self.mode).string {
        case "custom": (model.value(Self.temperature).double, model.value(Self.tint).double)
        case "daylight": (6504, 1)
        case "tungsten": (2850, 1)
        default: model.source.flatMap { model.lab.asShot.get($0) } ?? (5500, 1)
        }
    }

    var body: some View {
        let mode = model.value(Self.mode).string
        let edited = InspectorEdits.whiteBalancePaths.contains(where: model.isModified)
        let shown = shown
        InkSection(title: "White Balance", edited: edited) {
            HStack(spacing: 6) {
            ChoiceRow(title: "Preset", items: [.option("As Shot", tag: "as_shot"), .option(autoBusy ? "Auto…" : "Auto", tag: "auto"), .divider,
                                               .option("Daylight", tag: "daylight"), .option("Tungsten", tag: "tungsten"), .divider,
                                               .option("Custom", tag: "custom")],
                      selection: mode.isEmpty ? "as_shot" : mode, changed: model.isModified(Self.mode),
                      help: "As Shot is the camera's own balance. Auto makes the photograph's middle tones neutral. Moving Temperature or Tint makes it Custom.") { tag in
                switch tag {
                case "auto": auto()
                case "custom": set(temperature: shown.temperature, tint: shown.tint)
                default: model.set(Self.mode, .string(tag))
                }
            }
                // The eyedropper: a click on a white or a grey in the photograph balances it there.
                Button { model.lab.pickingWhite.toggle() } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(model.lab.pickingWhite ? Color.white : Theme.dim)
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(model.lab.pickingWhite ? Theme.accent.opacity(0.9) : Color.white.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!model.isRaw || model.source == nil)
                .help("White balance picker (W): click a white or a light grey in the photograph")
                .padding(.trailing, Theme.Size.gutter - 6)
            }
            LabeledSlider(title: "Temperature", value: Binding(get: { min(max(shown.temperature, Self.shownTemperatures.lowerBound), Self.shownTemperatures.upperBound) },
                                                               set: { set(temperature: (($0 / 50).rounded() * 50), tint: shown.tint) }),
                          range: Self.shownTemperatures, step: 50, defaultValue: defaultPair.temperature,
                          modified: mode == "custom" && abs(shown.temperature - defaultPair.temperature) > 25, reset: reset,
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change White Balance") },
                          help: "Cooler to the left, warmer to the right, in kelvin: the colour of the light the photograph is balanced for.",
                          gradient: Self.temperatureColors)
            LabeledSlider(title: "Tint", value: Binding(get: { min(max(WhiteBalanceMath.tintValue(shown.tint), -100), 100).rounded() + 0 },
                                                        set: { set(temperature: shown.temperature, tint: WhiteBalanceMath.tintScale($0.rounded())) }),
                          range: -100...100, step: 1, defaultValue: WhiteBalanceMath.tintValue(defaultPair.tint).rounded(),
                          modified: mode == "custom" && abs(WhiteBalanceMath.tintValue(shown.tint) - WhiteBalanceMath.tintValue(defaultPair.tint)) > 0.5, reset: reset,
                          editing: { $0 ? model.beginInteraction() : model.endInteraction(action: "Change White Balance") },
                          help: "Towards green on the left, magenta on the right.",
                          gradient: Self.tintColors)
        }
    }

    /// As shot, where a reset goes back to.
    private var defaultPair: (temperature: Double, tint: Double) { model.source.flatMap { model.lab.asShot.get($0) } ?? (5500, 1) }

    private func set(temperature: Double, tint: Double) {
        model.setParams([(Self.mode, .string("custom")),
                         (Self.temperature, .number(min(max(temperature, WhiteBalanceMath.temperatures.lowerBound), WhiteBalanceMath.temperatures.upperBound))),
                         (Self.tint, .number(min(max(tint, 0.05), 4)))])
    }

    private func reset() { model.set(Self.mode, .string("as_shot")) }

    private func auto() {
        guard let source = model.source, !autoBusy else { return }
        // The engine's Auto, once it has the photograph's balance: it lands exactly where it says.
        if let found = model.lab.asShot.autos[source] { return set(temperature: (found.temperature / 10).rounded() * 10, tint: found.tint) }
        autoBusy = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> (temperature: Double, tint: Double)? in
                guard let asShot = WhiteBalanceMath.asShot(of: source) else { return nil }
                return WhiteBalanceMath.auto(of: source, asShot: asShot)
            }.value
            autoBusy = false
            guard model.source == source else { return }
            if let found { set(temperature: (found.temperature / 10).rounded() * 10, tint: found.tint) }
            else { model.error = "Auto white balance found nothing to go by in this photograph." }
        }
    }

    static let temperatureColors: [NSColor] = [NSColor(srgbRed: 0.25, green: 0.52, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.86, green: 0.88, blue: 0.9, alpha: 1),
                                               NSColor(srgbRed: 1.0, green: 0.74, blue: 0.2, alpha: 1)]
    static let tintColors: [NSColor] = [NSColor(srgbRed: 0.2, green: 0.8, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.86, green: 0.86, blue: 0.86, alpha: 1),
                                        NSColor(srgbRed: 0.92, green: 0.25, blue: 0.85, alpha: 1)]
}

// MARK: Film and paper

/// The film and the paper at the head of the panel, as QLab shows the film: its canister, its name, its speed and
/// kind. Each opens its stocks. The paper can be taken away: the film is then scanned as it is, with no print.
struct StockPicker: View {
    let model: EditorModel
    /// Qlick Lab: the card folded to one line (the film, the paper), to leave the column to the settings.
    @AppStorage("qlick.filmCardFolded") private var folded = false

    var body: some View {
        Group {
            if folded { foldedCard } else { card }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .padding(.horizontal, Theme.Size.gutter - 8)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.2), value: folded)
    }

    /// One line: the film and what it's printed on; a click opens the card again.
    private var foldedCard: some View {
        let scanning = model.value("io.scan_film").bool
        let noFilm = model.value(EditorModel.noFilmPath).bool
        return Button { folded = false } label: {
            HStack(spacing: 8) {
                Text(noFilm ? "No film" : model.filmName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.paper).lineLimit(1)
                Text(scanning ? "scanned" : "on \(model.paperName)").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 14).frame(height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Shows the film, the paper and the recipe")
        .accessibilityLabel("Film \(noFilm ? "none" : model.filmName), \(scanning ? "scanned" : "printed on \(model.paperName)")")
        .accessibilityHint("Opens the film card")
    }

    private var card: some View {
        let scanning = model.value("io.scan_film").bool
        let noFilm = model.value(EditorModel.noFilmPath).bool
        let film = model.films.first { $0.id == model.film }
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                if noFilm {
                    PickerRow(model: model, paper: false, caption: nil, name: "No film",
                              detail: scanning ? "The image as it is, with the effects" : "The image is printed as a negative", opens: false, canister: nil)
                } else {
                    PickerRow(model: model, paper: false, caption: nil, name: model.filmName, detail: film.map { Self.detail($0, name: model.filmName) },
                              opens: true, canister: film)
                }
                Button { model.toggle(EditorModel.noFilmPath).wrappedValue.toggle() } label: {
                    Image(systemName: noFilm ? "film" : "xmark.circle")
                        .font(.system(size: 12)).foregroundStyle(noFilm ? Theme.accent : Theme.dim)
                        .frame(width: 30, height: 56).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(noFilm ? "Use a film again" : "No film: take the image as it is, for a scanned negative or effects alone")
                Button { folded = true } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 24, height: 56).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Folds the film card to one line")
                .accessibilityLabel("Fold the film card")
                .padding(.trailing, 4)
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 0) {
                PickerRow(model: model, paper: true, caption: "Printed on", name: scanning ? "No paper: the film is scanned" : model.paperName,
                          detail: nil, opens: !scanning, canister: nil)
                Button { model.toggle("io.scan_film").wrappedValue.toggle() } label: {
                    Image(systemName: scanning ? "doc.badge.plus" : "xmark.circle")
                        .font(.system(size: 12)).foregroundStyle(scanning ? Theme.accent : Theme.dim)
                        .frame(width: 30, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(scanning ? "Print on a paper again" : "No paper: scan the developed film directly, its colours and effects without a print")
                .padding(.trailing, 4)
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 12)
            PresetRow(model: model)
        }
    }

    static func kind(_ stock: Stock) -> String {
        stock.bw ? "Black & white negative" : stock.positive ? "Colour slide" : "Colour negative"
    }

    /// "ISO 400 · Colour negative", the speed read from the film's name.
    static func detail(_ stock: Stock, name: String) -> String {
        let speed = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first { [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1600, 3200].contains($0) }
        return ([speed.map { "ISO \($0)" }, kind(stock)].compactMap { $0 }).joined(separator: " · ")
    }
}

/// A 35 mm canister, drawn: the film's kind in its colour (yellow for colour negative, blue for slide, grey for
/// black and white).
struct Canister: View {
    let stock: Stock
    var body: some View {
        let body: Color = stock.bw ? Color(white: 0.55) : stock.positive ? Color(red: 0.2, green: 0.45, blue: 0.85) : Color(red: 0.98, green: 0.74, blue: 0.12)
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(white: 0.12)).frame(width: 26, height: 5).offset(y: -17)
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color(white: 0.12)).frame(width: 26, height: 5).offset(y: 17)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(LinearGradient(colors: [body.opacity(0.75), body, body.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 24, height: 32)
            Rectangle().fill(Color.black.opacity(0.75)).frame(width: 24, height: 6).offset(y: 6)
            RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.15)).frame(width: 6, height: 7).offset(x: 13, y: -10)
        }
        .frame(width: 34, height: 40)
        .accessibilityHidden(true)
    }
}

private struct PickerRow: View {
    let model: EditorModel
    let paper: Bool
    let caption: String?
    let name: String
    let detail: String?
    let opens: Bool
    let canister: Stock?
    @State private var hovered = false
    @State private var anchor = MenuAnchor()

    var body: some View {
        HStack(spacing: 11) {
            if let canister { Canister(stock: canister) }
            if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize() }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: paper ? 12 : 15, weight: paper ? .medium : .semibold)).foregroundStyle(paper ? Color(white: 0.85) : Color.white).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Color(white: 0.6)).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if opens { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(hovered ? Theme.paper : Theme.dim) }
        }
        .padding(.horizontal, 12)
        .frame(height: paper ? 34 : 56)
        .background(Color.white.opacity(hovered && opens ? 0.04 : 0))
        .background(AnchorView(anchor: anchor))
        .background(TrayHitArea(model: model))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { if opens { open() } }
        .help(opens ? (paper ? ControlHelp.paper : ControlHelp.film) : name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(paper ? "Paper" : "Film"): \(name)")
        .accessibilityAddTraits(opens ? .isButton : [])
        .accessibilityAction { if opens { open() } }
    }

    private func open() {
        // With the preview tiles, the tray under the photograph; else the plain menu.
        if model.previews.enabled { model.toggleTray(paper: paper); return }
        let stocks = paper ? model.listedPapers : model.listedFilms
        let favorites = model.previews.favorites(in: stocks, paper: paper)
        var items: [ChoiceItem] = []
        if !favorites.isEmpty {
            items.append(.header("Favourites"))
            items += favorites.map { .option($0.name, tag: StockMenu.favoriteID($0.id)) }
        }
        for group in paper ? model.paperGroups : model.filmGroups {
            items.append(.header(group.title))
            items += group.stocks.map { .option($0.name, tag: $0.id) }
        }
        popUpChoiceMenu(items, selected: paper ? model.paper : model.film, under: anchor.view) { tag in
            let id = StockMenu.stockID(tag: tag)
            if paper { model.choosePaper(id) } else { model.chooseFilm(id) }
        }
    }
}

// MARK: Grain and halation

/// The grain in two sliders, before its emulsion-by-emulsion detail: how much of it, and how large.
struct GrainSimpleRows: View {
    let model: EditorModel
    static let amount = "film_render.grain.rms_granularity", size = "film_render.grain.particle_scale_sublayers"
    /// Qlick Lab: colourless grain on a colour film.
    static let monochrome = "film_render.grain.luminance_only"

    var body: some View {
        SectionPresetRow(model: model, section: .grain)
        row("Amount", Self.amount, limits: 0...80, range: 0...600, help: "How strong the grain is, in percent of the film's own. 100 is the film as it is.")
        row("Size", Self.size, limits: 0.05...2, range: 0...300, help: "How large the grains are, in percent of the film's own. Larger grain reads as a faster film.")
        if !model.filmIsBW {
            TickRow(title: "Monochrome", isOn: model.toggle(Self.monochrome), changed: model.isModified(Self.monochrome),
                    help: "Colourless grain, as on black and white film.")
        }
    }

    private func row(_ title: String, _ path: String, limits: ClosedRange<Double>, range: ClosedRange<Double>, help: String) -> some View {
        let percent = (model.stockScale(path) * 100).rounded()
        return LabeledSlider(title: title, value: Binding(get: { percent }, set: { model.setStockScale(path, $0.rounded() / 100, limits: limits) }),
                             range: range, step: 1, unit: "%", defaultValue: 100, modified: abs(percent - 100) > 0.5,
                             reset: { model.set(path, .null) },
                             editing: { $0 ? model.beginInteraction() : model.endInteraction() }, help: help)
    }
}

/// Halation's own rows: its presets, the anti-halation layer, and Show mask.
struct HalationRows: View {
    let model: EditorModel

    var body: some View {
        SectionPresetRow(model: model, section: .halation)
        AntiHalationRow(model: model)
        TickRow(title: "Show mask", isOn: Binding(get: { model.halationMask }, set: { model.halationMask = $0 }), changed: model.halationMask,
                help: "Shows where the halation falls, on black: the brighter, the more it lights that part of the photograph. Only on screen: never saved or exported.")
    }
}

/// The anti-halation layer, as it is spoken of: the film's own, a weak one, or none (as on a film sold without it).
/// It sets Halation's Amount, which stays under it for anything between.
struct AntiHalationRow: View {
    let model: EditorModel
    static let strength = "film_render.halation.halation_strength", active = "film_render.halation.active"
    static let amount = "film_render.halation.halation_amount"
    /// The light bounced back into the emulsion, red, green and blue, behind each kind of layer (the engine's
    /// `halation_preset`). Nil is the film's own.
    static let levels: [(tag: String, title: String, strength: [Double]?)] = [
        ("film", "As the film", nil), ("strong", "Strong", [0.015, 0.005, 0]), ("weak", "Weak", [0.08, 0.02, 0]),
        ("removed", "Removed", [0.30, 0.10, 0.015]),
    ]

    var body: some View {
        let value = model.value(Self.strength)
        let set = value.array.map(\.double)
        let level = value == .null ? Self.levels[0]
            : Self.levels.dropFirst().first { level in level.strength.map { zip($0, set).allSatisfy { abs($0 - $1) < 0.0005 } && set.count == 3 } ?? false }
        let own = model.films.first { $0.id == model.film }?.antihalation ?? ""
        let word = ["strong": "strong", "weak": "weak", "no": "none"][own].map { " (\($0))" } ?? ""
        ChoiceRow(title: "Anti-halation layer",
                  items: Self.levels.map { .option($0.tag == "film" ? $0.title + word : $0.title, tag: $0.tag) } + (level == nil ? [.divider, .option("Custom", tag: "custom")] : []),
                  selection: level?.tag ?? "custom", changed: model.isModified(Self.strength),
                  help: "The layer on the back of the film that stops light bouncing back into the emulsion. Weak, a red glow shows round bright lights; removed, as on films sold without it, the glow is strong and wide. Amount scales it.") { tag in
            guard let chosen = Self.levels.first(where: { $0.tag == tag }) else { return }
            model.setParams([(Self.strength, chosen.strength.map { .array($0.map { .number($0) }) } ?? .null), (Self.active, .bool(true))])
        }
    }
}

// MARK: Curve

/// The curve, at the foot of Develop: the print's tone graph (drag it, or its handles) and the film's own contrast.
struct CurveSection: View {
    let model: EditorModel
    static let filmGamma = "film_render.density_curves_morph.gamma_factor", filmActive = "film_render.density_curves_morph.active"

    var body: some View {
        let scanning = model.value("io.scan_film").bool
        let edited = [ToneGraphPaths.gamma, ToneGraphPaths.fast, ToneGraphPaths.slow, Self.filmGamma].contains(where: model.isModified)
        InkSection(title: "Curve", edited: edited) {
            if !scanning {
                ToneGraphView(model: model).padding(.horizontal, Theme.Size.gutter).padding(.vertical, 6)
            }
            let on = model.value(Self.filmActive).bool
            if !model.value(EditorModel.noFilmPath).bool {
                LabeledSlider(title: "Film contrast", value: Binding(get: { on ? model.value(Self.filmGamma).double : 1 },
                                                                     set: { model.setParams([(Self.filmActive, .bool(true)), (Self.filmGamma, .number(EditorModel.snap($0, to: 0.5...2, step: 0.01)))]) }),
                              range: 0.5...2, step: 0.01, defaultValue: 1, modified: on && model.isModified(Self.filmGamma),
                              reset: { model.resetValue(Self.filmGamma) },
                              editing: { $0 ? model.beginInteraction() : model.endInteraction() },
                              help: ControlHelp.text(Self.filmGamma))
            }
            if !scanning {
                SliderRow(model: model, title: "Print exposure", path: ToneGraphPaths.printExposure, range: ToneGraphPaths.exposureRange, step: 0.01)
            }
        }
    }
}

// MARK: Effects

/// What is added on top of the film, as QLab offers it: chromatic aberration (lateral and axial, with presets). Grain
/// and halation belong to the film, so they live in Emulsion only.
struct EffectsTab: View {
    let model: EditorModel
    static let lateral = "effects.chromatic_aberration", axial = "effects.ca_axial", blueYellow = "effects.ca_blue_yellow",
               anamorphic = "effects.ca_anamorphic", highlights = "effects.ca_highlights", enabled = "effects.ca_enabled"
    /// The aberration's settings; `enabled` is its switch, which keeps them.
    static let settings = [lateral, axial, blueYellow, anamorphic, highlights]
    static let paths = settings + [enabled]

    /// The aberration's presets: what each kind of lens does, as values of the controls below.
    struct Preset {
        let name: String, lateral: Double, axial: Double, blueYellow: Bool, anamorphic: Bool, highlights: Bool
    }
    static let presets: [Preset] = [
        Preset(name: "Subtle Lateral", lateral: 12, axial: 0, blueYellow: false, anamorphic: false, highlights: false),
        Preset(name: "Vintage Dispersion", lateral: 40, axial: 18, blueYellow: false, anamorphic: false, highlights: false),
        Preset(name: "Axial Glow", lateral: 0, axial: 45, blueYellow: false, anamorphic: false, highlights: false),
        Preset(name: "Purple Highlights", lateral: 6, axial: 60, blueYellow: false, anamorphic: false, highlights: true),
        Preset(name: "Anamorphic", lateral: 45, axial: 10, blueYellow: false, anamorphic: true, highlights: false),
        Preset(name: "Fast-Lens Axial", lateral: 8, axial: 70, blueYellow: false, anamorphic: false, highlights: false),
        Preset(name: "Vintage Blue / Yellow Smear", lateral: 50, axial: 15, blueYellow: true, anamorphic: false, highlights: false),
    ]

    static func count(_ model: EditorModel) -> Int { paths.filter(model.isModified).count }
    static func edits(_ model: EditorModel) -> [TabEdit] {
        let titles = [lateral: "Lateral aberration", axial: "Axial aberration", blueYellow: "Blue / yellow", anamorphic: "Anamorphic", highlights: "Highlights only", enabled: "Chromatic aberration"]
        return paths.filter(model.isModified).map { path in
            let value = model.value(path)
            let shown: String = if case .bool(let on) = value { on ? "On" : "Off" } else { "\(Int(value.double.rounded()))" }
            return TabEdit(title: titles[path] ?? path, value: shown, target: .param(path))
        }
    }

    private var current: Preset? {
        Self.presets.first { p in
            abs(model.value(Self.lateral).double - p.lateral) < 0.5 && abs(model.value(Self.axial).double - p.axial) < 0.5
                && model.value(Self.blueYellow).bool == p.blueYellow && model.value(Self.anamorphic).bool == p.anamorphic
                && model.value(Self.highlights).bool == p.highlights
        }
    }

    var body: some View {
        let edited = Self.settings.contains(where: model.isModified)
        InkSection(title: "Chromatic Aberration", edited: edited, enabled: model.toggle(Self.enabled)) {
            ChoiceRow(title: "Preset", items: [.option("None", tag: "none")] + [.divider] + Self.presets.map { .option($0.name, tag: $0.name) }
                      + (current == nil && edited ? [.divider, .option("Custom", tag: "custom")] : []),
                      selection: !edited ? "none" : current?.name ?? "custom", changed: edited,
                      help: "Lenses that bend colours apart. Lateral: fringes towards the corners. Axial: soft red and blue round sharp green, as with a fast lens wide open.") { tag in
                if tag == "none" { model.setParams(Self.paths.map { ($0, model.defaultValue($0)) }) }
                else if let p = Self.presets.first(where: { $0.name == tag }) {
                    model.setParams([(Self.lateral, .number(p.lateral)), (Self.axial, .number(p.axial)), (Self.blueYellow, .bool(p.blueYellow)),
                                     (Self.anamorphic, .bool(p.anamorphic)), (Self.highlights, .bool(p.highlights))])
                }
            }
            SliderRow(model: model, title: "Lateral", path: Self.lateral, range: -100...100, step: 1)
            SliderRow(model: model, title: "Axial", path: Self.axial, range: 0...100, step: 1)
            TickRow(title: "Blue / yellow", isOn: model.toggle(Self.blueYellow), changed: model.isModified(Self.blueYellow),
                    help: "Lateral fringes in blue and yellow rather than red and blue, as with old uncoated lenses.")
            TickRow(title: "Anamorphic", isOn: model.toggle(Self.anamorphic), changed: model.isModified(Self.anamorphic),
                    help: "Lateral fringes along the width only, as through an anamorphic lens.")
            TickRow(title: "Highlights only", isOn: model.toggle(Self.highlights), changed: model.isModified(Self.highlights),
                    help: "Axial fringes only round bright light: the purple edges of highlights.")
        }
    }
}

// MARK: Tabs

/// The panel's tabs as one pill: the chosen one lit, a dot where something changed.
struct TabPills: View {
    let counts: [InspectorTab: Int]
    @Binding var tab: InspectorTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.inDevelop, id: \.self) { item in
                let on = tab == item
                Button { tab = item } label: {
                    HStack(spacing: 4) {
                        Text(item.title).font(.system(size: 12, weight: on ? .semibold : .medium))
                        if (counts[item] ?? 0) > 0 { Circle().fill(Theme.accent).frame(width: 4, height: 4) }
                    }
                    .foregroundStyle(on ? Color.white : Color(white: 0.62))
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(Capsule().fill(on ? Color.white.opacity(0.16) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue((counts[item] ?? 0) > 0 ? "\(counts[item]!) edits" : "")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .padding(.horizontal, Theme.Size.gutter - 6)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: tab)
    }
}

/// The recipe, in the film card: the one applied to this photograph, a menu of the recipes to apply another (hidden ones
/// aside, favourites first), and + to save this development as a new one. The Recipes room keeps the shelf itself.
private struct PresetRow: View {
    let model: EditorModel

    private func item(_ preset: PresetFile) -> some View {
        Button { model.applyPreset(preset) } label: {
            if model.appliedPreset == preset.url { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
        }
    }

    var body: some View {
        let name = model.appliedPreset.map { $0.deletingPathExtension().lastPathComponent }
        HStack(spacing: 0) {
            // Qlick Lab: the recipe chooser, under the film and the paper: a click applies one to this photograph.
            Menu {
                let recipes = model.listedPresets
                let favourites = recipes.filter(model.lab.isFavourite(recipe:))
                if recipes.isEmpty { Text("No recipes yet") }
                if !favourites.isEmpty {
                    Section("Favourites") { ForEach(favourites) { preset in item(preset) } }
                    Section("All Recipes") { ForEach(recipes.filter { !favourites.contains($0) }) { preset in item(preset) } }
                } else {
                    ForEach(recipes) { preset in item(preset) }
                }
                Divider()
                Button("Save This Development as a Recipe…") { model.newPreset() }.disabled(!model.canChangePresets)
                Button("Show the Recipes") { model.lab.show(.recipes) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    Text("Recipe").font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize()
                    Text(name ?? "None").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(name == nil ? Color(white: 0.6) : Color(white: 0.9)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                }
                .padding(.leading, 12).padding(.trailing, 6)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            // As a plain button, so the whole row (the name and its chevron) is its label.
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .disabled(model.source == nil || !model.canChangePresets)
            .help("Apply a recipe to this photograph: its film, paper and settings")
            Button { model.newPreset() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
                    .frame(width: 30, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canChangePresets)
            .help("Save this development as a new recipe (⇧⌘S)")
            .padding(.trailing, 4)
        }
    }
}
