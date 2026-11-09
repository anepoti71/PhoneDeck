import SwiftUI
import PMD3BarCore

struct GridView: View {
    let model: AppModel
    /// One viewer controller per iPhone, made on first use. A plain (unobserved) cache, so a cell
    /// can create its controller while rendering instead of waiting for onAppear/onChange.
    @State private var cache = ControllerCache()

    final class ControllerCache {
        private var controllers: [String: ViewerController] = [:]
        @MainActor func controller(for udid: String, name: String) -> ViewerController {
            if let c = controllers[udid] { return c }
            let c = ViewerController(deviceOnly: true)  // grid: always only the iPhones, not remembered
            c.deviceName = name
            controllers[udid] = c
            return c
        }
    }

    private var sessions: [MirrorSession] { model.activeSessions }

    var body: some View {
        Group {
            if sessions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("No iPhone mirroring").foregroundStyle(.white)
                    Text("Needs reachable iPhones with iOS \(Device.mirrorMinimumIOS) or later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 1) {
                    ForEach(sessions) { s in cell(s) }
                }
            }
        }
        .background(Color.black)
    }

    @ViewBuilder private func cell(_ s: MirrorSession) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(model.device(s.udid)?.name ?? "iPhone").font(.caption.weight(.semibold))
                Spacer()
                Button { MirrorWindows.shared.show(s.udid) } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("Open in its own window (with Tools)")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.top, 6)
            if s.state == .running {
                ViewerWebView(url: s.viewerURL, generation: s.generation,
                              controller: cache.controller(for: s.udid, name: model.device(s.udid)?.name ?? "iPhone"))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).environment(\.colorScheme, .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
