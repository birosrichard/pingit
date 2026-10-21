import AppKit
import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("GitPingly")
                    .font(.headline)

                Spacer()

                Button("Refresh", systemImage: "arrow.clockwise") {}
                    .labelStyle(.iconOnly)
                    .disabled(true)
                    .help("Refresh is unavailable until GitHub is connected.")
            }
            .padding(16)

            Divider()

            VStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("GitHub isn’t connected")
                    .font(.headline)

                Text("Connection setup will be available in a future update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)

            Divider()

            HStack {
                Spacer()

                Button("Quit GitPingly") {
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
