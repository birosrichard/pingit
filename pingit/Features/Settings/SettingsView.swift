import SwiftUI

struct SettingsView: View {
    @Environment(GitHubConnection.self) private var connection
    @State private var token = ""

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    var body: some View {
        Form {
            Section("GitHub connection") {
                if let account = connection.account {
                    GitHubAccountView(account: account)
                } else {
                    LabeledContent("Status", value: connection.isConnecting ? "Connecting…" : "Not connected")

                    SecureField("Personal access token", text: $token)
                        .textContentType(.password)
                        .disabled(connection.isConnecting)
                        .onSubmit { connect() }

                    HStack {
                        Button("Connect") { connect() }
                            .disabled(connection.isConnecting || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if connection.isConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Connecting to GitHub")
                        }

                        if connection.hasSavedCredential {
                            Button("Retry saved connection") {
                                Task { await connection.reconnectSavedAccount() }
                            }
                            .disabled(connection.isConnecting)
                        }
                    }

                    Text("Create a fine-grained token in GitHub Settings → Developer settings → Personal access tokens. Choose your account, set an expiration, use Public repositories, and leave additional permissions unset. No write permissions are needed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Link("How to create a fine-grained token", destination: URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token")!)
                }

                if let error = connection.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Connection error: \(error)")
                }

                if connection.account != nil || connection.hasSavedCredential {
                    Button("Disconnect", role: .destructive) {
                        token = ""
                        connection.disconnect()
                    }
                    .disabled(connection.isConnecting)
                }

                Text("Your token is stored in macOS Keychain and is never shown after connecting. Account validation does not verify access to private repositories or organizations. Future PR and review features may need repository permissions and organization approval.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About pingit") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
        .onDisappear { token = "" }
        .onChange(of: connection.account) { _, account in
            if account != nil { token = "" }
        }
    }

    private func connect() {
        guard !connection.isConnecting,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submittedToken = token
        token = ""
        Task { await connection.connect(token: submittedToken) }
    }
}
