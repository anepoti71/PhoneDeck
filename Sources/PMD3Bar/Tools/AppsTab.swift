import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PMD3BarCore

struct AppsTab: View {
    let tools: DeviceTools
    @State private var search = ""
    @State private var confirmUninstall: DeviceTools.AppInfo?

    private var filtered: [DeviceTools.AppInfo] {
        search.isEmpty ? tools.apps : tools.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundle_id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Cerca", text: $search).textFieldStyle(.roundedBorder)
                Button { pickIPA() } label: { Label("Installa .ipa", systemImage: "plus") }
                Button { Task { await tools.refreshApps() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Aggiorna")
            }
            .padding(.horizontal, 10).padding(.top, 8)
            if let err = tools.appsError { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 10) }
            List(filtered) { app in
                HStack {
                    Group {
                        if let img = tools.icon(for: app.bundle_id) {
                            Image(nsImage: img).resizable().interpolation(.high)
                        } else {
                            RoundedRectangle(cornerRadius: 7).fill(.quaternary)
                        }
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text("\(app.bundle_id) · \(app.version)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { Task { await tools.launch(app) } } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help("Avvia")
                }
                .contextMenu {
                    Button("Avvia") { Task { await tools.launch(app) } }
                    Button("Copia bundle ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.bundle_id, forType: .string)
                    }
                    Divider()
                    Button("Disinstalla…", role: .destructive) { confirmUninstall = app }
                }
            }
            .overlay { if tools.appsLoading && tools.apps.isEmpty { ProgressView() } }
            Text("Trascina un .ipa sulla finestra per installarlo. Avvia richiede la Developer Disk Image.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .task { if tools.apps.isEmpty { await tools.refreshApps() } }
        .confirmationDialog("Disinstallare \(confirmUninstall?.name ?? "")?", isPresented: .init(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })
        ) {
            Button("Disinstalla", role: .destructive) {
                if let app = confirmUninstall { Task { await tools.uninstall(app) } }
            }
        } message: {
            Text("L'app e tutti i suoi dati verranno eliminati dall'iPhone.")
        }
    }

    private func pickIPA() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await tools.install(url) } }
    }
}
