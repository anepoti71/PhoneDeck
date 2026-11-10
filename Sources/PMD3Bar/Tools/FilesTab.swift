import AppKit
import SwiftUI
import PMD3BarCore

struct FilesTab: View {
    let tools: DeviceTools
    @State private var confirmDelete: DeviceTools.FileEntry?

    var body: some View {
        VStack(spacing: 8) {
            scopePicker.padding(.horizontal, 10).padding(.top, 8)
            HStack {
                Button { Task { await tools.goUp() } } label: { Image(systemName: "chevron.up") }
                    .disabled(!tools.canGoUp).help("Parent folder")
                Text(tools.filesPath).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                if let id = tools.filesScope.bundleID {
                    Button { tools.mounts.open(id, name: tools.filesScopeName) } label: {
                        Image(systemName: tools.mounts.isMounted(id) ? "externaldrive.connected.to.line.below" : "macwindow")
                    }
                    .help("Open the container in Finder, to work on its files directly")
                }
                Button { pickUpload() } label: { Image(systemName: "square.and.arrow.up") }.help("Upload here")
                Button { Task { await tools.refreshFiles() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            .padding(.horizontal, 10)
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
            Text(footnote)
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .task {
            if tools.files.isEmpty { await tools.refreshFiles() }
            if tools.apps.isEmpty { await tools.refreshApps() }
        }
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

    private var footnote: String {
        switch tools.filesScope {
        case .media:
            return "The iPhone's Media folder (photos in DCIM). Double-click to open, right-click to download. Drop files on the window to copy them here."
        case .app(_, false):
            return "The app's whole container (Documents, Library, tmp): open for development-signed apps. Drop files on the window to copy them here."
        case .app(_, true):
            return "Only the app's Documents folder: the iPhone opens the whole container only for development-signed apps."
        }
    }

    private var scopePicker: some View {
        Menu {
            Button { Task { await tools.setFilesScope(.media) } } label: { Label("Media", systemImage: "photo.on.rectangle") }
            if !tools.apps.isEmpty {
                Section("App containers") {
                    ForEach(tools.apps) { app in
                        Button(app.name) { Task { await tools.setFilesScope(.app(bundleID: app.bundle_id, documentsOnly: false)) } }
                    }
                }
            }
        } label: {
            Label(tools.filesScopeName, systemImage: tools.filesScope == .media ? "photo.on.rectangle" : "app")
        }
        .help("Browse the Media folder or an app's container")
    }

    private func pickUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task { await tools.upload(panel.urls) }
    }
}
