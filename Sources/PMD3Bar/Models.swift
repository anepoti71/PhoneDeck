import Foundation

struct Device: Identifiable, Hashable {
    let id: String          // UniqueDeviceID
    var name: String
    var productVersion: String
    var productType: String
    var connections: Set<String>  // connections that answered lockdown: "USB", "Network"
    var unreachableError: String? // set when usbmuxd lists the device but no connection answers

    var reachable: Bool { !connections.isEmpty }
    var hasUSB: Bool { connections.contains("USB") }

    var connectionLabel: String {
        guard reachable else { return "non raggiungibile" }
        return connections.sorted().map { $0 == "Network" ? "Wi-Fi" : $0 }.joined(separator: " + ")
    }

    /// Parses `pmd3bar_helper.py list` JSON: one entry per usbmux connection, each with its own error.
    static func parseHelperList(_ data: Data) -> [Device] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var byID: [String: Device] = [:]
        var order: [String] = []
        for item in items {
            guard let udid = item["udid"] as? String else { continue }
            let conn = item["connection"] as? String ?? "?"
            let error = item["error"] as? String
            if byID[udid] == nil {
                order.append(udid)
                byID[udid] = Device(id: udid, name: "iPhone", productVersion: "?", productType: "?",
                                    connections: [], unreachableError: nil)
            }
            if let error {
                byID[udid]!.unreachableError = byID[udid]!.unreachableError ?? "\(conn == "Network" ? "Wi-Fi" : conn): \(error)"
                continue
            }
            byID[udid]!.connections.insert(conn)
            if let name = item["name"] as? String { byID[udid]!.name = name }
            if let v = item["version"] as? String { byID[udid]!.productVersion = v }
            if let t = item["product_type"] as? String { byID[udid]!.productType = t }
        }
        for id in order where byID[id]!.reachable { byID[id]!.unreachableError = nil }
        // Reachable first, then USB: mounting and mirroring are faster and steadier over USB.
        func rank(_ d: Device) -> Int { d.reachable ? (d.hasUSB ? 0 : 1) : 2 }
        return order.compactMap { byID[$0] }.sorted { rank($0) < rank($1) }
    }
}

enum MountState: Equatable {
    case unknown, checking, mounted, notMounted, mounting
    case failed(String)
}

enum MirrorState: Equatable {
    case stopped, starting, running, stopping
    case failed(String)
}

/// True if `pymobiledevice3 mounter list` reports a developer image (cryptex DDIs show up as Personalized too).
func isDeveloperImageMounted(_ data: Data) -> Bool {
    guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
    return items.contains { item in
        let type = item["DiskImageType"] as? String
        let personalized = item["PersonalizedImageType"] as? String
        let mounted = (item["IsMounted"] as? Bool) ?? true
        return mounted && (personalized == "DeveloperDiskImage" || type == "Developer"
            || (item["MountPath"] as? String) == "/System/Developer"
            || (item["MountPath"] as? String) == "/Developer")
    }
}
