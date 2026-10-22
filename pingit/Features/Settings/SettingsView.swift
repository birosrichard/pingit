import SwiftUI

struct SettingsView: View {
    @Environment(GitHubConnection.self) private var connection
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    var body: some View {
        @Bindable var preferences = connection.dashboard.syncPreferences
        Form {
            Section("GitHub tokens") {
                GitHubConnectionControls()
            }

            Section("Background Sync") {
                Toggle("Enable background sync", isOn: $preferences.enabled)
                Picker("Refresh interval", selection: $preferences.intervalMinutes) {
                    ForEach(BackgroundSyncPreferences.intervals, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                .disabled(!preferences.enabled)
                if let date = connection.dashboard.lastSuccessfulRefreshAt {
                    LabeledContent("Last data received", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Text("Refreshes while pingit is running, even with the menu closed. Failed connections keep their previous results.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            NotificationSettingsSection()

            Section("About pingit") {
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 700)
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
    private enum Field: Hashable { case owner, token }
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connection.connections.isEmpty {
                Text("No GitHub tokens connected")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("github.connections.empty")
            }
            ForEach(connection.connections) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        GitHubOwnerAvatar(owner: row.resourceOwner, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.resourceOwner).font(.headline)
                            Text(row.account.map { "@\($0.login)" } ?? "Identity needs validation")
                            Text(row.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Replace token") {
                            replacing = row.id
                            owner = row.resourceOwner
                            isAdding = true
                            token = ""
                            focusedField = .token
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
                    focusedField = .owner
                }
                .disabled(connection.isConnecting)
                .accessibilityIdentifier("github.token.add")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resource owner (required)")
                        .font(.headline)
                    TextField("For example, apify or birosrichard", text: $owner)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($focusedField, equals: .owner)
                        .onSubmit { focusedField = .token }
                        .accessibilityLabel("Resource owner, required")
                        .accessibilityHint("Enter the personal username or organization chosen for this token.")
                        .accessibilityIdentifier("github.token.owner")
                        .disabled(connection.isConnecting)
                    Text("Personal username or organization selected when creating the token. This label does not verify repository access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Personal access token (required)")
                        .font(.headline)
                    SecureField("Paste your GitHub token", text: $token)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .textContentType(.password)
                        .focused($focusedField, equals: .token)
                        .onSubmit { connect() }
                        .accessibilityLabel("Personal access token, required")
                        .accessibilityIdentifier("github.token.secret")
                        .disabled(connection.isConnecting)
                }
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

struct NotificationSettingsSection: View {
    @Environment(NotificationCoordinator.self) private var notifications

    var body: some View {
        @Bindable var preferences = notifications.preferences
        Section("Notifications") {
            Toggle("Enable notifications", isOn: $preferences.enabled)
            Text("New events only. Private repository names and PR titles may appear in banners and Notification Center. Control previews in macOS System Settings.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Permission", value: notifications.permission.label)
            if notifications.permission == .notDetermined {
                Button("Request notification permission") {
                    Task { await notifications.requestPermission() }
                }
                .disabled(notifications.isRequestingPermission)
            } else {
                Button("Refresh permission status") {
                    Task { await notifications.refreshAuthorization() }
                }
            }
            Group {
                Toggle("Review requested", isOn: $preferences.reviewRequested)
                Toggle("Review request removed", isOn: $preferences.reviewRequestRemoved)
                Toggle("Pull request approved", isOn: $preferences.approved)
                Toggle("Changes requested", isOn: $preferences.changesRequested)
                Toggle("Your PR merged", isOn: $preferences.prMerged)
                Toggle("Your PR closed without merging", isOn: $preferences.prClosed)
                Toggle("Your PR reopened", isOn: $preferences.prReopened)
                Toggle("Ready for review", isOn: $preferences.readyForReview)
                Toggle("New PR and inline comments", isOn: $preferences.newPRComments)
                Toggle("Review-thread replies", isOn: $preferences.reviewThreadReplies)
                Toggle("Include automated bot comments", isOn: $preferences.botComments)
                Toggle("Play a sound", isOn: $preferences.sound)
            }
            .disabled(!preferences.enabled)
            #if DEBUG
            Button("Send test notification") { notifications.sendDebugNotification() }
                .disabled(!preferences.enabled || !notifications.permission.allowsDelivery || notifications.isDelivering)
            #endif
            if let error = notifications.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .task { await notifications.refreshAuthorization() }
    }
}
