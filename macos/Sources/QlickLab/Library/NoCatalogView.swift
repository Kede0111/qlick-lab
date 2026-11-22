// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// What the window shows while no catalogue is open (File › Close Catalog): the lab holds nothing, and asks which
/// catalogue to open, a new one, or one opened before. It covers every room, Develop and Print included.
struct NoCatalogView: View {
    let lab: LabState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabGlyphView(glyph: .archive, size: 44, color: Theme.label)
                .padding(.bottom, 18)
            Text("No catalog open").font(Theme.title(20)).foregroundStyle(Theme.paper)
            Text("A catalog holds its own Archives and Boxes. Open one to carry on; the photographs stay where they are.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack(spacing: 8) {
                Button("Open Catalog…") { lab.openCatalogPanel() }.buttonStyle(QPrimaryButtonStyle())
                Button("New Catalog…") { lab.newCatalogPanel() }.buttonStyle(QPillButtonStyle())
            }
            .padding(.top, 18)
            CapsLabel("Recent").padding(.top, 30).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                ForEach([CatalogList.defaultDirectory] + lab.catalogs.recent, id: \.self) { url in
                    RecentCatalogRow(url: url) { lab.openCatalog(url) }
                }
            }
        }
        .frame(width: 420, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

private struct RecentCatalogRow: View {
    let url: URL
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                LabGlyphView(glyph: .archive, size: 15, color: hovered ? Theme.paper : Theme.label)
                VStack(alignment: .leading, spacing: 1) {
                    Text(CatalogList.name(of: url)).font(.system(size: 13)).foregroundStyle(Theme.paper)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(url.path)
    }
}
