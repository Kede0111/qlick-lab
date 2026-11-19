// Qlick Lab — GPL-3.0-only.
import AppKit
import SwiftUI

/// The sidebar's Binder: the folders chosen on disk, as a tree that follows the disk. A folder of photographs that no
/// project has wears an amber dot; a click opens it on the contact sheet, its menu files it in a project.
struct BinderSection: View {
    let model: EditorModel
    /// Unfolded by hand; the roots start unfolded.
    @State private var open: Set<String> = []
    @State private var folded: Set<String> = []

    private var lab: LabState { model.lab }

    var body: some View {
        let binder = lab.binder
        HStack {
            CapsLabel("Binder")
            Spacer()
            Button(action: choose) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a folder of your disks to the Binder")
        }
        .padding(.leading, 10).padding(.trailing, 2)
        .padding(.top, 22).padding(.bottom, 6)

        if binder.roots.isEmpty {
            Text("Add the folders where your photographs live. Folders not yet in a project are marked.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.top, 2)
        }
        let filed = Set(lab.projects.projects.flatMap { $0.rolls.map(\.folder) })
        let openFolder = model.library.directory?.standardizedFileURL.path
        ForEach(binder.roots, id: \.self) { root in
            if let tree = binder.trees[root] {
                rows(tree, depth: 0, root: root, filed: filed, openFolder: openFolder)
            } else {
                BinderRow(name: root.lastPathComponent, depth: 0, photos: nil, unfiled: false, unfiledInside: false, on: false, hasChildren: false, unfolded: false,
                          missing: !FileManager.default.fileExists(atPath: root.path), toggle: {}, action: {})
                    .contextMenu { rootMenu(root) }
            }
        }
    }

    private func rows(_ folder: BinderFolder, depth: Int, root: URL, filed: Set<String>, openFolder: String?) -> AnyView {
        let unfolded = isOpen(folder, depth: depth)
        return AnyView(Group {
            BinderRow(name: folder.name, depth: depth, photos: folder.photos, unfiled: folder.photos > 0 && !filed.contains(folder.url.path),
                      unfiledInside: !unfolded && folder.children.flatMap(\.all).contains { $0.photos > 0 && !filed.contains($0.url.path) },
                      on: folder.url.path == openFolder, hasChildren: !folder.children.isEmpty, unfolded: unfolded, missing: false,
                      toggle: { toggle(folder, depth: depth) },
                      action: { if folder.photos > 0 { lab.open(folder: folder.url) } else { toggle(folder, depth: depth) } })
                .contextMenu { menu(folder, root: depth == 0 ? root : nil, filed: filed.contains(folder.url.path)) }
            if unfolded {
                ForEach(folder.children) { child in rows(child, depth: depth + 1, root: root, filed: filed, openFolder: openFolder) }
            }
        })
    }

    private func isOpen(_ folder: BinderFolder, depth: Int) -> Bool {
        depth == 0 ? !folded.contains(folder.id) : open.contains(folder.id)
    }

    private func toggle(_ folder: BinderFolder, depth: Int) {
        if depth == 0 {
            if folded.contains(folder.id) { folded.remove(folder.id) } else { folded.insert(folder.id) }
        } else if open.contains(folder.id) { open.remove(folder.id) } else { open.insert(folder.id) }
    }

    @ViewBuilder private func menu(_ folder: BinderFolder, root: URL?, filed: Bool) -> some View {
        if folder.photos > 0 { Button("Open on the Contact Sheet") { lab.open(folder: folder.url) } }
        if !filed {
            Button("Import…") { lab.importFolders([folder.url]) }
            if !lab.projects.ordinary.isEmpty {
                Menu("Add to Project") {
                    ForEach(lab.projects.ordinary) { project in Button(project.name) { lab.importFolders([folder.url], into: project.id) } }
                }
            }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        if let root {
            Divider()
            rootMenu(root)
        }
    }

    @ViewBuilder private func rootMenu(_ root: URL) -> some View {
        Button("Remove from the Binder") { lab.binder.remove(root) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Add to the Binder"
        panel.message = "Choose a folder where your photographs live. Its folders are shown as a tree; nothing is moved."
        panel.prompt = "Add"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { for url in urls { lab.binder.add(url) } }
        }
    }
}

private struct BinderRow: View {
    let name: String
    let depth: Int
    let photos: Int?
    let unfiled: Bool
    /// Folded, with a folder in no project somewhere under it.
    let unfiledInside: Bool
    let on: Bool
    let hasChildren: Bool
    let unfolded: Bool
    let missing: Bool
    let toggle: () -> Void
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.dim)
                    .rotationEffect(.degrees(unfolded ? 90 : 0))
                    .opacity(hasChildren ? 1 : 0)
                    .frame(width: 18, height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasChildren)
            Button(action: action) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(on ? Theme.accent : unfiled ? Theme.warn : Color.clear).frame(width: 5, height: 5)
                        if !on && !unfiled && unfiledInside { Circle().strokeBorder(Theme.warn, lineWidth: 1).frame(width: 6, height: 6) }
                    }
                    .frame(width: 8)
                    Text(name).font(.system(size: 12.5, weight: on ? .semibold : depth == 0 ? .medium : .regular))
                        .foregroundStyle(on ? Theme.paper : depth == 0 ? Color(white: 0.86) : Color(white: 0.72)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if missing {
                        Image(systemName: "questionmark.folder").font(.system(size: 10)).foregroundStyle(Theme.dim).help("Folder not found: its disk may not be connected")
                    } else if let photos, photos > 0 {
                        Text("\(photos)").font(Theme.value(11)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.trailing, 8)
                .frame(height: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(on ? 0.08 : hovered ? 0.05 : 0)))
        .onHover { hovered = $0 }
        .help(unfiled ? "In no project yet" : unfiledInside ? "Holds folders in no project yet" : "")
    }
}
