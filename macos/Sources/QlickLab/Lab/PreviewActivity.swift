// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// Build Previews at work, where you are: a turning mark, how many are done, and a way to stop. A moment's word
/// once it's done, or when there was nothing to build. Background builds the lab starts by itself stay in the
/// sidebar; one asked for shows here too.
struct PreviewActivity: View {
    let builder: PreviewBuilder

    var body: some View {
        if builder.running, builder.asked, builder.total > 0 {
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(Q.red)
                Text(builder.makingProxies ? "Making proxies" : "Building previews").font(.system(size: 11)).foregroundStyle(Color(white: 0.8))
                Text("\(min(builder.done + 1, builder.total)) of \(builder.total)").font(Q.value(11)).foregroundStyle(Q.dim)
                Button { builder.cancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Q.dim)
                }
                .buttonStyle(.plain)
                .help("Stop building previews")
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .help(builder.current.map { "Developing \($0.lastPathComponent) ahead, so it opens and shows large at once" } ?? "Building previews")
            .transition(.opacity)
        } else if let note = builder.note {
            Label(note, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Color(white: 0.8))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .transition(.opacity)
        }
    }
}
