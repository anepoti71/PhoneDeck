import CryptoKit
import Foundation

/// A provisioning profile (`.mobileprovision`), read from its decoded plist.
public struct ProvisioningProfile {
    public let name: String
    public let uuid: String
    public let teamID: String
    /// `application-identifier` entitlement: `TEAMID.com.example.app` or a wildcard `TEAMID.*`.
    public let appID: String
    public let expiration: Date
    public let devices: [String]
    /// Enterprise profiles run on any device.
    public let allDevices: Bool
    public let entitlements: [String: Any]
    /// SHA-1 (uppercase hex) of the certificates allowed to sign with this profile.
    public let certificateSHA1s: [String]
    /// Raw `.mobileprovision` file, copied into the app as `embedded.mobileprovision` when resigning.
    public var fileURL: URL?

    public init?(plist: [String: Any], fileURL: URL? = nil) {
        guard let name = plist["Name"] as? String,
              let uuid = plist["UUID"] as? String,
              let ent = plist["Entitlements"] as? [String: Any],
              let appID = ent["application-identifier"] as? String,
              let expiration = plist["ExpirationDate"] as? Date
        else { return nil }
        self.name = name
        self.uuid = uuid
        self.appID = appID
        self.expiration = expiration
        self.entitlements = ent
        teamID = (plist["TeamIdentifier"] as? [String])?.first
            ?? (ent["com.apple.developer.team-identifier"] as? String)
            ?? String(appID.prefix { $0 != "." })
        devices = plist["ProvisionedDevices"] as? [String] ?? []
        allDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        certificateSHA1s = (plist["DeveloperCertificates"] as? [Data] ?? []).map(Signing.sha1)
        self.fileURL = fileURL
    }

    /// The bundle ID part of the App ID (`com.example.app` or `*`).
    public var bundlePattern: String {
        appID.hasPrefix(teamID + ".") ? String(appID.dropFirst(teamID.count + 1)) : appID
    }

    public var isWildcard: Bool { bundlePattern.hasSuffix("*") }

    public func covers(bundleID: String) -> Bool { Signing.matches(bundleID, pattern: bundlePattern) }

    public func includes(udid: String) -> Bool {
        allDevices || devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    public func isExpired(at now: Date) -> Bool { expiration <= now }
}

/// What an `.ipa` holds, as far as installing it on an iPhone is concerned.
public struct IPAInfo {
    public enum Signature: Equatable {
        case unsigned
        case adhoc
        case signed(team: String?)
    }

    public let bundleID: String
    public let name: String
    public let version: String
    public let signature: Signature
    /// Entitlements the main app is signed with (empty when unsigned).
    public let entitlements: [String: Any]
    /// `embedded.mobileprovision` of the main app.
    public let profile: ProvisioningProfile?
    /// SHA-1 of the certificate the main app is signed with.
    public let signerSHA1: String?
    /// Bundle IDs of the app extensions (`PlugIns`, `Extensions`).
    public let extensionIDs: [String]

    public init(bundleID: String, name: String, version: String, signature: Signature,
                entitlements: [String: Any], profile: ProvisioningProfile?, signerSHA1: String?,
                extensionIDs: [String]) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.signature = signature
        self.entitlements = entitlements
        self.profile = profile
        self.signerSHA1 = signerSHA1
        self.extensionIDs = extensionIDs
    }
}

/// A reason an `.ipa` would be refused by the iPhone (installd).
public enum IPAIssue: Equatable {
    case unsigned
    case adhoc
    case noProfile
    case profileExpired(Date)
    case deviceNotInProfile
    case bundleIDNotCovered(appID: String)
    case certificateNotInProfile
    case entitlementsNotAllowed([String])

    public var message: String {
        switch self {
        case .unsigned:
            return "The app is not signed."
        case .adhoc:
            return "The app is only ad-hoc signed: an iPhone needs a signature from an Apple certificate."
        case .noProfile:
            return "The app has no provisioning profile (embedded.mobileprovision)."
        case .profileExpired(let date):
            return "Its provisioning profile expired on \(date.formatted(date: .abbreviated, time: .omitted))."
        case .deviceNotInProfile:
            return "This iPhone is not in its provisioning profile (UDID not registered, or an App Store profile)."
        case .bundleIDNotCovered(let appID):
            return "Its provisioning profile is for \(appID), not for this bundle ID."
        case .certificateNotInProfile:
            return "The certificate it is signed with is not in its provisioning profile."
        case .entitlementsNotAllowed(let keys):
            return "Its provisioning profile does not allow: \(keys.joined(separator: ", "))."
        }
    }
}

