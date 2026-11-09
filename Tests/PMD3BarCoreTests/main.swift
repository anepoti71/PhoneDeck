// Tests for PMD3BarCore. Run with `make test` (swift run PMD3BarCoreTests).
// A minimal harness: XCTest and swift-testing are not part of the Command Line Tools.
import Foundation
import PMD3BarCore

var passed = 0
var failures: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
    if condition() { passed += 1 } else { failures.append("\(name)  (\(file):\(line))") }
}

func suite(_ name: String, _ body: () -> Void) {
    let before = failures.count
    body()
    print("\(failures.count == before ? "✓" : "✗") \(name)")
}

func json(_ s: String) -> Data { Data(s.utf8) }

suite("Device.parseHelperList") {
    // Same iPhone over USB and Wi-Fi, an iOS 26 iPhone, and one that does not answer.
    let list = Device.parseHelperList(json("""
    [{"udid":"A","connection":"Network","name":"iPhone 16","version":"27.2","product_type":"iPhone17,1","error":null},
     {"udid":"B","connection":"Network","name":"iPhone 13","version":"26.3.1","product_type":"iPhone14,5","error":null},
     {"udid":"C","connection":"Network","name":null,"version":null,"product_type":null,"error":"timeout"},
     {"udid":"A","connection":"USB","name":"iPhone 16","version":"27.2","product_type":"iPhone17,1","error":null},
     {"udid":"B","connection":"USB","name":null,"version":null,"product_type":null,"error":"timeout"}]
    """))
    check(list.map(\.id) == ["A", "B", "C"], "reachable first, USB first, unreachable last")
    check(list[0].connections == ["USB", "Network"], "USB and Wi-Fi merged into one device")
    check(list[0].connectionLabel == "Wi-Fi + USB", "connection label")
    check(list[1].connections == ["Network"] && list[1].unreachableError == nil,
          "a failing link is dropped when another one answers")
    check(!list[2].reachable && list[2].unreachableError == "Wi-Fi: timeout", "unreachable device keeps its error")
    check(list[2].connectionLabel == "non raggiungibile", "unreachable label")
    check(list[0].supportsMirroring, "iOS 27.2 can be mirrored")
    check(!list[1].supportsMirroring, "iOS 26.3.1 cannot be mirrored")
    check(Device.parseHelperList(json("not json")).isEmpty, "invalid JSON gives no devices")
    check(Device.parseHelperList(json("[]")).isEmpty, "empty list")
}

suite("isDeveloperImageMounted") {
    check(isDeveloperImageMounted(json("""
    [{"DiskImageType":"Personalized","IsMounted":true,"MountPath":"/System/Developer","PersonalizedImageType":"DeveloperDiskImage"}]
    """)), "personalized / cryptex DDI")
    check(isDeveloperImageMounted(json("""
    [{"DiskImageType":"Developer","IsMounted":true,"ImageSignature":"x"}]
    """)), "legacy Developer image (pre-iOS 14 listing)")
    check(!isDeveloperImageMounted(json("[]")), "nothing mounted")
    check(!isDeveloperImageMounted(json("""
    [{"DiskImageType":"Personalized","IsMounted":false,"PersonalizedImageType":"DeveloperDiskImage"}]
    """)), "listed but not mounted")
    check(!isDeveloperImageMounted(json("garbage")), "invalid JSON")
}

suite("RunResult.errorSummary") {
    let boxed = RunResult(status: 1, stdout: Data(), stderr: """
    ╭─ Error ─────────────╮
    │ No such option: --udid 1234 │
    ╰─────────────────────╯
    """)
    check(boxed.errorSummary == "No such option: --udid 1234", "rich error box is unwrapped")
    check(RunResult(status: 2, stdout: Data(), stderr: "").errorSummary == "Comando fallito (exit 2)", "empty stderr")
    check(RunResult(status: 0, stdout: Data(), stderr: "").ok, "exit 0 is ok")
    let log = RunResult(status: 1, stdout: Data(), stderr: "line one\nINFO trying again\nERROR Device not found\n")
    check(log.errorSummary == "INFO trying again ERROR Device not found", "last two lines")
}

suite("Versions.isVersion(_:newerThan:)") {
    check(Versions.isVersion("11.51.0", newerThan: "11.50.3"), "minor bump")
    check(Versions.isVersion("12.0.0", newerThan: "11.99.99"), "major bump")
    check(Versions.isVersion("11.50.10", newerThan: "11.50.9"), "numeric, not lexicographic")
    check(!Versions.isVersion("11.50.3", newerThan: "11.50.3"), "equal")
    check(!Versions.isVersion("11.2.0", newerThan: "11.50.3"), "older")
    check(!Versions.isVersion("11.51", newerThan: "11.51.0"), "missing part counts as 0")
    check(Versions.isVersion("11.51.0rc1", newerThan: "11.50.3"), "suffix ignored")
    check(!Versions.isVersion("…", newerThan: "11.50.3"), "version not loaded yet")
}

suite("ViewerLayout.viewportWidth") {
    // iPhone portrait screen 1179 x 2556 in a viewport 824 px high.
    let w = ViewerLayout.viewportWidth(forHeight: 824, ratio: 1179.0 / 2556.0)
    check(abs(w - (88 + 800 * 1179.0 / 2556.0)) < 0.001, "portrait")
    let landscape = ViewerLayout.viewportWidth(forHeight: 500, ratio: 2556.0 / 1179.0)
    check(landscape > 500, "landscape is wider than tall")
    check(ViewerLayout.viewportWidth(forHeight: 10, ratio: 0.5) == 88 + 100 * 0.5, "tiny heights clamp to 100")
}

suite("DeviceDates.parse") {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let d = DeviceDates.parse("2026-11-09T11:05:09.123456")
    check(d != nil, "naive time with microseconds")
    if let d {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        check(c.year == 2026 && c.month == 11 && c.day == 9 && c.hour == 11 && c.minute == 5 && c.second == 9,
              "read as local time")
    }
    check(DeviceDates.parse("2021-09-24T11:05:18") != nil, "without fraction")
    check(DeviceDates.parse("2026-11-09T11:47:59.777170+00:00") != nil, "with time zone")
    check(DeviceDates.parse(nil) == nil && DeviceDates.parse("") == nil, "missing")
    check(DeviceDates.parse("ieri") == nil, "garbage")
}

print("\n\(passed) controlli superati, \(failures.count) falliti")
for f in failures { print("  ✗ \(f)") }
exit(failures.isEmpty ? 0 : 1)
