import Foundation
import PMD3BarCore
import Security

/// Reads an `.ipa`'s signature and profile, finds this Mac's profiles and signing identities, and
/// resigns an app for an iPhone. The decisions (what is wrong, which profile to use) are in
/// PMD3BarCore's `Signing`; this file only runs the tools.
enum IPASigning {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// An extracted `.ipa`. Delete it with `discard()` when done.
    /// `dir` holds two folders: `unpacked` (the archive's content, untrusted) and `scratch` (files
    /// the app writes, such as certificates and entitlements). Nothing is ever written into
    /// `unpacked` by name from the archive, so a link planted in the `.ipa` can't redirect a write.
    struct Extracted {
        let dir: URL
        let app: URL
        let info: IPAInfo
        var unpacked: URL { dir.appendingPathComponent("unpacked", isDirectory: true) }
        var scratch: URL { dir.appendingPathComponent("scratch", isDirectory: true) }

        func discard() { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Inspect

    static func extract(_ ipa: URL) async throws -> Extracted {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PMD3Bar-ipa-\(UUID().uuidString)", isDirectory: true)
        let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try await tool("/usr/bin/ditto", ["-x", "-k", ipa.path, unpacked.path], "Can't unpack the .ipa")
            try rejectLinks(in: unpacked)
            let payload = unpacked.appendingPathComponent("Payload")
            guard let app = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" })
            else { throw Failure("The .ipa has no Payload/*.app") }
            return Extracted(dir: dir, app: app, info: try await inspect(app, scratch: scratch))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Apps never need symbolic links, and one could point a later write or `codesign --force` at a
    /// file outside the archive (for example `~/.ssh/authorized_keys`): refuse the whole `.ipa`.
    private static func rejectLinks(in root: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in false })
        else { throw Failure("Can't read the unpacked .ipa") }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true {
                throw Failure("The .ipa contains a symbolic link (\(url.lastPathComponent)): refused, apps don't need them")
            }
            guard url.standardizedFileURL.path.hasPrefix(base) || url.resolvingSymlinksInPath().path.hasPrefix(base) else {
                throw Failure("The .ipa contains a path outside its folder: refused")
            }
        }
    }

