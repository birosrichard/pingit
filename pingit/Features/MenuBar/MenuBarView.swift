import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(GitHubConnection.self) private var connection
    @Environment(\.openSettings) private var openSettings
    @State private var isShowingConnection = false

    private var dashboard: PullRequestDashboard { connection.dashboard }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("PingitMark")
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                Text("pingit")
                    .font(.headline)

                Spacer()

                if dashboard.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing pull requests")
                }

                Button("Refresh", systemImage: "arrow.clockwise") { dashboard.refresh() }
                    .labelStyle(.iconOnly)
                    .disabled(connection.account == nil || dashboard.isLoading)
                    .keyboardShortcut("r")
                    .help("Refresh pull requests (⌘R)")
            }
            .padding(16)

            Divider()

            if isShowingConnection && connection.account == nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Connect GitHub")
                                .font(.headline)
                            Spacer()
                            Button("Back", systemImage: "chevron.left") {
                                isShowingConnection = false
                            }
                            .buttonStyle(.borderless)
                        }

                        GitHubConnectionControls()
                    }
                    .padding(20)
                }
                .frame(height: 440)
            } else if let account = connection.account {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("@\(account.login)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        PullRequestSection(title: "Needs your review", state: dashboard.reviews,
                                           emptyMessage: "Nothing needs your review.", showsAuthor: true)
                        Divider()
                        PullRequestSection(title: "My pull requests", state: dashboard.authored,
                                           emptyMessage: "No open pull requests.", showsAuthor: false)
                    }
                    .padding(16)
                }
                .frame(height: 440)
            } else {
                VStack(spacing: 12) {
                    if connection.isConnecting {
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

                        Text(connection.errorMessage ?? "Connect your GitHub account to get started.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Button("Connect GitHub") {
                            isShowingConnection = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }

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
        .frame(width: 380)
        .onAppear { dashboard.loadIfNeeded() }
        .onChange(of: connection.account) { _, account in
            if account != nil {
                isShowingConnection = false
                dashboard.loadIfNeeded()
            }
        }
    }
}

private struct PullRequestSection: View {
    let title: String
    let state: PullRequestSectionState
    let emptyMessage: String
    let showsAuthor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(state.result.map { String($0.pullRequests.count) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(state.result.map { "\($0.pullRequests.count) loaded pull requests" } ?? "Count unavailable")
            }

            if state.phase == .loading || state.phase == .idle {
                Label(state.result == nil ? "Loading pull requests…" : "Refreshing…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Use Refresh to retry. Settings can help with connection or token access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let result = state.result {
                if result.pullRequests.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(result.pullRequests) { pr in
                            PullRequestRow(pr: pr, showsAuthor: showsAuthor)
                        }
                    }
                }
                if let date = state.updatedAt {
                    Text("\(state.phase == .failed ? "Showing previous results from" : "Updated") \(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.coverageMessages, id: \.self) { message in
                    Label(message, systemImage: result.isTruncated && message == state.coverageMessages.first
                          ? "exclamationmark.circle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct PullRequestRow: View {
    let pr: GitHubPullRequest
    let showsAuthor: Bool
    @State private var isHovered = false

    private var reviewLabel: String {
        switch pr.reviewStatus {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .unknown, nil: "Review status unknown"
        }
    }

    private var reviewSymbol: String {
        switch pr.reviewStatus {
        case .approved: "checkmark.circle"
        case .changesRequested: "exclamationmark.bubble"
        case .reviewRequired: "person.crop.circle.badge.clock"
        case .unknown, nil: "questionmark.circle"
        }
    }

    var body: some View {
        Group {
            if let url = pr.browserURL {
                Link(destination: url) { content }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pr.title), \(pr.repository.nameWithOwner), pull request \(pr.number)\(pr.isDraft ? ", draft" : "")\(showsAuthor ? pr.authorLogin.map { ", by \($0)" } ?? "" : ", \(reviewLabel)"). Open on GitHub.")
                    .help("Open on GitHub: \(pr.title)")
            } else {
                content
                    .accessibilityElement(children: .combine)
                    .help("This pull request has an invalid GitHub URL.")
            }
        }
        .onHover { isHovered = $0 }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            GitHubOwnerAvatar(owner: pr.repository.ownerLogin, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(pr.title)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                Text("\(pr.repository.nameWithOwner) #\(String(pr.number))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if pr.isDraft { Text("Draft") }
                    if showsAuthor {
                        Text(pr.authorLogin.map { "by @\($0)" } ?? "Author unavailable")
                            .lineLimit(1)
                    } else {
                        Label(reviewLabel, systemImage: reviewSymbol)
                            .help("GitHub’s review decision. Approval alone does not establish merge readiness.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if pr.browserURL == nil {
                    Label("GitHub link unavailable", systemImage: "link.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .contentShape(Rectangle())
        .background(isHovered && pr.browserURL != nil ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }
}
