// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// Qlick Lab: the Recipes room's "iPhone · QLab" section, while an iPhone with QLab is plugged in: its recipes beside
/// the lab's, how each stands, and what can be done with it, one recipe at a time (`PhoneRecipes`).
struct PhoneRecipesPanel: View {
    let model: EditorModel
    let recipes: PhoneRecipes
    /// The lab's recipe being dragged (the room's), let go once it's dropped here.
    @Binding var dragged: URL?
    @AppStorage("qlick.iphoneRecipesOpen") private var open = true
    @State private var targeted = false

    private var phones: PhoneImport { model.lab.importer.phones }
    private var device: PhoneDevice? { phones.devices.first { $0.state == .ready } ?? phones.devices.first }

    var body: some View {
        let device = device
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { open.toggle() } label: {
                    Label(device?.title ?? "iPhone · QLab", systemImage: open ? "chevron.down" : "chevron.right")
                        .font(Theme.caps(11.5, weight: .semibold)).foregroundStyle(Theme.paper).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain).help(open ? "Hide the iPhone’s recipes" : "Show the iPhone’s recipes")
                if let busy = recipes.busy {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                } else if let advice = device?.advice {
                    Text(advice).font(.system(size: 11.5)).foregroundStyle(Theme.warn).lineLimit(1)
                } else if let notice = recipes.notice {
                    Text(notice).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle).help(notice)
                } else {
                    Text(summary).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer()
                Button("Read Again") {
                    if let device, device.state != .ready { phones.refresh(device.udid) }
                    recipes.refresh(device, model: model)
                }
                .buttonStyle(QPillButtonStyle()).disabled(recipes.busy != nil)
                .help("Reads the iPhone’s recipes again. Drag a recipe here to send it to the iPhone; drag one of the iPhone’s among the lab’s to bring it to the Mac")
            }
            .padding(.horizontal, 16).frame(height: 36)
            if open, !recipes.rows.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(recipes.rows) { row in
                            PhoneRecipeLine(model: model, recipes: recipes, row: row)
                                // Dragged among the lab's recipes, it's brought to the Mac.
                                .onDrag {
                                    guard let phone = row.phone else { return NSItemProvider() }
                                    return NSItemProvider(contentsOf: phone.local) ?? NSItemProvider()
                                } preview: { Text(row.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.paper).padding(8) }
                            Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: 230)
            }
        }
        .background(Color(white: 0.05))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
        // A recipe of the lab dropped here is sent to the iPhone, as its line's button would.
        .overlay {
            if targeted { RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2).padding(4).allowsHitTesting(false) }
        }
        .onDrop(of: [.text], isTargeted: $targeted) { providers in
            guard device?.state == .ready, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? String, let url = URL(string: text), url.isFileURL else { return }
                Task { @MainActor in
                    dragged = nil
                    recipes.dropOnPhone(url, model: model)
                }
            }
            return true
        }
        .task(id: Watch(udid: device?.udid, state: device?.state)) { recipes.refresh(device, model: model) }
    }

    private struct Watch: Hashable { var udid: String?; var state: PhoneDevice.State? }

    private var summary: String {
        let onPhone = recipes.rows.filter { $0.phone != nil }.count
        let changed = recipes.rows.filter { ![.same, .onlyMac].contains($0.status) }.count
        var text = "\(onPhone) recipe\(onPhone == 1 ? "" : "s") on the iPhone"
        if changed > 0 { text += " · \(changed) to look at" }
        return text + ". Nothing is exchanged on its own: choose what goes where."
    }
}

/// One recipe: its name on each side, how they stand, what can be done.
private struct PhoneRecipeLine: View {
    let model: EditorModel
    let recipes: PhoneRecipes
    let row: PhoneRecipeRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flask").font(.system(size: 11)).foregroundStyle(Theme.dim)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.paper).lineLimit(1)
                if let mac = row.mac, let phone = row.phone, PresetName.key(mac.name) != PresetName.key(phone.name) {
                    Text("“\(mac.name)” on the Mac").font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(row.status.title).font(.system(size: 10, weight: .semibold)).tracking(0.3)
                .foregroundStyle(attention ? Theme.accent : Color(white: 0.7))
                .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Color.white.opacity(0.06)))
            actions
        }
        .padding(.horizontal, 16).frame(height: 40)
        .disabled(recipes.busy != nil || !model.canChangePresets)
    }

    private var attention: Bool { ![.same, .onlyMac].contains(row.status) }

    @ViewBuilder private var actions: some View {
        switch row.status {
        case .onlyPhone:
            Button("Bring to the Mac") { recipes.bringToMac(row, model: model) }.buttonStyle(QPillButtonStyle(active: true))
                .help("Adds it to the lab’s recipes, as the same recipe (its identifier)")
            more { delete }
        case .onlyMac:
            Button("Send to the iPhone") { recipes.sendToPhone(row, model: model) }.buttonStyle(QPillButtonStyle())
                .help("Puts it in QLab’s recipes; QLab shows it when it next comes to the front")
        case .same:
            more { delete }
        case .changedOnPhone:
            Button("Update the Mac") { recipes.bringToMac(row, model: model) }.buttonStyle(QPillButtonStyle(active: true))
                .help("The Mac’s recipe becomes the iPhone’s, its name included")
            more { sendInstead; keepBoth; Divider(); delete }
        case .changedOnMac:
            Button("Update the iPhone") { recipes.sendToPhone(row, model: model) }.buttonStyle(QPillButtonStyle(active: true))
                .help("The iPhone’s recipe becomes the Mac’s, its name included")
            more { bringInstead; keepBoth; Divider(); delete }
        case .changedOnBoth, .different:
            Button("Keep Both") { recipes.keepBoth(row, model: model) }.buttonStyle(QPillButtonStyle())
                .help("Brings the iPhone’s to the Mac as a recipe of its own, “(iPhone)” after its name")
            more { bringInstead; sendInstead; Divider(); delete }
        }
    }

    private var bringInstead: some View {
        Button("Replace the Mac’s with the iPhone’s") { recipes.bringToMac(row, model: model) }
    }
    private var sendInstead: some View {
        Button("Replace the iPhone’s with the Mac’s") { recipes.sendToPhone(row, model: model) }
    }
    private var keepBoth: some View {
        Button("Keep Both on the Mac") { recipes.keepBoth(row, model: model) }
    }
    private var delete: some View {
        Button("Delete from the iPhone…") { recipes.removeFromPhone(row, model: model) }
    }

    private func more<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Menu { content() } label: { Image(systemName: "ellipsis.circle").font(.system(size: 13)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More")
    }
}
