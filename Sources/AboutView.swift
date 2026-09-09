import SwiftUI
import AppKit

@MainActor
struct AboutView: View {

    private static let repositoryURL =
        URL(string: "https://github.com/Forgo7ten/MicLock")!

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

            Button {
                NSWorkspace.shared.open(Self.repositoryURL)
            } label: {
                Label("在 GitHub 上查看", systemImage: "arrow.up.right.square")
            }
            .controlSize(.large)
            .padding(.top, 6)

            Text("MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 380)
    }
}
