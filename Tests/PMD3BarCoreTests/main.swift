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
    check(list[2].connectionLabel == "unreachable", "unreachable label")
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
    check(RunResult(status: 2, stdout: Data(), stderr: "").errorSummary == "Command failed (exit 2)", "empty stderr")
    check(RunResult(status: 0, stdout: Data(), stderr: "").ok, "exit 0 is ok")
    let log = RunResult(status: 1, stdout: Data(), stderr: "line one\nINFO trying again\nERROR Device not found\n")
    check(log.errorSummary == "INFO trying again ERROR Device not found", "last two lines")
    let pmd3 = RunResult(status: 1, stdout: Data(), stderr: """
    2026-11-10 14:00:45 Some-Mac.local __main__[97101] ERROR The device refused to open the container of com.x: InstallationLookupFailed.
    Please report it at https://github.com/doronz88/pymobiledevice3/issues, with the output of the same command run with -v (`pymobiledevice3 -v ...`), so support for it can be added.
    2026-11-10 14:00:45 Some-Mac.local __main__[97101] INFO Run again with -v for the full traceback (include it when reporting an issue)
    """)
    check(pmd3.errorSummary == "The device refused to open the container of com.x: InstallationLookupFailed.",
          "pymobiledevice3 log line: message only, hints dropped")
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
    check(abs(w - (28 + (824 - 28) * 1179.0 / 2556.0)) < 0.001, "portrait: device fills the height, margin on both sides")
    let landscape = ViewerLayout.viewportWidth(forHeight: 500, ratio: 2556.0 / 1179.0)
    check(landscape > 500, "landscape is wider than tall")
    check(ViewerLayout.viewportWidth(forHeight: 10, ratio: 0.5) == 28 + 100 * 0.5, "tiny heights clamp to 100")
}

