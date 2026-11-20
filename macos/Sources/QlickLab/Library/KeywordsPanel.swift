// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// What the photographs say in words: their colour label, title and caption (one photograph), and keywords, with the
/// keyword set (⌥1…⌥9) and the catalogue's keywords, counted. The same editor over the contact sheet
/// (`KeywordsPanel`) and in Develop's information (⌘I); ⌘K gives its Add Keyword field the keys.
struct PhotoWordsEditor: View {
    let model: EditorModel
    @State private var title = ""
    @State private var caption = ""
    /// The photograph `title` and `caption` were read from.
    @State private var editing: URL?
    @State private var adding = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case title, caption, add }
    private var lab: LabState { model.lab }

    var body: some View {
        let targets = model.ratingTargets
        VStack(alignment: .leading, spacing: 14) {
            if targets.isEmpty {
                Text("Select a photograph.").font(Theme.caps(12)).foregroundStyle(Theme.dim)
            } else {
                if ColorLabel.inInterface { labels(targets) }
                if targets.count == 1 { words } else {
                    Text("\(targets.count) photographs: a title and a caption are written for one at a time.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                keywords(targets)
            }
            catalogue(targets)
        }
        .onAppear { load(targets.count == 1 ? targets.first : nil) }
        .onChange(of: targets.count == 1 ? targets.first : nil) { old, new in commit(old); load(new) }
        .onChange(of: editing.map { model.library.summary(for: $0).words }) { _, _ in
            // An undo, or another window: what's stored shows, unless it's being typed.
            if focus != .title && focus != .caption { load(editing) }
        }
        .onChange(of: focus) { old, new in
            if (old == .title || old == .caption), new != .title, new != .caption { commit(editing) }
        }
        .task(id: lab.keywordFocus) {
            guard lab.keywordFocusPending else { return }
            lab.keywordFocusPending = false
            try? await Task.sleep(for: .milliseconds(60))
            focus = .add
        }
        .onDisappear { commit(editing) }
    }

    // MARK: Label

    private func labels(_ targets: [URL]) -> some View {
        let summaries = targets.map { model.library.summary(for: $0) }
        return VStack(alignment: .leading, spacing: 7) {
            CapsLabel("Colour Label", size: 9.5)
            HStack(spacing: 7) {
                ForEach(ColorLabel.allCases) { label in
                    let all = summaries.allSatisfy { $0.label == label }, some = summaries.contains { $0.label == label }
                    Button { model.toggleLabel(label, targets: targets) } label: {
                        LabelDot(label: label, size: 15)
                            .padding(3)
                            .overlay(Circle().strokeBorder(Theme.paper.opacity(all ? 0.9 : some ? 0.4 : 0), lineWidth: 1.2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(LabelNames.name(label) + (label.action.map { " (\(ShortcutStore.display(lab.keys.key($0))))" } ?? ""))
                }
                Button { model.setLabel(nil, targets: targets) } label: {
                    Image(systemName: "circle.slash").font(.system(size: 13)).foregroundStyle(Theme.dim).frame(width: 21, height: 21)
                }
                .buttonStyle(.plain).help("No label")
                .disabled(summaries.allSatisfy { $0.label == nil })
                Spacer(minLength: 0)
                if let shown = summaries.first?.label, summaries.allSatisfy({ $0.label == shown }) {
                    Text(LabelNames.name(shown)).font(.system(size: 11.5)).foregroundStyle(Theme.label).lineLimit(1)
                }
            }
        }
    }

    // MARK: Title and caption

    private var words: some View {
        VStack(alignment: .leading, spacing: 7) {
            CapsLabel("Title", size: 9.5)
            field(TextField("A title", text: $title).focused($focus, equals: .title).onSubmit { commit(editing) })
            CapsLabel("Caption", size: 9.5).padding(.top, 4)
            field(TextField("What, where, who…", text: $caption, axis: .vertical).lineLimit(2...6).focused($focus, equals: .caption))
        }
    }

    private func field(_ field: some View) -> some View {
        field.textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.paper)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func load(_ photo: URL?) {
        editing = photo
        let words = photo.map { model.library.summary(for: $0).words } ?? PhotoWords()
        title = words.title; caption = words.caption
    }

    private func commit(_ photo: URL?) {
        guard let photo, photo == editing else { return }
        let stored = model.library.summary(for: photo).words
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != stored.title || caption != stored.caption else { return }
        model.setTitle(title, caption: caption, of: photo)
    }

    // MARK: Keywords

    private func keywords(_ targets: [URL]) -> some View {
        let held = Self.held(targets.map { model.library.summary(for: $0).words.keywords })
        return VStack(alignment: .leading, spacing: 7) {
            CapsLabel("Keywords", size: 9.5)
            if !held.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(held, id: \.word) { entry in
                        KeywordChip(word: entry.word, partial: entry.count < targets.count ? "\(entry.count)/\(targets.count)" : nil,
                                    add: { added([entry.word], targets) }, remove: { model.removeKeyword(entry.word, targets: targets); lab.projects.recount(holding: targets) })
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                TextField("Add Keyword (⌘K)", text: $adding)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.paper)
                    .focused($focus, equals: .add)
                    .onSubmit {
                        let typed = PhotoWords.typed(adding)
                        adding = ""
                        added(typed, model.ratingTargets)
                        focus = .add
                    }
                    .onExitCommand { adding = ""; focus = nil; lab.sheetView.map { $0.window?.makeFirstResponder($0) } }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
            .help("Several at once, separated by commas. Return adds them to the photographs selected.")
        }
    }

    private func added(_ words: [String], _ targets: [URL]) {
        guard !words.isEmpty else { return }
        model.addKeywords(words, targets: targets)
        lab.projects.recount(holding: targets)
    }

    /// The keywords the photographs hold, each with how many of them hold it, in the order first met.
    static func held(_ lists: [[String]]) -> [(word: String, count: Int)] {
        var order: [String] = [], counts: [String: (word: String, count: Int)] = [:]
        for list in lists {
            for word in Set(list.map { $0.lowercased() }) {
                if counts[word] == nil { order.append(word) }
                counts[word] = (counts[word]?.word ?? list.first { $0.lowercased() == word } ?? word, (counts[word]?.count ?? 0) + 1)
            }
        }
        return order.compactMap { counts[$0] }.sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
    }

    // MARK: The catalogue's keywords

    private func catalogue(_ targets: [URL]) -> some View {
        let all = Self.merged(lab.projects.keywordCounts(), listed: model.library.items.map { model.library.summary(for: $0.url).words.keywords })
        let filtered = model.library.filter.keyword
        return VStack(alignment: .leading, spacing: 5) {
            CapsLabel("In the Catalogue", size: 9.5)
            if all.isEmpty {
                Text("No keywords yet.").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
            ForEach(all.prefix(60), id: \.word) { entry in
                HStack(spacing: 6) {
                    Button { if !targets.isEmpty { model.toggleKeyword(entry.word, targets: targets); lab.projects.recount(holding: targets) } } label: {
                        HStack(spacing: 6) {
                            Text(entry.word).font(.system(size: 12)).foregroundStyle(Theme.paper).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(entry.count)").font(Theme.value(11)).foregroundStyle(Theme.dim)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(targets.isEmpty ? entry.word : "Add “\(entry.word)” to the photographs selected, or take it off")
                    let on = filtered?.caseInsensitiveCompare(entry.word) == .orderedSame
                    Button { model.library.filter.keyword = on ? nil : entry.word } label: {
                        Image(systemName: on ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11)).foregroundStyle(on ? Theme.accent : Theme.dim)
                    }
                    .buttonStyle(.plain).help(on ? "Show every photograph again" : "Show only the photographs with “\(entry.word)”")
                }
                .frame(height: 20)
            }
        }
    }

    /// The catalogue's counts, with the keywords of what's listed that it hasn't counted yet (a folder outside it).
    static func merged(_ catalogue: [(word: String, count: Int)], listed: [[String]]) -> [(word: String, count: Int)] {
        var result = catalogue
        let known = Set(catalogue.map { $0.word.lowercased() })
        for entry in held(listed) where !known.contains(entry.word.lowercased()) { result.append(entry) }
        return result.sorted { $0.count != $1.count ? $0.count > $1.count : $0.word.localizedStandardCompare($1.word) == .orderedAscending }
    }
}

/// A keyword the selection holds: its word, how many of them hold it when not all ("3/5", a click gives it to all),
/// and × to take it off.
private struct KeywordChip: View {
    let word: String
    let partial: String?
    let add: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: add) {
                HStack(spacing: 4) {
                    Text(word).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.paper).lineLimit(1)
                    if let partial { Text(partial).font(Theme.value(10)).foregroundStyle(Theme.dim) }
                }
            }
            .buttonStyle(.plain)
            .disabled(partial == nil)
            .help(partial == nil ? word : "Give “\(word)” to every photograph selected")
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(hovered ? Theme.paper : Theme.dim)
            }
            .buttonStyle(.plain).help("Take “\(word)” off")
        }
        .padding(.leading, 9).padding(.trailing, 7).frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(partial == nil ? 0.12 : 0.05)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(partial == nil ? 0 : 0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .onHover { hovered = $0 }
    }
}

/// Lays its views in lines, wrapping as words do.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// The information card over the contact sheet (the sheet's ⓘ, ⌘K, ⌃⌘I): the photograph's words (`PhotoWordsEditor`:
/// label, title, caption, keywords) over its facts (`FrameInfoPanel`), on glass, as Develop's information (⌘I).
struct KeywordsPanel: View {
    let model: EditorModel
    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                CapsLabel("Information", size: 10.5, color: Theme.paper)
                Spacer(minLength: 8)
                QIconButton(symbol: "xmark", help: "Close") { model.lab.wordsVisible = false }
            }
            .padding(.leading, 16).padding(.trailing, 8).frame(height: 38)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            FittingScroll {
                VStack(alignment: .leading, spacing: 14) {
                    PhotoWordsEditor(model: model)
                    if let current = model.selection.current {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                        FrameInfoPanel(model: model, item: current, card: false)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.width)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous))
        .glass(RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keywords and Label")
    }
}

/// A scroll view as tall as its content, up to the room it's offered: it scrolls only when that's shorter. One copy
/// of the content (a `ViewThatFits` would make two, each with its own fields).
struct FittingScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.background(GeometryReader { proxy in
                Color.clear.onAppear { height = proxy.size.height }.onChange(of: proxy.size.height) { _, new in height = new }
            })
        }
        .scrollIndicators(.never)
        .frame(maxHeight: max(height, 1))
    }
}
