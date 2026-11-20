// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// Print, the lab's third part: making prints of the photographs developed. The photographs are those chosen on the
/// contact sheet (or the one open in Develop).
struct PrintWorkspace: View {
    let model: EditorModel

    private var lab: LabState { model.lab }

    var body: some View {
        let count = model.exportsSingle ? (model.source == nil ? 0 : 1) : model.exportTargets.count
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CapsLabel("Print", color: Theme.paper)
                Spacer()
                Text(count == 0 ? "No photograph chosen" : count == 1 ? "1 photograph" : "\(count) photographs")
                    .font(Theme.value(12)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(Color(white: 0.04))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }

            VStack(spacing: 14) {
                LabSymbol(symbol: Workspace.print.symbol, points: 40, color: Theme.faint)
                Text(count == 0 ? "Choose the photographs to print" : "Ready to print").font(Theme.title(18)).foregroundStyle(Theme.paper)
                Text(count == 0 ? "Select frames on the contact sheet, or open one in the Lab, then come back here."
                                : "The prints are made as developed in the Lab: film, paper, border and size.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button(model.exportTitle) { model.exportPanel() }
                        .buttonStyle(QPrimaryButtonStyle()).disabled(!model.canExport)
                    Button("Print Contact Sheet…") { lab.printing = true }
                        .buttonStyle(QPillButtonStyle()).disabled(model.library.files.isEmpty)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
    }
}
