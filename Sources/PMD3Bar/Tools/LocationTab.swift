import MapKit
import SwiftUI
import PMD3BarCore

struct LocationTab: View {
    let model: AppModel
    let tools: DeviceTools
    let udid: String
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 41.9028, longitude: 12.4964),
        span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)))
    @State private var pin: CLLocationCoordinate2D?
    @State private var latText = ""
    @State private var lonText = ""
    @State private var search = ""
    /// Once the user picks a point, the map stops following the Mac's position.
    @State private var userMoved = false
    private var mac: MacLocation { MacLocation.shared }

    private static let presets: [(String, Double, Double)] = [
        ("Rome", 41.9028, 12.4964), ("Milan", 45.4642, 9.1900), ("London", 51.5074, -0.1278),
        ("New York", 40.7128, -74.0060), ("Cupertino", 37.3349, -122.0090), ("Tokyo", 35.6762, 139.6503),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mountStates[udid] == .notMounted {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Developer Disk Image needed").font(.caption)
                    Spacer()
                    Button("Mount") { Task { await model.mount(udid) } }
                }
            }
            HStack {
                TextField("Search for a place", text: $search).textFieldStyle(.roundedBorder).onSubmit { geocode() }
                Button { centerOnMac() } label: { Image(systemName: "location.circle") }
                    .help("Center on the Mac's location (near the iPhone)")
                Menu("Cities") {
                    ForEach(Self.presets, id: \.0) { p in
                        Button(p.0) { choose(CLLocationCoordinate2D(latitude: p.1, longitude: p.2), zoom: true) }
                    }
                }
                .fixedSize()
            }
            MapReader { proxy in
                Map(position: $position) {
                    if let c = mac.coordinate {
                        Annotation("This Mac", coordinate: c) {
                            Image(systemName: "laptopcomputer").font(.caption).padding(4)
                                .background(.gray, in: Circle()).foregroundStyle(.white)
                        }
                    }
                    if let last = tools.lastSimulated, !isActive {
                        Marker("Last simulated", systemImage: "clock.arrow.circlepath", coordinate: last).tint(.gray)
                    }
                    if let pin { Marker("", coordinate: pin).tint(.red) }
                    if case .active(let c) = tools.locationState {
                        Annotation("iPhone", coordinate: c) {
                            Image(systemName: "iphone.gen3").padding(4).background(.blue, in: Circle()).foregroundStyle(.white)
                        }
                    }
                }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { choose(c, zoom: false) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 260)
            HStack {
                TextField("Latitude", text: $latText).textFieldStyle(.roundedBorder)
                TextField("Longitude", text: $lonText).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Set location") {
                    if let c = coordinateFromFields() { tools.setLocation(c) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(coordinateFromFields() == nil || tools.locationState == .starting)
                Button("Restore real") { Task { await tools.clearLocation() } }
                    .disabled(tools.locationState == .off)
                Spacer()
                locationStatus
            }
            macStatus
            Text("Click the map to pick a point. The location stays simulated while the window is open; closing it restores the real one. The iPhone does not tell the Mac its real location: the map starts from the Mac, which is nearby, or from the last simulated location.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .onAppear(perform: initialCamera)
        .onChange(of: mac.coordinate?.latitude) { _, _ in
            // First fix of the Mac's position: follow it unless something better is already shown.
            if !userMoved, !isActive, tools.lastSimulated == nil, let c = mac.coordinate { focus(c, span: 0.02) }
        }
    }

    private var isActive: Bool {
        if case .active = tools.locationState { return true }
        return false
    }

    @ViewBuilder private var macStatus: some View {
        switch mac.status {
        case .denied:
            Text("Mac location unavailable: allow it in System Settings ▸ Privacy & Security ▸ Location Services ▸ PMD3Bar.")
                .font(.caption2).foregroundStyle(.orange)
        case .failed(let msg):
            Text("Mac location unavailable (\(msg)).").font(.caption2).foregroundStyle(.orange)
        case .locating:
            Label("Finding the Mac's location…", systemImage: "location").font(.caption2).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// Start from what is known about the iPhone: its active simulated position, the last one
    /// simulated, or else the Mac's position (asked now, applied when it arrives).
    private func initialCamera() {
        if case .active(let c) = tools.locationState {
            focus(c, span: 0.02)
        } else if let last = tools.lastSimulated {
            focus(last, span: 0.02)
        } else if let c = mac.coordinate {
            focus(c, span: 0.02)
        }
        mac.refresh()
    }

    private func centerOnMac() {
        guard let c = mac.coordinate else { mac.refresh(); return }
        choose(c, zoom: true)
    }

    private func focus(_ c: CLLocationCoordinate2D, span: Double) {
        position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }

    @ViewBuilder private var locationStatus: some View {
        switch tools.locationState {
        case .off: EmptyView()
        case .starting: ProgressView().controlSize(.small)
        case .active: Label("Active", systemImage: "location.fill").foregroundStyle(.blue).font(.caption)
        case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func choose(_ c: CLLocationCoordinate2D, zoom: Bool) {
        userMoved = true
        pin = c
        latText = String(format: "%.6f", c.latitude)
        lonText = String(format: "%.6f", c.longitude)
        if zoom {
            position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        }
    }

    private func coordinateFromFields() -> CLLocationCoordinate2D? {
        let norm = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
        guard let lat = norm(latText), let lon = norm(lonText), (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func geocode() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = search
        Task {
            if let item = try? await MKLocalSearch(request: request).start().mapItems.first {
                choose(item.placemark.coordinate, zoom: true)
            }
        }
    }
}