/// A signing identity from the keychain (`security find-identity`).
public struct SigningIdentity: Equatable, Hashable {
    public let sha1: String
    public let name: String

    public init(sha1: String, name: String) {
        self.sha1 = sha1
        self.name = name
    }
}

/// One way to resign an app for an iPhone: a keychain identity plus a profile that allows it.
public struct ResignPlan {
    public let identity: SigningIdentity
    public let profile: ProvisioningProfile
    /// Bundle ID the resigned app gets (differs from the original with an explicit profile for another App ID).
    public let bundleID: String
    /// Extensions that can't be signed with this profile and are left out.
    public let droppedExtensions: [String]

    public var changesBundleID: Bool { bundleID != originalBundleID }
    let originalBundleID: String

    public var label: String {
        "\(profile.name) · \(identity.name)"
    }
}

public enum Signing {
    public static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// `value` against a profile value that may end with `*` (`TEAM.*`, `group.*`, `*`).
    public static func matches(_ value: String, pattern: String) -> Bool {
        if pattern.hasSuffix("*") { return value.hasPrefix(pattern.dropLast()) }
        return value == pattern
    }

    /// Why the iPhone `udid` would refuse this app. Empty: it should install.
    public static func issues(_ ipa: IPAInfo, udid: String, now: Date = Date()) -> [IPAIssue] {
        switch ipa.signature {
        case .unsigned: return [.unsigned]
        case .adhoc: return [.adhoc]
        case .signed: break
        }
        guard let p = ipa.profile else { return [.noProfile] }
        var out: [IPAIssue] = []
        if p.isExpired(at: now) { out.append(.profileExpired(p.expiration)) }
        if !p.includes(udid: udid) { out.append(.deviceNotInProfile) }
        if !p.covers(bundleID: ipa.bundleID) { out.append(.bundleIDNotCovered(appID: p.appID)) }
        if let signer = ipa.signerSHA1, !p.certificateSHA1s.isEmpty, !p.certificateSHA1s.contains(signer) {
            out.append(.certificateNotInProfile)
        }
        let denied = deniedEntitlements(ipa.entitlements, allowed: p.entitlements)
        if !denied.isEmpty { out.append(.entitlementsNotAllowed(denied)) }
        return out
    }

    /// Entitlement keys the app asks for that the profile does not grant (with its wildcards).
    public static func deniedEntitlements(_ requested: [String: Any], allowed: [String: Any]) -> [String] {
        requested.keys.sorted().filter { key in
            guard let have = allowed[key] else { return true }
            return !isAllowed(requested[key]!, by: have)
        }
    }

    private static func isAllowed(_ value: Any, by allowed: Any) -> Bool {
        let patterns: [String] = (allowed as? [String]) ?? ((allowed as? String).map { [$0] } ?? [])
        if let b = value as? Bool, let a = allowed as? Bool { return !b || a }
        if let s = value as? String { return patterns.contains { matches(s, pattern: $0) } }
        if let list = value as? [String] {
            return list.allSatisfy { v in patterns.contains { matches(v, pattern: $0) } }
        }
        return true  // dictionaries, numbers: installd compares those loosely, don't flag them
    }

