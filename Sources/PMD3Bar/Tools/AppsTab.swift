import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PMD3BarCore

struct AppsTab: View {
    let tools: DeviceTools
    /// Switches the panel to another tab (Files for an app's container, Console for its output).
    var showTab: (ToolTab) -> Void = { _ in }
    @State private var search = ""
    @State private var confirmUninstall: DeviceTools.AppInfo?
    @State private var launchWithOptions: DeviceTools.AppInfo?

    private var filtered: [DeviceTools.AppInfo] {
        search.isEmpty ? tools.apps : tools.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.bundle_id.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Button { pickIPA() } label: { Label("Install .ipa", systemImage: "plus") }
                Button { Task { await tools.refreshApps() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
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
                    if tools.mounts.isMounted(app.bundle_id) {
                        Button { tools.mounts.open(app.bundle_id, name: app.name) } label: {
                            Image(systemName: "externaldrive.connected.to.line.below")
                        }
                        .buttonStyle(.borderless).help("Mounted in Finder: click to show it")
                    }
                    Button { Task { await tools.launch(app) } } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help("Launch")
                }
                .contextMenu {
                    Button("Launch") { Task { await tools.launch(app) } }
                    Button("Launch with Options…") { launchWithOptions = app }
                    Divider()
                    Button("Show Files") {
                        showTab(.files)
                        Task { await tools.showFiles(of: app) }
                    }
                    if tools.mounts.isMounted(app.bundle_id) {
                        Button("Show in Finder") { tools.mounts.open(app.bundle_id, name: app.name) }
                        Button("Unmount from Finder") { tools.mounts.unmount(app.bundle_id) }
                    } else {
                        Button("Open in Finder") { tools.mounts.open(app.bundle_id, name: app.name) }
                    }
                    Button("Download Container") { Task { await tools.downloadContainer(app) } }
                    Divider()
                    Button("Copy bundle ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.bundle_id, forType: .string)
                    }
                    Divider()
                    Button("Uninstall…", role: .destructive) { confirmUninstall = app }
                }
            }
            .overlay { if tools.appsLoading && tools.apps.isEmpty { ProgressView() } }
            Text("Drop an .ipa on the window to install it. Launch needs the Developer Disk Image. Right-click an app for its files and launch options.")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
        }
        .task { if tools.apps.isEmpty { await tools.refreshApps() } }
        .sheet(item: $launchWithOptions) { app in
            LaunchOptionsSheet(app: app, options: tools.launchOptions(for: app)) { options in
                tools.saveLaunchOptions(options, for: app)
                if options.console { showTab(.console) }
                Task { await tools.launch(app, options: options) }
            }
        }
        .confirmationDialog("Uninstall \(confirmUninstall?.name ?? "")?", isPresented: .init(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } })
        ) {
            Button("Uninstall", role: .destructive) {
                if let app = confirmUninstall { Task { await tools.uninstall(app) } }
            }
        } message: {
            Text("The app and all its data will be deleted from the iPhone.")
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

/// Arguments and environment for one launch, remembered per app.
struct LaunchOptionsSheet: View {
    let app: DeviceTools.AppInfo
    @State var options: LaunchOptions
    let launch: (LaunchOptions) -> Void
    @Environment(\.dismiss) private var dismiss

    private var error: String? {
        do {
            _ = try options.parsedArguments()
            _ = try options.parsedEnvironment()
            return nil
        } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Launch \(app.name)").font(.headline)
            Text("Arguments").font(.caption).foregroundStyle(.secondary)
            TextField("-FIRDebugEnabled -AppleLanguages \"(it)\"", text: $options.arguments)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
            Text("Environment, one KEY=value per line").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $options.environment)
                .font(.callout.monospaced())
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            Toggle("Quit the app first if it is running", isOn: $options.killExisting).toggleStyle(.checkbox)
            Toggle("Show its output (stdout and stderr) in the Console tab", isOn: $options.console)
                .toggleStyle(.checkbox)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Clear") { options = LaunchOptions() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Launch") {
                    launch(options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(error != nil)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
