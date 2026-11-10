import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PMD3BarCore

/// Shown when an .ipa would be refused by the iPhone: why, how to resign it with this Mac's
/// profiles, and otherwise what to create on the developer portal for this app and iPhone.
struct InstallReviewSheet: View {
    let review: DeviceTools.InstallReview
    let tools: DeviceTools
    @State private var choice = 0
    @State private var showSteps = false

    private static let portalURL = URL(string: "https://developer.apple.com/account/resources/profiles/list")!

    private var plan: ResignPlan? {
        review.plans.isEmpty ? nil : review.plans[min(choice, review.plans.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(review.issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: "xmark.circle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            if let plan {
                planSection(plan)
                DisclosureGroup("What a profile for \(review.info.bundleID) needs", isExpanded: $showSteps) {
                    steps.padding(.top, 6)
                }
            } else {
                Text("No profile on this Mac can sign it for this iPhone. On the developer portal you need:")
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                steps
            }
            if !review.rejected.isEmpty {
                DisclosureGroup("Profiles on this Mac that can't be used (\(review.rejected.count))") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(review.rejected, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
            }
            HStack {
                Button("Choose Profile…") { pickProfile() }
                    .help("Add a .mobileprovision downloaded from the developer portal")
                Button("Copy UDID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tools.udid, forType: .string)
                }
                .help("This iPhone's UDID, to register it in Devices")
                Button("Developer Portal") { NSWorkspace.shared.open(Self.portalURL) }
            }
            if let err = review.profileError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Install Anyway") { review.decide(.installAnyway) }
                    .help("Send it to the iPhone as it is")
                Spacer()
                Button("Cancel", role: .cancel) { review.decide(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button("Resign and Install") { if let plan { review.decide(.resign(plan)) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 500)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 30)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("The iPhone would refuse \(review.info.name)").font(.headline)
                Text([review.info.bundleID, review.info.version].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func planSection(_ plan: ResignPlan) -> some View {
        Text("Resign it for this iPhone with:").font(.subheadline.weight(.medium))
        Picker("Profile", selection: $choice) {
            ForEach(Array(review.plans.enumerated()), id: \.offset) { i, p in Text(p.label).tag(i) }
        }
        .labelsHidden()
        VStack(alignment: .leading, spacing: 4) {
            if plan.changesBundleID {
                note("arrow.triangle.swap", "The bundle ID becomes \(plan.bundleID): this profile is for that App ID, not for \(review.info.bundleID).")
            }
            let missing = Signing.missingCapabilities(review.info, plan: plan)
            if !missing.isEmpty {
                note("exclamationmark.triangle", "This profile doesn't grant \(missing.joined(separator: ", ")): the features that use it may not work.",
                     color: .orange)
            }
            if !plan.droppedExtensions.isEmpty {
                note("puzzlepiece.extension",
                     "Leaves out \(plan.droppedExtensions.joined(separator: ", ")): each extension needs its own profile.")
            }
            note("square.and.arrow.down", "The resigned copy is saved to Downloads.")
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(review.requirements.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .font(.callout)
            }
        }
    }

    private func note(_ icon: String, _ text: String, color: Color = .secondary) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pickProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mobileprovision", "provisionprofile"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tools.addProfile(url, to: review)
        choice = 0
    }
}