    /// Parses `security find-identity -v -p codesigning`, keeping identities that can sign iOS apps.
    public static func parseIdentities(_ text: String) -> [SigningIdentity] {
        var out: [SigningIdentity] = []
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[0].hasSuffix(")"), parts[1].count == 40,
                  parts[2].hasPrefix("\""), parts[2].hasSuffix("\"") else { continue }
            let name = String(parts[2].dropFirst().dropLast())
            guard ["Apple Development", "iPhone Developer", "Apple Distribution", "iPhone Distribution"]
                .contains(where: { name.hasPrefix($0 + ":") }) else { continue }
            let id = SigningIdentity(sha1: String(parts[1]).uppercased(), name: name)
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Ways to resign `ipa` for `udid` with what this Mac has, best first:
    /// a profile for the app's own bundle ID, then a wildcard one, then one for another App ID
    /// (the app gets that bundle ID). Profiles must be valid, include the iPhone and allow the identity.
    public static func plans(for ipa: IPAInfo, udid: String, profiles: [ProvisioningProfile],
                             identities: [SigningIdentity], now: Date = Date()) -> [ResignPlan] {
        var ranked: [(Int, Date, ResignPlan)] = []
        for p in profiles where !p.isExpired(at: now) && p.includes(udid: udid) {
            guard let identity = identities.first(where: { p.certificateSHA1s.contains($0.sha1) }) else { continue }
            let rank: Int
            let bundleID: String
            if p.covers(bundleID: ipa.bundleID) {
                rank = p.isWildcard ? 1 : 0
                bundleID = ipa.bundleID
            } else if !p.isWildcard {
                rank = 2
                bundleID = p.bundlePattern
            } else {
                continue  // wildcard with another prefix: no single bundle ID to pick
            }
            let dropped = p.isWildcard ? [] : ipa.extensionIDs
            ranked.append((rank, p.expiration, ResignPlan(identity: identity, profile: p, bundleID: bundleID,
                                                          droppedExtensions: dropped,
                                                          originalBundleID: ipa.bundleID)))
        }
        return ranked.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 > $1.1 }.map(\.2)
    }

    /// Bundle ID of an extension once its app becomes `newAppID` (same suffix after the app's ID).
    public static func extensionID(_ ext: String, from oldAppID: String, to newAppID: String) -> String {
        ext.hasPrefix(oldAppID + ".") ? newAppID + ext.dropFirst(oldAppID.count) : ext
    }

    /// Entitlements to sign `bundleID` with under `profile`: what the profile grants, with the
    /// wildcards Xcode would expand expanded, and the wildcard-only ones left out.
    public static func entitlements(for bundleID: String, profile: ProvisioningProfile) -> [String: Any] {
        let fullID = profile.teamID + "." + bundleID
        var out: [String: Any] = [:]
        for (key, value) in profile.entitlements {
            switch key {
            case "application-identifier":
                out[key] = fullID
            case "keychain-access-groups":
                let groups = (value as? [String] ?? []).map { $0.hasSuffix("*") ? fullID : $0 }
                out[key] = Array(NSOrderedSet(array: groups)) as? [String] ?? groups
            default:
                if let s = value as? String {
                    if !s.hasSuffix("*") { out[key] = s }
                } else if let list = value as? [String] {
                    let concrete = list.filter { !$0.hasSuffix("*") }
                    if !concrete.isEmpty { out[key] = concrete }
                } else {
                    out[key] = value
                }
            }
        }
        return out
    }
}

// MARK: What is needed

/// What the developer portal must provide to sign a given app for a given iPhone, worked out from
/// the app itself (bundle ID, entitlements it asks for, extensions) — not from any existing profile.
public struct SigningRequirements: Equatable {
    public let bundleID: String
    public let udid: String
    /// An Apple Development identity (certificate + private key) is in the keychain.
    public let hasIdentity: Bool
    /// Capabilities the app's entitlements ask for, as the portal names them.
    public let capabilities: [String]
    public let appGroups: [String]
    public let extensionIDs: [String]

    /// Capabilities and extensions need an explicit App ID; otherwise a wildcard (`*`) one is enough.
    public var needsExplicitAppID: Bool { !capabilities.isEmpty || !extensionIDs.isEmpty }

    /// The steps on developer.apple.com, in order.
    public var steps: [String] {
        var out: [String] = []
        out.append(hasIdentity
            ? "Certificate: an Apple Development certificate is in your keychain (use it for the profile)."
            : "Certificate: create an Apple Development certificate (Certificates) and install it in the keychain with its private key.")
        out.append("Device: register this iPhone in Devices (UDID \(udid)).")
        if !appGroups.isEmpty {
            out.append("App Groups: create \(appGroups.joined(separator: ", ")) (Identifiers › App Groups).")
        }
        if needsExplicitAppID {
            var s = "App ID: create an explicit App ID \(bundleID)"
            if !capabilities.isEmpty { s += " with \(capabilities.joined(separator: ", "))" }
            out.append(s + ".")
        } else {
            out.append("App ID: an explicit App ID \(bundleID), or a wildcard one (*), with no capabilities.")
        }
        if !extensionIDs.isEmpty {
            out.append("Extensions: \(extensionIDs.joined(separator: ", ")) each need their own App ID and profile; with a single profile they are left out of the resigned app.")
        }
        out.append("Profile: create an iOS App Development profile with that App ID, the certificate and this iPhone, download it and add it with Choose Profile….")
        return out
    }
}