    private static func inspect(_ app: URL, scratch: URL) async throws -> IPAInfo {
        guard let plist = readPlist(app.appendingPathComponent("Info.plist")),
              let bundleID = plist["CFBundleIdentifier"] as? String
        else { throw Failure("The app has no readable Info.plist") }
        guard Safety.isBundleID(bundleID) else { throw Failure("The app's bundle ID is not valid") }

        let details = await Shell.run("/usr/bin/codesign", ["-dv", app.path])
        let signature: IPAInfo.Signature
        if !details.ok {
            signature = .unsigned
        } else if details.stderr.contains("Signature=adhoc") {
            signature = .adhoc
        } else {
            let team = details.stderr.split(separator: "\n")
                .first { $0.hasPrefix("TeamIdentifier=") }
                .map { String($0.dropFirst("TeamIdentifier=".count)) }
            signature = .signed(team: team == "not set" ? nil : team)
        }

        var entitlements: [String: Any] = [:]
        var signer: String?
        // Ad-hoc apps carry entitlements too: they say which capabilities the app needs.
        if signature != .unsigned {
            let ent = await Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app.path])
            if ent.ok, let dict = try? PropertyListSerialization.propertyList(from: ent.stdout, format: nil) as? [String: Any] {
                entitlements = dict
            }
        }
        if case .signed = signature {
            // Writes the chain as <prefix>0 (leaf), <prefix>1, … in DER.
            let prefix = scratch.appendingPathComponent("signer-cert").path
            if await Shell.run("/usr/bin/codesign", ["-d", "--extract-certificates=\(prefix)", app.path]).ok,
               let leaf = FileManager.default.contents(atPath: prefix + "0") {
                signer = Signing.sha1(leaf)
            }
        }

        return IPAInfo(
            bundleID: bundleID,
            name: (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? app.deletingPathExtension().lastPathComponent,
            version: (plist["CFBundleShortVersionString"] as? String) ?? "",
            signature: signature,
            entitlements: entitlements,
            profile: profile(at: app.appendingPathComponent("embedded.mobileprovision")),
            signerSHA1: signer,
            extensionIDs: extensions(of: app).compactMap {
                readPlist($0.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String
            })
    }

    /// App extensions inside the app (`PlugIns/*.appex`, `Extensions/*.appex`).
    private static func extensions(of app: URL) -> [URL] {
        ["PlugIns", "Extensions"].flatMap { sub in
            ((try? FileManager.default.contentsOfDirectory(at: app.appendingPathComponent(sub),
                                                           includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "appex" }
        }
    }

    // MARK: Profiles and identities

    /// Where Xcode and the Finder (double-click) keep provisioning profiles.
    static let profileDirectories: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
                home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles")]
    }()

    static func installedProfiles() -> [ProvisioningProfile] {
        var seen = Set<String>()
        return profileDirectories.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension) }
                .compactMap(profile(at:))
        }
        .filter { seen.insert($0.uuid).inserted }
    }

    /// Copies a profile the user picked to where Xcode keeps them, so it is found next time too.
    static func addProfile(_ url: URL) throws -> ProvisioningProfile {
        guard let p = profile(at: url) else { throw Failure("\(url.lastPathComponent) is not a provisioning profile") }
        // The UUID names the copy: it must be a UUID, not a path.
        guard Safety.isProfileUUID(p.uuid) else { throw Failure("\(url.lastPathComponent) has an invalid UUID") }
        let dir = profileDirectories[1]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(p.uuid).mobileprovision")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        var copy = p
        copy.fileURL = dest
        return copy
    }

    /// Decodes a `.mobileprovision` (a CMS-signed plist) without spawning `security cms -D`.
    static func profile(at url: URL) -> ProvisioningProfile? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let fed = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
        var content: CFData?
        guard fed == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content,
              let plist = try? PropertyListSerialization.propertyList(from: content as Data, format: nil) as? [String: Any]
        else { return nil }
        return ProvisioningProfile(plist: plist, fileURL: url)
    }

    static func identities() async -> [SigningIdentity] {
        let r = await Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        return Signing.parseIdentities(String(decoding: r.stdout, as: UTF8.self))
    }

    // MARK: Resign

    /// Resigns the extracted app with `plan` and packs it as a new `.ipa` at `output`.
    static func resign(_ x: Extracted, plan: ResignPlan, to output: URL) async throws {
        guard let profileURL = plan.profile.fileURL else { throw Failure("The profile file is missing") }
        let fm = FileManager.default
        let app = x.app

        guard Safety.isBundleID(plan.bundleID) else { throw Failure("The bundle ID \(plan.bundleID) is not valid") }
        // The tree was checked at extraction; check again in case anything changed it since.
        try rejectLinks(in: x.unpacked)

        // Extensions need their own profile: an explicit one signs only the app.
        for ext in extensions(of: app) {
            let id = readPlist(ext.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String
            if let id, plan.droppedExtensions.contains(id) { try fm.removeItem(at: ext) }
        }
        // A Watch app can't be installed on the iPhone with this profile either.
        try? fm.removeItem(at: app.appendingPathComponent("Watch"))

        let bundles = extensions(of: app) + [app]  // inner first: the app's seal covers the extensions
        for bundle in bundles {
            let infoURL = bundle.appendingPathComponent("Info.plist")
            guard var info = readPlist(infoURL), let oldID = info["CFBundleIdentifier"] as? String else {
                throw Failure("Can't read \(bundle.lastPathComponent)/Info.plist")
            }
            let newID = bundle == app ? plan.bundleID : Signing.extensionID(oldID, from: x.info.bundleID, to: plan.bundleID)
            guard Safety.isBundleID(newID) else { throw Failure("The bundle ID \(newID) is not valid") }
            if newID != oldID {
                info["CFBundleIdentifier"] = newID
                let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                try data.write(to: infoURL, options: .atomic)
            }
            let embedded = bundle.appendingPathComponent("embedded.mobileprovision")
            try? fm.removeItem(at: embedded)
            try fm.copyItem(at: profileURL, to: embedded)

            for code in nestedCode(in: bundle) {
                try await tool("/usr/bin/codesign", ["--force", "--sign", plan.identity.sha1, "--timestamp=none", code.path],
                               "Can't sign \(code.lastPathComponent)")
            }
            // A fresh name in the app's own scratch folder, never a name derived from the archive.
            let ent = x.scratch.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
            let entData = try PropertyListSerialization.data(
                fromPropertyList: Signing.entitlements(for: newID, profile: plan.profile), format: .xml, options: 0)
            try entData.write(to: ent, options: [.atomic, .withoutOverwriting])
            try await tool("/usr/bin/codesign", ["--force", "--sign", plan.identity.sha1, "--timestamp=none",
                                                 "--generate-entitlement-der", "--entitlements", ent.path, bundle.path],
                           "Can't sign \(bundle.lastPathComponent)")
        }

        try? fm.removeItem(at: output)
        try await tool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent",
                                          x.unpacked.appendingPathComponent("Payload").path, output.path],
                       "Can't write \(output.lastPathComponent)")
    }

    /// Frameworks and dylibs of a bundle (not its extensions), deepest first.
    private static func nestedCode(in bundle: URL) -> [URL] {
        let frameworks = bundle.appendingPathComponent("Frameworks")
        guard let items = try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)
        else { return [] }
        return items.filter { ["framework", "dylib"].contains($0.pathExtension) }
            .sorted { $0.path.count > $1.path.count }
    }

    // MARK: Helpers

    private static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func tool(_ path: String, _ args: [String], _ what: String) async throws {
        let r = await Shell.run(path, args)
        guard r.ok else {
            let detail = r.stderr.split(separator: "\n").last.map(String.init) ?? "exit \(r.status)"
            PMD3.log("$ \(path) \(args.joined(separator: " ")) -> exit \(r.status)\n\(r.stderr)")
            throw Failure("\(what): \(detail)")
        }
    }
}

