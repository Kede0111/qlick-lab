// Qlick Lab — GPL-3.0-only.
import Observation
import SwiftUI

/// What a profile's own file says of a stock: read from `data/profiles/<id>.json`, never invented. The curves are
/// the measured (or modelled) data the engine simulates with, so a stock's card shows its real character.
struct StockProfile: Sendable {
    var type = ""
    var use = ""
    var support = ""
    var antihalation = ""
    var referenceIlluminant = ""
    var targetPrint = ""
    var copyright = ""
    var license = ""
    var version = ""
    /// log₁₀ exposure, and the density of each layer at it.
    var logExposure: [Double] = []
    var density: [[Double]] = []
    var wavelengths: [Double] = []
    /// log₁₀ sensitivity of each layer by wavelength.
    var sensitivity: [[Double?]] = []

    nonisolated static func read(_ url: URL) -> StockProfile? {
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var profile = StockProfile()
        let info = json["info"] as? [String: Any] ?? [:], metadata = json["metadata"] as? [String: Any] ?? [:], curves = json["data"] as? [String: Any] ?? [:]
        func text(_ value: Any?) -> String { value as? String ?? "" }
        profile.type = text(info["type"]); profile.use = text(info["use"]); profile.support = text(info["support"])
        profile.antihalation = text(info["antihalation"]); profile.referenceIlluminant = text(info["reference_illuminant"])
        profile.targetPrint = text(info["target_print"])
        profile.copyright = text(metadata["copyright"]); profile.license = text(metadata["license"]); profile.version = text(metadata["version"])
        profile.logExposure = (curves["log_exposure"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        profile.density = (curves["density_curves"] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
        profile.wavelengths = (curves["wavelengths"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        profile.sensitivity = (curves["log_sensitivity"] as? [[Any]] ?? []).map { $0.map { ($0 as? NSNumber)?.doubleValue } }
        return profile
    }
}

@MainActor @Observable final class StockProfiles {
    private(set) var profiles: [String: StockProfile] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    func get(_ id: String, data: URL?) -> StockProfile? {
        if let known = profiles[id] { return known }
        guard let data, reading.insert(id).inserted else { return nil }
        let url = data.appendingPathComponent("profiles/\(id).json")
        Task { [weak self] in
            let profile = await Task.detached(priority: .utility) { StockProfile.read(url) }.value
            self?.profiles[id] = profile ?? StockProfile()
        }
        return nil
    }
}

/// What a stock's name and catalog entry say of it.
enum StockFacts {
    static let makers = ["Kodak", "Fujifilm", "Fujicolor", "Fuji", "Ilford", "Agfa", "CineStill", "Lomography", "LomoChrome", "Harman"]

    static func maker(_ stock: Stock) -> String {
        let name = stock.name
        if let maker = makers.first(where: { name.hasPrefix($0) }) { return maker == "Fujicolor" || maker == "Fuji" ? "Fujifilm" : maker == "LomoChrome" ? "Lomography" : maker }
        let prefix = stock.id.split(separator: "_").first.map(String.init) ?? ""
        return makers.first { $0.lowercased() == prefix } ?? prefix.capitalized
    }

    /// The speed in the stock's name, if it has one ("Portra 400", "Vision3 500T", "Velvia 50").
    static func speed(_ stock: Stock) -> Int? {
        guard !stock.paper else { return nil }
        let speeds: Set<Int> = [25, 50, 64, 100, 125, 160, 200, 250, 400, 500, 800, 1600, 3200]
        let words = stock.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.compactMap { word -> Int? in
            // "500T", "250D", "100F", "400H": a speed with the stock's letter.
            let digits = word.drop { !$0.isNumber }.prefix { $0.isNumber }
            guard !digits.isEmpty, word.count - digits.count <= 2, let speed = Int(digits), speeds.contains(speed) else { return nil }
            return speed
        }.last
    }

    enum Family: String, CaseIterable, Identifiable {
        case colourNegative, slide, cinema, infrared, blackAndWhite, colourPaper, cinemaPrint, blackAndWhitePaper
        var id: String { rawValue }
        var title: String {
            switch self {
            case .colourNegative: "Colour negative"
            case .slide: "Diapositives"
            case .cinema: "Cinema films"
            case .infrared: "Infrarouge"
            case .blackAndWhite: "Black & white"
            case .colourPaper: "Colour papers"
            case .cinemaPrint: "Cinema print films"
            case .blackAndWhitePaper: "Black & white papers"
            }
        }
    }

    static func family(_ stock: Stock, cinemaPrints: Set<String>) -> Family {
        if stock.paper { return stock.bw ? .blackAndWhitePaper : stock.isMotionPicturePrint ? .cinemaPrint : .colourPaper }
        if stock.id.contains("aerochrome") || stock.id.contains("infrared") { return .infrared }
        if stock.bw { return .blackAndWhite }
        if stock.positive { return .slide }
        return cinemaPrints.contains(stock.target) ? .cinema : .colourNegative
    }

    static func kind(_ stock: Stock, family: Family) -> String {
        switch family {
        case .colourNegative: "Colour negative"
        case .slide: "Colour slide"
        case .cinema: "Cinema negative"
        case .infrared: "Infrarouge couleur"
        case .blackAndWhite: stock.positive ? "Black & white slide" : "Black & white negative"
        case .colourPaper: "Colour paper"
        case .cinemaPrint: "Film de tirage"
        case .blackAndWhitePaper: "Black & white paper"
        }
    }

    /// Where the profile comes from and how far it can be trusted, as NEgs documents it.
    static func provenance(_ stock: Stock, profile: StockProfile?) -> String {
        if stock.fotufilm {
            return stock.manufacturerData
                ? "Profile adapted from Fotufilm (MUAStudio Inc., CC BY-SA 4.0), built on the maker's data."
                : "Profile adapted from Fotufilm (MUAStudio Inc., CC BY-SA 4.0), modelled from photographs: an approximation, not a measurement of the film."
        }
        if ["kodak_trix400_d76_8min", "ilford_mgrc_deluxe_grade2"].contains(stock.id) {
            return "Profile made from Kodak's and Ilford's datasheets, in spektrafilm's format. Experimental."
        }
        return "spektrafilm profile by Andrea Volpato (CC BY-SA 4.0), built on the maker's published datasheets."
    }
}

// MARK: The room

/// Films, or papers: the shelf of stocks the engine simulates, each shown by its own data, with a preview developed
/// on the open photograph. Nothing here is a fictional profile or a stand-in picture.
struct StockLibrary: View {
    let model: EditorModel
    let papers: Bool
    @State private var query = ""
    @State private var family: StockFacts.Family?
    @State private var favouritesOnly = false
    @State private var selected: String?

    private var lab: LabState { model.lab }

    var body: some View {
        let stocks = papers ? model.papers : model.listedFilms(keeping: [model.film])
        let cinemaPrints = Set(model.papers.filter(\.isMotionPicturePrint).map(\.id))
        let families = Dictionary(grouping: stocks) { StockFacts.family($0, cinemaPrints: cinemaPrints) }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let shown = stocks.filter { stock in
            let stockFamily = StockFacts.family(stock, cinemaPrints: cinemaPrints)
            if let family, stockFamily != family { return false }
            if favouritesOnly, !lab.favouriteStocks.contains(stock.id) { return false }
            let text = "\(stock.name) \(StockFacts.maker(stock)) \(stockFamily.title) \(StockFacts.speed(stock).map { "ISO \($0)" } ?? "")"
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
        let current = selected.flatMap { id in stocks.first { $0.id == id } } ?? stocks.first { $0.id == (papers ? model.paper : model.film) } ?? shown.first
        HStack(spacing: 0) {
            // Families.
            VStack(alignment: .leading, spacing: 2) {
                RoomButton(symbol: papers ? "doc.plaintext" : "film.stack", title: papers ? "All papers" : "All films", on: family == nil && !favouritesOnly,
                           trailing: "\(stocks.count)") { family = nil; favouritesOnly = false }
                RoomButton(symbol: "star", title: "Favourites", on: favouritesOnly, trailing: "\(stocks.filter { lab.favouriteStocks.contains($0.id) }.count)") {
                    favouritesOnly.toggle(); family = nil
                }
                CapsLabel("Categories").padding(.leading, 10).padding(.top, 16).padding(.bottom, 4)
                ForEach(StockFacts.Family.allCases.filter { families[$0] != nil }) { item in
                    RoomButton(symbol: "circle", title: item.title, on: family == item, trailing: "\(families[item]?.count ?? 0)") {
                        family = family == item ? nil : item; favouritesOnly = false
                    }
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 214)
            .background(Color(white: 0.045))

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Q.dim)
                        TextField(papers ? "Search papers…" : "Search films…", text: $query).textFieldStyle(.plain).font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 10).frame(width: 280, height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    Spacer()
                    if model.source == nil {
                        Text("Open a photograph to see each \(papers ? "paper" : "film") on it.").font(.system(size: 11.5)).foregroundStyle(Q.dim)
                    } else if let item = model.sourceItem {
                        Text("Previews developed on \(model.library.name(of: item))").font(.system(size: 11.5)).foregroundStyle(Q.dim)
                    }
                }
                .padding(.horizontal, 16).frame(height: 44)
                .background(Color(white: 0.04))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 230), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(shown) { stock in
                            StockCard(model: model, stock: stock, family: StockFacts.family(stock, cinemaPrints: cinemaPrints),
                                      selected: current?.id == stock.id, inUse: stock.id == (papers ? model.paper : model.film)) { selected = stock.id }
                        }
                    }
                    .padding(20)
                    if shown.isEmpty {
                        Text("No \(papers ? "paper" : "film") matches.").font(.system(size: 12.5)).foregroundStyle(Q.dim).padding(.top, 60)
                    }
                }
            }
            .background(Theme.bg)

            if let current {
                StockDetail(model: model, stock: current, family: StockFacts.family(current, cinemaPrints: cinemaPrints))
                    .frame(width: 330)
                    .background(Color(white: 0.06))
                    .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The request for a stock's preview on the open photograph: the engine develops it, as a click on the stock would.
@MainActor private func stockRequest(_ model: EditorModel, _ stock: Stock, longSide: Int) -> LabDeveloper.Request? {
    guard let item = model.sourceItem else { return nil }
    // A paper is tried under the photograph's own film; not on a slide, which is scanned and has no print.
    if stock.paper {
        guard !model.state.params["io.scan_film"].bool else { return nil }
        return LabDeveloper.Request(item: item, paper: stock.id, longSide: longSide)
    }
    return LabDeveloper.Request(item: item, film: stock.id, longSide: longSide)
}

private struct StockCard: View {
    let model: EditorModel
    let stock: Stock
    let family: StockFacts.Family
    let selected: Bool
    let inUse: Bool
    let select: () -> Void
    @State private var image: CGImage?
    @State private var hovered = false

    var body: some View {
        let lab = model.lab
        let favourite = lab.favouriteStocks.contains(stock.id)
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color(white: 0.09)
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else {
                    // Without a photograph: the stock's own characteristic curves.
                    StockCurves(profile: lab.stockProfiles.get(stock.id, data: model.labEnginePaths?.data), kind: .density, bw: stock.bw, compact: true)
                        .padding(12)
                }
            }
            .aspectRatio(1.5, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(selected ? Q.text : Color.white.opacity(hovered ? 0.3 : 0.08), lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                Button { lab.toggleFavourite(stock.id) } label: {
                    Image(systemName: favourite ? "star.fill" : "star").font(.system(size: 11.5)).foregroundStyle(favourite ? Q.text : Color.white.opacity(0.7))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                        .shadow(color: .black.opacity(0.7), radius: 2)
                }
                .buttonStyle(.plain).opacity(favourite || hovered ? 1 : 0)
                .help(favourite ? "Remove from Favourites" : "Add to Favourites")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if inUse { Circle().fill(Q.red).frame(width: 5, height: 5).help("Used by the open photograph") }
                Text(stock.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Q.text).lineLimit(1)
            }
            Text([StockFacts.speed(stock).map { "ISO \($0)" }, StockFacts.kind(stock, family: family)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(Q.dim).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .task(id: model.sourceItem) {
            image = nil
            guard let request = stockRequest(model, stock, longSide: 420) else { return }
            // The film in use first shows at once; the others as the helper gets to them.
            image = await model.lab.compareModel.developer.image(request)
        }
    }
}

private struct StockDetail: View {
    let model: EditorModel
    let stock: Stock
    let family: StockFacts.Family
    @State private var image: CGImage?

    var body: some View {
        let lab = model.lab
        let profile = lab.stockProfiles.get(stock.id, data: model.labEnginePaths?.data)
        let favourite = lab.favouriteStocks.contains(stock.id)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(stock.name).font(Q.title(18)).foregroundStyle(Q.text).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { lab.toggleFavourite(stock.id) } label: { Image(systemName: favourite ? "star.fill" : "star").foregroundStyle(favourite ? Q.text : Q.dim) }
                            .buttonStyle(.plain)
                    }
                    Text(StockFacts.kind(stock, family: family)).font(.system(size: 12)).foregroundStyle(Q.dim)
                }
                VStack(alignment: .leading, spacing: 7) {
                    fact("Fabricant", StockFacts.maker(stock))
                    if let speed = StockFacts.speed(stock) { fact("Speed", "ISO \(speed)") }
                    if let profile {
                        if !profile.use.isEmpty { fact("Usage", profile.use == "still" ? "Photographie" : profile.use == "cine" ? "Cinema" : profile.use) }
                        if !profile.referenceIlluminant.isEmpty, !stock.paper { fact("Équilibre", profile.referenceIlluminant == "TH-KG3" ? "Tungsten" : "Daylight (\(profile.referenceIlluminant))") }
                        if !profile.antihalation.isEmpty, !stock.paper { fact("Antihalo", ["strong": "Forte", "weak": "Faible", "no": "Aucune", "none": "Aucune"][profile.antihalation] ?? profile.antihalation) }
                    }
                    if !stock.paper, let paper = model.papers.first(where: { $0.id == stock.target }) { fact("Suggested print", paper.name) }
                    if stock.positive, !stock.paper { fact("Print", "Scanned directly (slide)") }
                    if !stock.times.isEmpty { fact("Developments", stock.times.map { "\(Int($0)) min" }.joined(separator: ", ")) }
                }
                if let profile, !profile.density.isEmpty {
                    chart("Characteristic curves", "Each layer's density by exposure (log H)") {
                        StockCurves(profile: profile, kind: .density, bw: stock.bw, compact: false)
                    }
                }
                if let profile, !profile.sensitivity.isEmpty, !stock.paper {
                    chart("Spectral sensitivity", "Each layer's sensitivity from 380 to 780 nm") {
                        StockCurves(profile: profile, kind: .sensitivity, bw: stock.bw, compact: false)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    CapsLabel("Provenance")
                    Text(StockFacts.provenance(stock, profile: profile)).font(.system(size: 11.5)).foregroundStyle(Color(white: 0.7)).fixedSize(horizontal: false, vertical: true)
                    if let profile, !profile.copyright.isEmpty {
                        Text(profile.copyright).font(.system(size: 10.5)).foregroundStyle(Q.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("A simulation from published data: it approaches the film, it doesn't replace it. \(StockFacts.maker(stock)) is a trademark of its owner, unconnected with Qlick Lab.")
                        .font(.system(size: 10.5)).foregroundStyle(Q.faint).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 8) {
                    Button(stock.paper ? "Print on This Paper" : "Develop on This Film") {
                        if stock.paper { model.choosePaper(stock.id) } else { model.chooseFilm(stock.id) }
                        lab.show(.develop)
                    }
                    .buttonStyle(QPrimaryButtonStyle()).disabled(model.source == nil || !model.canChangeEdits)
                    if !stock.paper {
                        Button("Compare with Other Films") {
                            var films = [model.film, stock.id]
                            films = films.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                            for other in lab.favouriteStocks.sorted() where films.count < 3 && !films.contains(other) && model.films.contains(where: { $0.id == other }) { films.append(other) }
                            if films.count < 2, let other = model.films.first(where: { !films.contains($0.id) }) { films.append(other.id) }
                            lab.compare.films = films
                            lab.show(.compare); lab.compareModel.setKind(.films)
                        }
                        .buttonStyle(QPillButtonStyle()).disabled(model.source == nil)
                    }
                    let isDefault = stock.paper ? model.newPhotoPaper == stock.id : model.newPhotoFilm == stock.id
                    Button(isDefault ? "Default for new photographs ✓" : "Use by Default for New Photographs") {
                        if stock.paper { model.setNewPhotoPaper(stock.id) } else { model.setNewPhotoFilm(stock.id) }
                    }
                    .buttonStyle(QPillButtonStyle()).disabled(isDefault)
                    .help("The contact sheet's undeveloped frames are shown on this \(stock.paper ? "paper" : "film")")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
        }
        .task(id: "\(stock.id)|\(model.sourceItem?.absoluteString ?? "")") {
            image = nil
            guard let request = stockRequest(model, stock, longSide: 900) else { return }
            image = await model.lab.compareModel.developer.image(request)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CapsLabel(label, size: 9.5).frame(width: 104, alignment: .leading)
            Text(value).font(Q.value(12)).foregroundStyle(Color(white: 0.86)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chart<Content: View>(_ title: String, _ help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel(title)
            content().frame(height: 132)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04)))
            Text(help).font(.system(size: 10.5)).foregroundStyle(Q.faint)
        }
    }
}

/// A profile's curves: the density of each layer against exposure, or its sensitivity against wavelength. The three
/// layers are drawn in the colours of the light they record (the only colour in the lab that isn't the pencil's:
/// it is data).
struct StockCurves: View {
    enum Kind { case density, sensitivity }
    let profile: StockProfile?
    let kind: Kind
    let bw: Bool
    let compact: Bool

    var body: some View {
        Canvas { context, size in
            guard let profile else { return }
            let xs = kind == .density ? profile.logExposure : profile.wavelengths
            let rows: [[Double?]] = kind == .density ? profile.density.map { $0.map(Optional.some) } : profile.sensitivity
            guard xs.count > 1, rows.count == xs.count else { return }
            let layers = bw ? 1 : min(rows.first?.count ?? 0, 3)
            var low = Double.infinity, high = -Double.infinity
            for row in rows { for value in row.prefix(layers) { if let value, value.isFinite { low = min(low, value); high = max(high, value) } } }
            guard high > low else { return }
            // Sensitivities fall off over decades: the top three are what shapes the picture.
            if kind == .sensitivity { low = max(low, high - 3) }
            let x0 = xs.first!, x1 = xs.last!
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: (x - x0) / (x1 - x0) * size.width, y: size.height - (min(max(y, low), high) - low) / (high - low) * size.height)
            }
            if !compact {
                var grid = Path()
                for step in 1..<4 { let y = size.height * CGFloat(step) / 4; grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                context.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            let colours: [Color] = bw ? [Color(white: 0.85)] : [Color(red: 0.92, green: 0.3, blue: 0.28), Color(red: 0.35, green: 0.78, blue: 0.4), Color(red: 0.35, green: 0.55, blue: 0.98)]
            for layer in 0..<layers {
                var path = Path(), drawing = false
                for (index, x) in xs.enumerated() {
                    guard rows[index].indices.contains(layer), let value = rows[index][layer], value.isFinite, kind == .density || value >= low else { drawing = false; continue }
                    let p = point(x, value)
                    if drawing { path.addLine(to: p) } else { path.move(to: p); drawing = true }
                }
                context.stroke(path, with: .color(colours[layer].opacity(compact ? 0.75 : 0.95)), style: StrokeStyle(lineWidth: compact ? 1.2 : 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityLabel(kind == .density ? "Characteristic curves" : "Spectral sensitivity")
    }
}