extension Signing {
    /// Entitlements every profile carries (or that resigning sets): not capabilities to ask for.
    static let baseEntitlements: Set<String> = [
        "application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
        "keychain-access-groups", "beta-reports-active",
    ]

    /// Portal name of the capability an entitlement belongs to.
    public static func capabilityName(_ key: String) -> String {
        switch key {
        case "com.apple.security.application-groups": return "App Groups"
        case "aps-environment": return "Push Notifications"
        case "com.apple.developer.associated-domains": return "Associated Domains"
        case "com.apple.developer.healthkit", "com.apple.developer.healthkit.access": return "HealthKit"
        case "com.apple.developer.homekit": return "HomeKit"
        case "com.apple.developer.in-app-payments": return "Apple Pay"
        case "com.apple.developer.siri": return "Siri"
        case "com.apple.developer.game-center": return "Game Center"
        case "com.apple.developer.networking.wifi-info": return "Access Wi-Fi Information"
        case "com.apple.developer.networking.networkextension": return "Network Extensions"
        case "com.apple.developer.networking.vpn.api": return "Personal VPN"
        case "com.apple.developer.nfc.readersession.formats": return "NFC Tag Reading"
        case "com.apple.developer.applesignin": return "Sign In with Apple"
        case "com.apple.developer.usernotifications.time-sensitive": return "Time Sensitive Notifications"
        case "com.apple.developer.default-data-protection": return "Data Protection"
        case "com.apple.external-accessory.wireless-configuration": return "Wireless Accessory Configuration"
        case "com.apple.developer.ubiquity-kvstore-identifier": return "iCloud"
        default:
            if key.hasPrefix("com.apple.developer.icloud") || key.hasPrefix("com.apple.developer.ubiquity") { return "iCloud" }
            return key
        }
    }

    /// Capabilities (portal names, no duplicates) the given entitlements ask for.
    public static func capabilities(_ entitlements: [String: Any]) -> [String] {
        var out: [String] = []
        for key in entitlements.keys.sorted() where !baseEntitlements.contains(key) {
            let name = capabilityName(key)
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    public static func requirements(for ipa: IPAInfo, udid: String, identities: [SigningIdentity]) -> SigningRequirements {
        SigningRequirements(
            bundleID: ipa.bundleID, udid: udid,
            hasIdentity: identities.contains { $0.name.hasPrefix("Apple Development:") || $0.name.hasPrefix("iPhone Developer:") },
            capabilities: capabilities(ipa.entitlements),
            appGroups: (ipa.entitlements["com.apple.security.application-groups"] as? [String]) ?? [],
            extensionIDs: ipa.extensionIDs)
    }

    /// Why a profile on this Mac can't resign the app for `udid` (nil: it can).
    public static func rejection(of p: ProvisioningProfile, for ipa: IPAInfo, udid: String,
                                 identities: [SigningIdentity], now: Date = Date()) -> String? {
        if p.isExpired(at: now) { return "expired" }
        if !p.includes(udid: udid) { return "this iPhone is not in it" }
        if !identities.contains(where: { p.certificateSHA1s.contains($0.sha1) }) {
            return "none of its certificates is in your keychain"
        }
        if p.isWildcard && !p.covers(bundleID: ipa.bundleID) { return "for \(p.appID), not this bundle ID" }
        return nil
    }

    /// Capabilities the app asks for that signing under `plan` would not grant: the features using
    /// them may not work in the resigned app.
    public static func missingCapabilities(_ ipa: IPAInfo, plan: ResignPlan) -> [String] {
        let granted = entitlements(for: plan.bundleID, profile: plan.profile)
        let wanted = ipa.entitlements.filter { !baseEntitlements.contains($0.key) }
        return capabilities(wanted.filter { deniedEntitlements([$0.key: $0.value], allowed: granted).count > 0 })
    }
}
