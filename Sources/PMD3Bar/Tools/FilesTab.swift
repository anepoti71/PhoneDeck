import AppKit
import SwiftUI
import PMD3BarCore

struct FilesTab: View {
    let tools: DeviceTools
    @State private var confirmDelete: DeviceTools.FileEntry?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { Task { await tools.goUp() } } label: { Image(systemName: "chevron.up") }
                    .disabled(tools.filesPath == "/").help("Parent folder")
                Text(tools.filesPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { pickUpload() } label: { Image(systemName: "square.and.arrow.up") }.help("Upload here")
                Button { Task { await tools.refreshFiles() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            .padding(.horizontal, 10).padding(.top, 8)
            if let err = tools.filesError { Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 10) }
            List(tools.files) { entry in
                HStack {
                    Image(systemName: entry.dir ? "folder.fill" : "doc").foregroundStyle(entry.dir ? Color.accentColor : .secondary)
                    Text(entry.name).lineLimit(1)
                    Spacer()
                    if !entry.dir {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if entry.dir { Task { await tools.openDirectory(tools.path(for: entry)) } }
                }
                .contextMenu {
                    if entry.dir { Button("Open") { Task { await tools.openDirectory(tools.path(for: entry)) } } }
                    Button("Save to Downloads") { Task { await tools.download(entry) } }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = entry }
                }
            }
            .overlay { if tools.filesLoading && tools.files.isEmpty { ProgressView() } }
            Text("The iPhone's Media folder (photos in DCIM). Double-click to open, right-click to download. Drop files on the window to copy them here.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .task { if tools.files.isEmpty { await tools.refreshFiles() } }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: .init(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let e = confirmDelete { Task { await tools.delete(e) } }
            }
        } message: {
            Text(confirmDelete?.dir == true ? "The folder and all its contents will be deleted from the iPhone." : "The file will be deleted from the iPhone.")
        }
    }

    private func pickUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await tools.upload(panel.urls) }
    }
}