suite("PasscodeKeypad") {
    // iPhone 15/16: 1179 x 2556 px, @3x, 393 pt wide.
    check(PasscodeKeypad.pointWidth(pixelWidth: 1179) == 393, "@3x stream")
    check(PasscodeKeypad.pointWidth(pixelWidth: 828) == 414, "@2x stream (iPhone 11)")
    check(PasscodeKeypad.pointWidth(pixelWidth: 600) == 390, "scaled stream falls back to 390 pt")
    let keys = PasscodeKeypad.keys(width: 1179, height: 2556)
    check(keys.map(\.digit) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"], "ten keys, phone order")
    check(abs(keys[1].x - 0.5) < 1e-9 && abs(keys[9].x - 0.5) < 1e-9, "middle column centred")
    check(abs((keys[2].x - keys[1].x) * 393 - 104) < 1e-6, "column pitch in points")
    check(abs((keys[3].y - keys[0].y) * 2556 / 3 - 90) < 1e-6, "row pitch in points")
    check(abs((keys[4].y + keys[7].y) / 2 - PasscodeKeypad.defaultCenterY) < 1e-9, "keypad centred on centerY")
    check(abs(keys[0].r * 393 - 38) < 1e-6, "key radius in points")
    check(PasscodeKeypad.keys(width: 2556, height: 1179).isEmpty, "no keypad in landscape")
    check(PasscodeKeypad.keys(width: 0, height: 0).isEmpty, "no keypad before the size is known")
    let clamped = PasscodeKeypad.keys(width: 1179, height: 2556, centerY: 5)
    check(abs((clamped[4].y + clamped[7].y) / 2 - 0.8) < 1e-9, "centerY clamped")
    check(PasscodeKeypad.json(Array(keys.prefix(1))).hasPrefix("[{"), "JSON array")
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

func profile(_ appID: String, devices: [String] = ["UDID-1"], expires: TimeInterval = 86_400,
             certs: [Data] = [Data("cert-A".utf8)], extra: [String: Any] = [:]) -> ProvisioningProfile {
    var ent: [String: Any] = ["application-identifier": "TEAM1." + appID, "get-task-allow": true,
                              "keychain-access-groups": ["TEAM1.*", "com.apple.token"]]
    ent.merge(extra) { $1 }
    return ProvisioningProfile(plist: [
        "Name": "P " + appID, "UUID": "u-" + appID, "TeamIdentifier": ["TEAM1"],
        "ExpirationDate": Date(timeIntervalSinceNow: expires), "ProvisionedDevices": devices,
        "DeveloperCertificates": certs, "Entitlements": ent,
    ])!
}

func ipa(_ bundleID: String, signature: IPAInfo.Signature = .signed(team: "TEAM1"),
         entitlements: [String: Any] = [:], profile: ProvisioningProfile? = nil,
         signer: String? = nil, extensions: [String] = []) -> IPAInfo {
    IPAInfo(bundleID: bundleID, name: "App", version: "1.0", signature: signature, entitlements: entitlements,
            profile: profile, signerSHA1: signer, extensionIDs: extensions)
}

suite("ProvisioningProfile") {
    let p = profile("com.acme.app")
    check(p.teamID == "TEAM1" && p.bundlePattern == "com.acme.app" && !p.isWildcard, "explicit App ID")
    check(p.covers(bundleID: "com.acme.app") && !p.covers(bundleID: "com.acme.app2"), "covers only its bundle ID")
    check(p.includes(udid: "udid-1") && !p.includes(udid: "UDID-2"), "devices, case-insensitive")
    check(p.certificateSHA1s == [Signing.sha1(Data("cert-A".utf8))], "certificate SHA-1")
    let w = profile("*")
    check(w.isWildcard && w.covers(bundleID: "anything.at.all"), "wildcard App ID")
    check(ProvisioningProfile(plist: ["Name": "x"]) == nil, "incomplete plist")
}

suite("Signing.issues") {
    let ok = profile("com.acme.app")
    check(Signing.issues(ipa("com.acme.app", profile: ok), udid: "UDID-1").isEmpty, "valid app installs")
    check(Signing.issues(ipa("x", signature: .adhoc), udid: "UDID-1") == [.adhoc], "ad-hoc (the WQFiles case)")
    check(Signing.issues(ipa("x", signature: .unsigned), udid: "UDID-1") == [.unsigned], "unsigned")
    check(Signing.issues(ipa("com.acme.app"), udid: "UDID-1") == [.noProfile], "signed without profile")
    check(Signing.issues(ipa("com.acme.app", profile: ok), udid: "UDID-9") == [.deviceNotInProfile],
          "iPhone not registered")
    let old = profile("com.acme.app", expires: -60)
    check(Signing.issues(ipa("com.acme.app", profile: old), udid: "UDID-1") == [.profileExpired(old.expiration)],
          "expired profile")
    check(Signing.issues(ipa("com.other", profile: ok), udid: "UDID-1") == [.bundleIDNotCovered(appID: "TEAM1.com.acme.app")],
          "profile for another App ID")
    check(Signing.issues(ipa("com.acme.app", profile: ok, signer: "FFFF"), udid: "UDID-1") == [.certificateNotInProfile],
          "signed with a certificate the profile doesn't list")
    let groups: [String: Any] = ["com.apple.security.application-groups": ["group.com.acme"]]
    check(Signing.issues(ipa("com.acme.app", entitlements: groups, profile: ok), udid: "UDID-1")
          == [.entitlementsNotAllowed(["com.apple.security.application-groups"])], "app group not in profile")
    let withGroup = profile("com.acme.app", extra: groups)
    check(Signing.issues(ipa("com.acme.app", entitlements: groups.merging(["get-task-allow": true]) { $1 },
                             profile: withGroup), udid: "UDID-1").isEmpty, "app group granted")
    check(Signing.deniedEntitlements(["keychain-access-groups": ["TEAM1.com.acme.app"]],
                                     allowed: ok.entitlements).isEmpty, "keychain group matches TEAM1.*")
    check(Signing.deniedEntitlements(["get-task-allow": true], allowed: ["get-task-allow": false])
          == ["get-task-allow"], "debuggable app with a distribution profile")
}

suite("Signing.parseIdentities") {
    let ids = Signing.parseIdentities("""
      1) B3B000C5E3E9088070697149468EFCAD19F94515 "Developer ID Application: A B (TEAM1)"
      2) 1a698226cb854173d20ad2a0482080ac525ef8af "Apple Development: A B (XYZ)"
      3) 1A698226CB854173D20AD2A0482080AC525EF8AF "Apple Development: A B (XYZ)"
         3 valid identities found
    """)
    check(ids == [SigningIdentity(sha1: "1A698226CB854173D20AD2A0482080AC525EF8AF", name: "Apple Development: A B (XYZ)")],
          "iOS identities only, uppercased, deduplicated")
}

suite("Signing.plans") {
    let certA = Data("cert-A".utf8)
    let me = SigningIdentity(sha1: Signing.sha1(certA), name: "Apple Development: Me")
    let app = ipa("com.acme.app", signature: .adhoc, extensions: ["com.acme.app.widget"])
    let exact = profile("com.acme.app", expires: 1000)
    let wild = profile("*", expires: 5000)
    let other = profile("com.me.wqfiles", expires: 9000)
    let plans = Signing.plans(for: app, udid: "UDID-1", profiles: [other, wild, exact], identities: [me])
    check(plans.map(\.profile.uuid) == [exact.uuid, wild.uuid, other.uuid], "own App ID, wildcard, then another App ID")
    check(!plans[0].changesBundleID && plans[0].droppedExtensions == ["com.acme.app.widget"], "explicit profile drops extensions")
    check(plans[1].droppedExtensions.isEmpty, "wildcard keeps extensions")
    check(plans[2].bundleID == "com.me.wqfiles" && plans[2].changesBundleID, "another App ID changes the bundle ID")
    check(Signing.plans(for: app, udid: "UDID-9", profiles: [exact, wild], identities: [me]).isEmpty, "iPhone not in any profile")
    check(Signing.plans(for: app, udid: "UDID-1", profiles: [exact], identities: []).isEmpty, "no identity in the keychain")
    check(Signing.plans(for: app, udid: "UDID-1", profiles: [profile("com.acme.app", expires: -1)], identities: [me]).isEmpty,
          "expired profile")
    check(Signing.plans(for: app, udid: "UDID-1", profiles: [profile("com.acme.app", certs: [Data("cert-B".utf8)])],
                        identities: [me]).isEmpty, "profile for another certificate")
    check(Signing.extensionID("com.acme.app.widget", from: "com.acme.app", to: "com.me.x") == "com.me.x.widget",
          "extension follows the new bundle ID")
}

suite("Signing.entitlements") {
    let p = profile("*", extra: ["com.apple.security.application-groups": ["group.com.acme", "group.*"],
                                 "com.apple.developer.associated-domains": "*"])
    let e = Signing.entitlements(for: "com.acme.app", profile: p)
    check(e["application-identifier"] as? String == "TEAM1.com.acme.app", "application-identifier expanded")
    check(e["keychain-access-groups"] as? [String] == ["TEAM1.com.acme.app", "com.apple.token"], "keychain wildcard expanded")
    check(e["com.apple.security.application-groups"] as? [String] == ["group.com.acme"], "wildcard group left out")
    check(e["com.apple.developer.associated-domains"] == nil, "wildcard-only entitlement left out")
    check(e["get-task-allow"] as? Bool == true, "get-task-allow kept")
    check(Signing.deniedEntitlements(e, allowed: p.entitlements).isEmpty, "result is allowed by the profile")
}

suite("Signing.requirements") {
    let me = SigningIdentity(sha1: "AA", name: "Apple Development: Me")
    let ent: [String: Any] = ["com.apple.security.application-groups": ["group.com.acme"],
                              "aps-environment": "development", "get-task-allow": true,
                              "com.apple.developer.icloud-services": ["CloudKit"],
                              "com.apple.developer.icloud-container-identifiers": ["iCloud.com.acme"]]
    let app = ipa("com.acme.app", signature: .adhoc, entitlements: ent, extensions: ["com.acme.app.share"])
    let r = Signing.requirements(for: app, udid: "UDID-7", identities: [me])
    check(r.hasIdentity && r.needsExplicitAppID, "identity found, explicit App ID needed")
    check(r.capabilities == ["Push Notifications", "iCloud", "App Groups"], "capabilities by portal name, once each")
    check(r.appGroups == ["group.com.acme"], "app groups to create")
    let text = r.steps.joined(separator: "\n")
    check(text.contains("UDID-7"), "steps name the iPhone")
    check(text.contains("explicit App ID com.acme.app with Push Notifications, iCloud, App Groups"), "steps name the App ID")
    check(text.contains("create group.com.acme"), "steps name the app group")
    check(text.contains("com.acme.app.share"), "steps name the extensions")
    let plain = Signing.requirements(for: ipa("com.acme.plain", signature: .adhoc), udid: "U", identities: [])
    check(!plain.hasIdentity && !plain.needsExplicitAppID, "plain app: wildcard App ID is enough, no identity")
    check(plain.steps[0].hasPrefix("Certificate: create"), "asks to create the certificate")
}

suite("Signing.rejection / missingCapabilities") {
    let me = SigningIdentity(sha1: Signing.sha1(Data("cert-A".utf8)), name: "Apple Development: Me")
    let app = ipa("com.acme.app", signature: .adhoc,
                  entitlements: ["com.apple.security.application-groups": ["group.com.acme"]])
    let exact = profile("com.acme.app")
    check(Signing.rejection(of: profile("com.acme.app", expires: -1), for: app, udid: "UDID-1", identities: [me]) == "expired",
          "expired")
    check(Signing.rejection(of: exact, for: app, udid: "UDID-2", identities: [me]) == "this iPhone is not in it", "device")
    check(Signing.rejection(of: exact, for: app, udid: "UDID-1", identities: []) == "none of its certificates is in your keychain",
          "certificate")
    check(Signing.rejection(of: exact, for: app, udid: "UDID-1", identities: [me]) == nil, "usable")
    let other = profile("com.me.wqfiles", extra: ["com.apple.security.application-groups": ["group.com.me.wqfiles"]])
    let plan = Signing.plans(for: app, udid: "UDID-1", profiles: [other], identities: [me])[0]
    check(Signing.missingCapabilities(app, plan: plan) == ["App Groups"], "another app's group doesn't grant this one")
    let withGroup = profile("com.acme.app", extra: ["com.apple.security.application-groups": ["group.com.acme"]])
    let good = Signing.plans(for: app, udid: "UDID-1", profiles: [withGroup], identities: [me])[0]
    check(Signing.missingCapabilities(app, plan: good).isEmpty, "matching profile grants everything")
}

suite("DeviceInfo.parse") {
    let info = DeviceInfo.parse(json("""
    {"device":{"DeviceName":"iPhone di Test","ProductType":"iPhone17,1","ProductVersion":"27.2","BuildVersion":"24C5",
               "SerialNumber":"F00","UniqueDeviceID":"U-1","ModelNumber":"MN0X3","RegionInfo":"ZD/A","WiFiAddress":""},
     "disk":{"TotalDataCapacity":100,"AmountDataAvailable":25,"TotalDataAvailable":60,"TotalDiskCapacity":128},
     "battery":{"CurrentCapacity":80,"IsCharging":true,"ExternalConnected":true,"CycleCount":312,
                "DesignCapacity":4000,"NominalChargeCapacity":3540,"AppleRawMaxCapacity":3600,"Temperature":2950},
     "errors":[]}
    """))
    check(info != nil, "parses")
    guard let info else { return }
    check(info.rows.first == .init(label: "Name", value: "iPhone di Test"), "name first")
    check(info.rows.contains(.init(label: "Model number", value: "MN0X3ZD/A")), "model number joined with region")
    check(!info.rows.contains { $0.label == "Wi-Fi address" }, "empty values hidden")
    check(info.storage == .init(total: 100, available: 25, availableWithPurgeable: 60) && info.storage?.usedFraction == 0.75,
          "storage: data partition, free now and with purgeable data")
    let tight = DeviceInfo.parse(json(#"{"disk":{"TotalDataCapacity":100,"AmountDataAvailable":25,"TotalDataAvailable":25}}"#))
    check(tight?.storage?.availableWithPurgeable == nil, "no purgeable line when it adds nothing")
    check(info.battery?.percent == 80 && info.battery?.charging == true, "charge")
    check(info.battery?.health == 89, "health from nominal / design capacity")
    check(info.battery?.temperatureC == 29.5, "temperature in hundredths of a degree")
    check(info.battery?.cycles == 312, "cycles")
    let bare = DeviceInfo.parse(json(#"{"device":{},"disk":{},"battery":{},"errors":["battery: Timeout"]}"#))
    check(bare?.storage == nil && bare?.battery == nil && bare?.errors == ["battery: Timeout"], "missing parts")
    let raw = DeviceInfo.parse(json(#"{"battery":{"DesignCapacity":3000,"AppleRawMaxCapacity":3300}}"#))
    check(raw?.battery?.health == 110, "falls back to raw max capacity")
    check(DeviceInfo.parse(json("[]")) == nil, "not an object")
}

suite("LaunchOptions") {
    let o = LaunchOptions(arguments: #"-FIRDebugEnabled "two words" 'single $x' a\ b"#,
                          environment: "API_URL=https://x.test/?a=b\n\n# comment\nDEBUG=1", killExisting: false)
    check((try? o.parsedArguments()) == ["-FIRDebugEnabled", "two words", "single $x", "a b"], "shell-like split")
    check((try? o.parsedEnvironment()) == ["API_URL=https://x.test/?a=b", "DEBUG=1"], "env lines, comments skipped")
    check((try? o.command(bundleID: "com.acme")) == [
        "developer", "core-device", "launch-application", "--env", "API_URL=https://x.test/?a=b", "--env", "DEBUG=1",
        "--no-kill-existing", "--", "com.acme", "-FIRDebugEnabled", "two words", "single $x", "a b"],
          "options before --, app arguments after")
    check((try? LaunchOptions(arguments: #""open"#).parsedArguments()) == nil, "unclosed quote")
    check((try? LaunchOptions(arguments: #""""#).parsedArguments()) == [""], "empty quoted argument kept")
    do {
        _ = try LaunchOptions(environment: "OK=1\nnot a var").parsedEnvironment()
        check(false, "bad env line rejected")
    } catch let e as LaunchOptions.ParseError {
        check(e == .badVariable(line: 2, text: "not a var"), "bad env line reports line")
    } catch { check(false, "error type") }
    check((try? LaunchOptions(environment: "1X=2").parsedEnvironment()) == nil, "name can't start with digit")
    check((try? LaunchOptions(environment: "=2").parsedEnvironment()) == nil, "empty name")
    check(LaunchOptions().isEmpty && !LaunchOptions(killExisting: false).isEmpty, "isEmpty")
}

suite("FilesScope") {
    let media = FilesScope.media
    check(!media.canGoUp(from: "/") && media.canGoUp(from: "/DCIM") && media.parent(of: "/DCIM/100APPLE") == "/DCIM",
          "media navigation")
    check(media.parent(of: "/DCIM") == "/", "parent of top folder is root")
    let docs = FilesScope.app(bundleID: "com.acme", documentsOnly: true)
    check(docs.root == "/Documents" && !docs.canGoUp(from: "/Documents") && !docs.canGoUp(from: "/Documents/"),
          "documents root")
    check(docs.parent(of: "/Documents/a/b") == "/Documents/a" && docs.parent(of: "/Library") == "/Documents",
          "never above Documents")
    check(docs.appFlags == ["--documents"] && FilesScope.app(bundleID: "x", documentsOnly: false).appFlags.isEmpty,
          "documents flag")
    check(docs.bundleID == "com.acme" && media.bundleID == nil, "bundle id")
}

suite("LaunchOptions.console") {
    let o = LaunchOptions(console: true)
    check((try? o.command(bundleID: "a")) == ["developer", "core-device", "launch-application",
                                              "--env", "NSUnbufferedIO=YES", "--env", "OS_ACTIVITY_DT_MODE=YES",
                                              "--kill-existing", "--console", "--", "a"],
          "--console before --, unbuffered stdout and os_log mirrored")
    let mine = LaunchOptions(environment: "OS_ACTIVITY_DT_MODE=NO", console: true)
    check((try? mine.command(bundleID: "a"))?.filter { $0.contains("=") } == ["OS_ACTIVITY_DT_MODE=NO", "NSUnbufferedIO=YES"],
          "user's variables win")
    check((try? LaunchOptions().command(bundleID: "a"))?.contains("--env") == false, "no console, no extra variables")
    check(!o.isEmpty, "console makes options non-default")
    let old = try? JSONDecoder().decode(LaunchOptions.self, from: json(#"{"arguments":"-x","environment":"","killExisting":false}"#))
    check(old == LaunchOptions(arguments: "-x", killExisting: false), "options saved before console decode")
}

suite("ConsoleBuffer") {
    var b = ConsoleBuffer(limit: 3)
    b.append(Data("one\ntw".utf8))
    check(b.lines.map(\.text) == ["one"], "partial line held")
    b.append(Data("o\r\nthree\n".utf8))
    check(b.lines.map(\.text) == ["one", "two", "three"], "joined across chunks, CRLF trimmed")
    let euro = Array("€\n".utf8)  // a 3-byte character split between two chunks
    b.append(Data(euro[0..<1]))
    b.append(Data(euro[1...]))
    check(b.lines.map(\.text) == ["two", "three", "€"], "UTF-8 split across chunks, oldest dropped at limit")
    check(b.lines.map(\.id) == [1, 2, 3], "ids keep increasing")
    b.append(Data("tail".utf8))
    b.finish()
    check(b.lines.last?.text == "tail", "tail kept at end of stream")
    b.removeAll()
    check(b.lines.isEmpty && b.text.isEmpty, "cleared")
}

suite("CaptureStats / WebDAVOutput") {
    let out = """
    {"seconds": 0.0, "packets": 0, "bytes": 0, "processes": [], "interfaces": []}
    {"seconds": 6.1, "packets": 90, "bytes": 23184, "processes": [{"name": "trustd (2907)", "packets": 22, "bytes": 1742}], "interfaces": [{"name": "en0", "packets": 90, "bytes": 23184}]}
    {"seconds": 6.3, "packets": 9
    """
    let s = CaptureStats.last(in: out)
    check(s?.packets == 90 && s?.processes.first?.name == "trustd (2907)" && s?.interfaces.first?.bytes == 23184,
          "last complete line wins over a truncated one")
    check(CaptureStats.last(in: "") == nil, "nothing yet")
    let w = "WebDAV server serving '/' at http://127.0.0.1:49944/\nMounted; revealed /var/folders/x/T/pmd-U-com.a-vdub\nPress Ctrl-C to stop.\n"
    check(WebDAVOutput.mountPath(in: w) == "/var/folders/x/T/pmd-U-com.a-vdub", "mount path")
    check(WebDAVOutput.mountPath(in: "WebDAV server serving") == nil, "not mounted yet")
    check(WebDAVOutput.mountUnavailable(in: "Automatic mount is unavailable on this host"), "mount unavailable")
}

suite("Safety: bundle IDs, profile UUIDs, file names") {
    check(Safety.isBundleID("com.example.App-2"), "normal bundle ID")
    check(!Safety.isBundleID("com.x/../../.ssh/authorized_keys"), "slash and dot-dot rejected")
    check(!Safety.isBundleID("com.x\nssh-ed25519 AAAA"), "newline rejected")
    check(!Safety.isBundleID("") && !Safety.isBundleID("..") && !Safety.isBundleID("."), "empty and dots rejected")
    check(!Safety.isBundleID(String(repeating: "a", count: 256)), "too long")
    check(Safety.isProfileUUID("6B8C9E2A-1F3D-4C5B-9A7E-0D1C2B3A4F5E"), "profile UUID")
    check(!Safety.isProfileUUID("../../../Library/LaunchAgents/x"), "path as UUID rejected")
    check(!Safety.isProfileUUID("6B8C9E2A1F3D4C5B9A7E0D1C2B3A4F5E"), "UUID without dashes rejected")
    check(Safety.isSafeFileName("Photo 1.jpg"), "plain name")
    check(!Safety.isSafeFileName("../x") && !Safety.isSafeFileName("a/b") && !Safety.isSafeFileName(".."), "traversal")
    check(!Safety.isSafeFileName("a\0b") && !Safety.isSafeFileName(""), "NUL and empty")
    check(Safety.fileName("../../Library/LaunchAgents/x.plist", fallback: "f") == "..-..-Library-LaunchAgents-x.plist",
          "separators replaced")
    check(Safety.fileName("..", fallback: "iPhone") == "iPhone" && Safety.fileName("  ", fallback: "iPhone") == "iPhone",
          "dot-only and blank fall back")
}

suite("Safety: viewer ports") {
    check(Safety.firstFreePort(from: 8080, used: [], isFree: { _ in true }) == 8080, "start port when free")
    check(Safety.firstFreePort(from: 8080, used: [8080], isFree: { $0 != 8081 }) == 8082, "skips used and busy")
    check(Safety.firstFreePort(from: 70000, used: [], isFree: { _ in true }) == 65535, "clamped to 65535, no crash")
    check(Safety.firstFreePort(from: 80, used: [], isFree: { _ in true }) == 1024, "clamped to 1024")
    check(Safety.firstFreePort(from: 65535, used: [65535], isFree: { _ in true }) == nil, "none left")
}

suite("Safety: viewer navigation") {
    let viewer = URL(string: "http://127.0.0.1:8080/")!
    check(Safety.isViewerURL(viewer, port: 8080), "viewer origin")
    check(!Safety.isViewerURL(viewer, port: 8081), "another port")
    check(!Safety.isViewerURL(URL(string: "http://localhost:8080/")!, port: 8080), "another host name")
    check(!Safety.isViewerURL(URL(string: "file:///127.0.0.1/x")!, port: 8080), "file URL")
    check(Safety.mayOpenExternally(URL(string: "https://github.com/x")!, userClicked: true), "clicked web link")
    check(!Safety.mayOpenExternally(URL(string: "https://github.com/x")!, userClicked: false), "scripted navigation")
    check(!Safety.mayOpenExternally(URL(string: "file:///Users/Shared/evil.app")!, userClicked: true), "file URL")
    check(!Safety.mayOpenExternally(URL(string: "x-apple.systempreferences:com.apple")!, userClicked: true), "custom scheme")
}

suite("MacPaste") {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
    check(MacPaste.payload(text: "ciao", png: png) == .success(.text("ciao")), "text wins over an image")
    check(MacPaste.payload(text: " \n", png: nil) == .success(.text(" \n")), "whitespace is pasted as is")
    check(MacPaste.payload(text: "", png: png) == .success(.png(png)), "image when there is no text")
    check(MacPaste.payload(text: nil, png: nil) == .failure(.empty), "nothing to paste")
    check(MacPaste.payload(text: nil, png: Data([1, 2, 3])) == .failure(.empty), "not a PNG")
    let big = png + Data(count: MacPaste.maxBytes)
    check(MacPaste.payload(text: nil, png: big) == .failure(.tooLarge(bytes: big.count)), "image over the limit")
    let long = String(repeating: "é", count: MacPaste.maxBytes / 2 + 1)
    check(MacPaste.payload(text: long, png: nil) == .failure(.tooLarge(bytes: long.utf8.count)), "text over the limit, in UTF-8 bytes")
    check(MacPaste.Problem.tooLarge(bytes: 40 * 1024 * 1024).message.contains("40 MB"), "size in the message")
    // ⌘ down, ⌘V, V up, all up: iOS sees the modifier before the key, as from a real keyboard.
    check(MacPaste.commandVReports == [[0xE3], [0xE3, 0x19], [0xE3], []], "⌘V key reports")
}

suite("HardwareButton") {
    // Names the viewer's POST /button accepts (_NAMED_BUTTONS in screen_stream.py).
    check(HardwareButton.allCases.map(\.rawValue) == ["home", "lock", "volume-up", "volume-down", "mute", "siri"],
          "server button names")
    check(HardwareButton.menu == [.lock, .volumeUp, .volumeDown, .mute, .siri], "menu: every button but Home")
    check(HardwareButton.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty }, "title and symbol")
    check(Set(HardwareButton.allCases.map(\.title)).count == HardwareButton.allCases.count, "distinct titles")
}

print("\n\(passed) checks passed, \(failures.count) failed")
for f in failures { print("  ✗ \(f)") }
exit(failures.isEmpty ? 0 : 1)
