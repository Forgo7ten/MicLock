import SwiftUI
import AppKit

@MainActor
struct AboutView: View {

    private static let repositoryURL =
        URL(string: "https://github.com/Forgo7ten/MicLock")!

    private static let licenseURL =
        URL(string: "https://github.com/Forgo7ten/MicLock/blob/main/LICENSE")!

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"

        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        if let build, !build.isEmpty {
            return "Version \(version) (\(build))"
        }

        return "Version \(version)"
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)

            Text("MicLock")
                .font(.title2)
                .fontWeight(.semibold)

            Text(versionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Keep your preferred microphone in control.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link(destination: Self.repositoryURL) {
                    Label("GitHub 项目", systemImage: "arrow.up.right.square")
                }

                Link("MIT License", destination: Self.licenseURL)
            }
            .padding(.top, 6)

            Text("Copyright © 2026 Forgo7ten")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
