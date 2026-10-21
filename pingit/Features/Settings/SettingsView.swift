import SwiftUI

struct SettingsView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("GitHub", value: "Not connected")

                Text("Connection setup will be available in a future update.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About pingit") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
    }
}