/// Runs a system tool to completion, capturing its output.
enum Shell {
    static func run(_ path: String, _ args: [String]) async -> RunResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch {
                    cont.resume(returning: RunResult(status: -1, stdout: Data(), stderr: error.localizedDescription))
                    return
                }
                final class Box: @unchecked Sendable { var data = Data() }
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                cont.resume(returning: RunResult(status: p.terminationStatus, stdout: outData,
                                                 stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }
}

/// `PMD3Bar --ipa-check <file.ipa> <UDID> [--profile <file>]… [--resign <out.ipa>]`: prints why the
/// iPhone would refuse the .ipa and how it could be resigned (and resigns it with the best plan),
/// without the UI. For troubleshooting (see RUNBOOK).
enum IPACheckCLI {
    static func main(_ args: [String]) -> Never {
        let done = DispatchSemaphore(value: 0)
        final class Code: @unchecked Sendable { var value: Int32 = 0 }
        let code = Code()
        Task.detached {
            code.value = await run(args)
            done.signal()
        }
        done.wait()
        exit(code.value)
    }

    private static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else {
            print("usage: PMD3Bar --ipa-check <file.ipa> <UDID> [--profile <file>]... [--resign <out.ipa>]")
            return 2
        }
        let ipa = URL(fileURLWithPath: args[0]), udid = args[1]
        var extra: [ProvisioningProfile] = []
        var resignTo: URL?
        var i = 2
        while i + 1 < args.count {
            if args[i] == "--profile", let p = IPASigning.profile(at: URL(fileURLWithPath: args[i + 1])) { extra.append(p) }
            if args[i] == "--resign" { resignTo = URL(fileURLWithPath: args[i + 1]) }
            i += 2
        }
        let x: IPASigning.Extracted
        do { x = try await IPASigning.extract(ipa) } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        defer { x.discard() }
        let info = x.info
        print("\(info.name) \(info.version)  \(info.bundleID)  signature: \(info.signature)")
        if let p = info.profile { print("profile: \(p.name)  \(p.appID)  expires \(p.expiration)  devices: \(p.devices.count)") }
        if !info.extensionIDs.isEmpty { print("extensions: \(info.extensionIDs.joined(separator: ", "))") }
        let issues = Signing.issues(info, udid: udid)
        print(issues.isEmpty ? "OK: the iPhone should accept it" : issues.map { "✗ " + $0.message }.joined(separator: "\n"))
        let identities = await IPASigning.identities()
        let profiles = IPASigning.installedProfiles() + extra
        let plans = Signing.plans(for: info, udid: udid, profiles: profiles, identities: identities)
        for (n, p) in plans.enumerated() {
            let missing = Signing.missingCapabilities(info, plan: p)
            print("plan \(n + 1): \(p.label) -> \(p.bundleID)"
                  + (p.droppedExtensions.isEmpty ? "" : "  drops \(p.droppedExtensions.joined(separator: ", "))")
                  + (missing.isEmpty ? "" : "  not granted: \(missing.joined(separator: ", "))"))
        }
        for p in profiles {
            if let why = Signing.rejection(of: p, for: info, udid: udid, identities: identities) { print("unusable: \(p.name): \(why)") }
        }
        if !issues.isEmpty {
            print("needed on the developer portal:")
            for (n, step) in Signing.requirements(for: info, udid: udid, identities: identities).steps.enumerated() {
                print("  \(n + 1). \(step)")
            }
        }
        guard let resignTo else { return issues.isEmpty ? 0 : 1 }
        guard let plan = plans.first else {
            print("error: no profile on this Mac can resign it for \(udid)")
            return 1
        }
        do {
            try await IPASigning.resign(x, plan: plan, to: resignTo)
            print("resigned: \(resignTo.path)")
            return 0
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
    }
}
