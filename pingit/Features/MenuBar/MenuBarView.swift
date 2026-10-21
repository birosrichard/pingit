import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(GitHubConnection.self) private var connection
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("pingit")
                    .font(.headline)

                Spacer()

                Button("Refresh", systemImage: "arrow.clockwise") {}
                    .labelStyle(.iconOnly)
                    .disabled(true)
                    .help("Pull request refresh will be available in a future update.")
            }
            .padding(16)

            Divider()

            VStack(spacing: 12) {
                if let account = connection.account {
                    GitHubAccountView(account: account)
                    Text("Pull requests and reviews will arrive in a future update.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if connection.isConnecting {
                    ProgressView()
                    Text("Connecting to GitHub…")
                        .font(.headline)
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    Text(connection.hasSavedCredential ? "GitHub needs attention" : "GitHub isn’t connected")
                        .font(.headline)

                    Text(connection.errorMessage ?? "Open Settings to connect your GitHub account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)

            Divider()

            HStack {
                Button("Settings…", systemImage: "gearshape") {
                    // A menu bar interaction does not activate an agent app on its own.
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",")

                Spacer()

                Button("Quit pingit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(12)
        }
        .frame(width: 320)
    }
}
