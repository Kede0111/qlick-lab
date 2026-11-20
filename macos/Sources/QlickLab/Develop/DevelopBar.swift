// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// What the lab adds to Develop, in the status line under the photograph and out of its way: the photograph's
/// versions, the ways to compare it, its pencil marks and the loupe.
struct DevelopBar: View {
    let model: EditorModel
    private var lab: LabState { model.lab }

    var body: some View {
        if let item = model.sourceItem, !model.cropping, !model.imageOnly, model.mode == .photo {
            let photo = item.photoFile
            let versions = [photo] + (model.library.duplicates[photo] ?? []).map { photo.variant($0) }
            let index = versions.firstIndex(of: item) ?? 0
            let summary = model.library.summary(for: item)
            HStack(spacing: 1) {
                Menu {
                    ForEach(Array(versions.enumerated()), id: \.element) { number, version in
                        Button {
                            if version != item { model.click(version) }
                        } label: {
                            Text("Version \(number + 1)" + (version == item ? "  ✓" : ""))
                        }
                    }
                    Divider()
                    Button("New Version (Virtual Copy)") { model.duplicate([item]) }.disabled(!model.canChangeEdits)
                    Button("Compare Versions") { compare(.versions, item) }.disabled(versions.count < 2)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.on.square").font(.system(size: 10))
                        Text(versions.count > 1 ? "Version \(index + 1) / \(versions.count)" : "Version 1").font(Theme.ui(11))
                    }
                    .foregroundStyle(Theme.label).padding(.horizontal, 6).frame(height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("This photograph's versions: each keeps its own development (⌘D makes one)")
                divider
                tool("square.split.2x1", "Before and after, side by side") { compare(.beforeAfter, item) }
                tool("film.stack", "Compare films on this photograph") { compare(.films, item) }
                tool("flask", "Compare recipes on this photograph") { compare(.recipes, item) }
                divider
                Button { model.setFlag(summary.flag == .pick ? nil : .pick, targets: [item]) } label: {
                    MarkGlyph(flag: .pick).frame(width: 15, height: 11).opacity(summary.flag == .pick ? 1 : 0.45).frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Pick (\(ShortcutStore.display(lab.keys.key(.pick))))")
                Button { model.setFlag(summary.flag == .reject ? nil : .reject, targets: [item]) } label: {
                    MarkGlyph(flag: .reject).frame(width: 13, height: 11).opacity(summary.flag == .reject ? 1 : 0.45).frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Reject (\(ShortcutStore.display(lab.keys.key(.reject))))")
                StarsControl(rating: summary.rating) { model.setRating($0, targets: [item]) }
                    .padding(.horizontal, 4)
                LabelMenu(model: model, item: item, label: summary.label)
                divider
                tool(lab.developLoupe ? "plus.magnifyingglass" : "magnifyingglass", "Loupe: click the photograph to see its pixels there, click again to fit (Z)", on: lab.developLoupe) {
                    lab.developLoupe.toggle()
                }
                divider
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.track).frame(width: 1, height: 10).padding(.horizontal, 6) }

    private func tool(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.accent : Theme.label).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
        .accessibilityLabel(help)
    }

    private func compare(_ kind: CompareSetup.Kind, _ item: URL) {
        lab.compare.items = [item]
        lab.show(.compare)
        lab.compareModel.setKind(kind)
    }
}

/// Five stars that take a click: the star clicked, or none when it's the rating already.
struct StarsControl: View {
    let rating: Int
    var size: CGFloat = 10
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star").font(.system(size: size))
                    .foregroundStyle(star <= rating ? Theme.paper : Theme.track)
                    .contentShape(Rectangle())
                    .onTapGesture { set(star == rating ? 0 : star) }
            }
        }
        .help("Rating (1 to 5, 0 for none)")
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5")
    }
}

/// An edit that takes a moment to develop, said small at the photograph's corner.
struct UpdatingMark: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).tint(.white)
            Text("Updating").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.85))
        }
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Updating")
    }
}
