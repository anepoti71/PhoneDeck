import AppKit
import SwiftUI
import PMD3BarCore

struct CrashesTab: View {
    @Bindable var tool: CrashesTool
    @State private var confirmDelete: DeviceTools.FileEntry?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { Task { await tool.open((tool.path as NSString).deletingLastPathComponent) } } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(tool.path == "/").help("Cartella superiore")
                Text(tool.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { Task { await tool.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Aggiorna")
            }
            if let err = tool.error { Text(err).font(.caption).foregroundStyle(.red) }
            List(tool.entries) { e in
                HStack {
                    Image(systemName: e.dir ? "folder.fill" : "doc.text").foregroundStyle(e.dir ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        if let d = DeviceDates.parse(e.mtime) {
                            Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    Task { e.dir ? await tool.open(tool.fullPath(e)) : await tool.show(e) }
                }
                .contextMenu {
                    if e.dir {
                        Button("Apri") { Task { await tool.open(tool.fullPath(e)) } }
                    } else {
                        Button("Mostra") { Task { await tool.show(e) } }
                    }
                    Button("Scarica in Download") { Task { await tool.download(e) } }
                    Divider()
                    Button("Elimina…", role: .destructive) { confirmDelete = e }
                }
            }
            .overlay { if tool.loading && tool.entries.isEmpty { ProgressView() } }
            Text("Report di crash e diagnostica dell'iPhone, dal più recente. Doppio clic per leggerli.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .task { if tool.entries.isEmpty { await tool.refresh() } }
        .sheet(isPresented: .init(get: { tool.openedReport != nil }, set: { if !$0 { tool.openedReport = nil } })) {
            if let rep = tool.openedReport { CrashReportSheet(name: rep.name, text: rep.text) { tool.openedReport = nil } }
        }
        .confirmationDialog("Eliminare \(confirmDelete?.name ?? "")?", isPresented: .init(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Elimina", role: .destructive) { if let e = confirmDelete { Task { await tool.delete(e) } } }
        } message: {
            Text("Il report viene eliminato dall'iPhone.")
        }
    }

}

struct CrashReportSheet: View {
    let name: String
    let text: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Copia") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Chiudi", action: close).keyboardShortcut(.cancelAction)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(minWidth: 640, minHeight: 480)
    }
}
