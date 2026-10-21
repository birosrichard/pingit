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
            Section("GitHub tokens") {
                GitHubConnectionControls()
            }

            Section("About pingit") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
}

struct GitHubConnectionControls: View {
    @Environment(GitHubConnection.self) private var connection
    @State private var token = ""
    @State private var owner = ""
    @State private var isAdding = false
    @State private var replacing: UUID?
    @State private var removing: GitHubTokenConnection?
    @State private var submission: Task<Void, Never>?
    @FocusState private var isTokenFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connection.connections.isEmpty {
                Text("No GitHub tokens connected")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("github.connections.empty")
            }
            ForEach(connection.connections) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.resourceOwner).font(.headline)
                    Text(row.account.map { "@\($0.login)" } ?? "Identity needs validation")
                    Text(row.status).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Replace token") {
                            replacing = row.id
                            owner = row.resourceOwner
                            isAdding = true
                            token = ""
                            isTokenFocused = true
                        }
                        .accessibilityLabel("Replace token for \(row.resourceOwner)")
                        Button("Remove", role: .destructive) { removing = row }
                            .accessibilityLabel("Remove token for \(row.resourceOwner)")
                    }
                    .disabled(connection.isConnecting)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("github.connection.\(row.id)")
                Divider()
            }
            if !isAdding {
                Button("Add GitHub token") {
                    replacing = nil
                    owner = ""
                    token = ""
                    isAdding = true
                    isTokenFocused = true
                }
                .disabled(connection.isConnecting)
                .accessibilityIdentifier("github.token.add")
            } else {
                TextField("Resource owner (personal username or organization)", text: $owner)
                    .accessibilityIdentifier("github.token.owner")
                SecureField("Personal access token", text: $token)
                    .textContentType(.password)
                    .focused($isTokenFocused)
                    .onSubmit { connect() }
                    .accessibilityIdentifier("github.token.secret")
                Text("Resource owner is your label; pingit cannot verify the token’s owner or full repository access.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(replacing == nil ? "Validate and add" : "Validate and replace") { connect() }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("github.token.validate")
                    Button("Cancel") {
                        submission?.cancel()
                        token = ""
                        isAdding = false
                    }
                    if connection.isConnecting {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Validating GitHub token")
                            .accessibilityIdentifier("github.token.validating")
                    }
                }
                .disabled(connection.isConnecting)
            }
            if connection.hasSavedCredential {
                Button("Retry saved connections") {
                    submission = Task { await connection.reconnectSavedAccount() }
                }
                .disabled(connection.isConnecting)
            }
            if let error = connection.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Connection error: \(error)")
                    .accessibilityIdentifier("github.token.error")
            }
            Text("Use tokens for the same GitHub account. For private repositories, select the intended owner and repositories, with Pull requests: Read-only and Metadata: Read-only. Organization policy or pending approval may restrict access. No write permissions are needed.")
                .font(.callout).foregroundStyle(.secondary)
            Link("Create a fine-grained token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
            Text("Tokens are stored separately in macOS Keychain and never shown after saving. An empty search does not prove access to all repositories.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(connection.isConnecting && !isAdding)
        .confirmationDialog("Remove GitHub token?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { row in
            Button("Remove token for \(row.resourceOwner)", role: .destructive) {
                connection.remove(row.id)
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { row in
            Text("Remove \(row.resourceOwner) from Keychain and discard pull requests available only through this token?")
        }
        .onDisappear {
            token = ""
            submission?.cancel()
        }
    }

    private func connect() {
        guard !connection.isConnecting,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submittedToken = token
        token = ""
        submission = Task {
            await connection.connect(token: submittedToken, resourceOwner: owner, replacing: replacing)
            if connection.errorMessage == nil { isAdding = false; replacing = nil }
        }
    }
}
