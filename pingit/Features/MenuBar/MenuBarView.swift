import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(GitHubConnection.self) private var connection
    @Environment(\.openSettings) private var openSettings
    @State private var isShowingConnection = false
    @State private var selection = PullRequestInbox.review
    @State private var isShowingDetails = false

    private var dashboard: PullRequestDashboard { connection.dashboard }
    private var state: PullRequestSectionState {
        selection == .review ? dashboard.reviews : dashboard.authored
    }
    private var pullRequests: [GitHubPullRequest] { selection.pullRequests(in: state) }
    private var errors: [String] {
        [connection.errorMessage,
         dashboard.reviews.errorMessage.map { "Review: \($0)" },
         dashboard.authored.errorMessage.map { "My PRs and drafts: \($0)" }].compactMap { $0 }
    }

    private var coverage: DiscoveryCoveragePresentation {
        DiscoveryCoveragePresentation(sections: [dashboard.reviews, dashboard.authored], errors: errors)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isShowingConnection && connection.account == nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Connect GitHub").font(.headline)
                            Spacer()
                            Button("Back", systemImage: "chevron.left") { isShowingConnection = false }
                                .buttonStyle(.borderless)
                        }
                        GitHubConnectionControls()
                    }
                    .padding(20)
                }
                .frame(height: 360)
            } else if connection.account != nil {
                inbox
            } else {
                disconnected
            }

            Divider()
            footer
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { dashboard.loadIfNeeded() }
        .onChange(of: connection.account) { _, account in
            selection = .review
            if account != nil {
                isShowingConnection = false
                dashboard.loadIfNeeded()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("PingitMark")
                .resizable()
                .frame(width: 32, height: 32)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("pingit").font(.system(size: 20, weight: .bold))
                if let account = connection.account {
                    Text("@\(account.login) · \(connection.connections.count) \(connection.connections.count == 1 ? "token" : "tokens")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Aggregated across configured tokens for @\(account.login)")
                }
            }
            Spacer(minLength: 8)
            if dashboard.isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Refreshing pull requests")
            }
            Button { dashboard.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 32)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh pull requests")
                .disabled(connection.account == nil || dashboard.isLoading)
                .keyboardShortcut("r")
                .help("Refresh pull requests (⌘R)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var inbox: some View {
        VStack(spacing: 0) {
            navigation
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color(nsColor: .windowBackgroundColor))

            HStack {
                Text(selection.title).font(.system(size: 17, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if selection == .review {
                    Text("Direct requests").font(.caption).foregroundStyle(.secondary)
                        .help("Team review requests aren’t included.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if pullRequests.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pullRequests) { pr in
                            PullRequestRow(pr: pr, showsAuthor: selection == .review)
                            if pr.id != pullRequests.last?.id {
                                Divider().padding(.leading, 58).padding(.trailing, 12)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
                .frame(height: min(360, CGFloat(pullRequests.count) * 108 + 6))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(Array(PullRequestInbox.allCases.enumerated()), id: \.element.id) { index, tab in
                let tabState = tab == .review ? dashboard.reviews : dashboard.authored
                let isSelected = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 6) {
                        Text(tab == .review ? "Review" : tab == .authored ? "My PRs" : "Drafts")
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        Text(tabState.result == nil ? "—" : String(tab.pullRequests(in: tabState).count))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(isSelected ? Color(nsColor: .controlBackgroundColor) : .secondary)
                            .background(isSelected ? Color.primary : Color.primary.opacity(0.07), in: Capsule())
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityLabel(tab.label(in: tabState))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help("\(tab.title) (⌘\(index + 1))")
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox navigation")
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            if state.phase == .idle || state.phase == .loading {
                Text("Loading pull requests…").font(.headline)
            } else if state.phase == .failed {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Couldn’t update this inbox").font(.headline)
                Text("Refresh to retry, or open the warning below for details.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: selection == .review ? "checkmark.circle" : "tray")
                    .font(.title2).foregroundStyle(.secondary)
                Text(selection == .review ? "All caught up" : selection == .drafts ? "No drafts" : "No open pull requests")
                    .font(.headline)
                Text(selection == .review ? "No direct requests in the repositories visible to your tokens." : "Nothing here in the repositories visible to your tokens.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
    }

    private var disconnected: some View {
        VStack(spacing: 12) {
            if connection.isConnecting {
                ProgressView()
                Text("Connecting to GitHub…").font(.headline)
            } else {
                Image(systemName: "link").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Text(connection.hasSavedCredential ? "GitHub needs attention" : "GitHub isn’t connected")
                    .font(.headline)
                Text(connection.errorMessage ?? "Connect your GitHub account to get started.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Connect GitHub") { isShowingConnection = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if connection.account != nil {
                HStack(spacing: 6) {
                    Button {
                        isShowingDetails.toggle()
                    } label: {
                        Label(coverage.label, systemImage: coverage.systemImage)
                            .foregroundStyle(coverage.isWarning ? Color.orange : .secondary)
                    }
                    .help(coverage.details)
                    .accessibilityLabel(coverage.accessibilityLabel)
                    .popover(isPresented: $isShowingDetails) { coverageDetails }
                    Spacer(minLength: 4)
                    if let date = state.updatedAt {
                        Text(state.phase == .failed ? "Previous results" : "Updated \(date.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                            .help("Last successful update: \(date.formatted(date: .complete, time: .standard))")
                    }
                }
                .font(.caption)
            }
            HStack {
                Button("Settings…", systemImage: "gearshape") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit pingit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .foregroundStyle(.secondary)
    }

    private var coverageDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("GitHub coverage & updates").font(.headline)
                ForEach(errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if !errors.isEmpty {
                    Text("Refresh to retry. Check Settings for token, permission, or authentication issues. Previous results may be shown.")
                }
                ForEach(Array(Set(dashboard.reviews.coverageMessages + dashboard.authored.coverageMessages)).sorted(), id: \.self) { message in
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
        }
        .frame(width: 340, height: 280)
    }
}

private struct PullRequestRow: View {
    let pr: GitHubPullRequest
    let showsAuthor: Bool
    @State private var isHovered = false

    var body: some View {
        Group {
            if let url = pr.browserURL {
                Link(destination: url) { content }
                    .buttonStyle(.plain)
                    .help("\(pr.title)\n\(pr.repository.nameWithOwner) #\(pr.number)\nOpen on GitHub")
            } else {
                content.help("This pull request has an invalid GitHub URL.")
            }
        }
        .accessibilityElement(children: .combine)
        .onHover { isHovered = $0 }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            GitHubOwnerAvatar(owner: showsAuthor ? pr.authorLogin : pr.repository.ownerLogin, size: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pr.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(pr.compactUpdatedAge(relativeTo: context.date))
                    }
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
                    .help("Updated \(pr.updatedAt.formatted(date: .complete, time: .standard))")
                    .accessibilityLabel("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                Text("\(pr.repository.nameWithOwner) #\(String(pr.number))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help("\(pr.repository.nameWithOwner) #\(pr.number)")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { metadata }
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }
                .font(.system(size: 12))
                if pr.browserURL == nil {
                    Label("GitHub link unavailable", systemImage: "link")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered && pr.browserURL != nil ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var metadata: some View {
        if pr.isDraft {
            Label("Draft", systemImage: "pencil.circle").foregroundStyle(.secondary)
        }
        if showsAuthor {
            Text(pr.authorLogin.map { "@\($0)" } ?? "Author unavailable")
                .foregroundStyle(.secondary).lineLimit(1)
        } else {
            switch pr.reviewStatus {
            case .approved:
                Label("Approved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .changesRequested:
                Label("Changes requested", systemImage: "exclamationmark.bubble.fill").foregroundStyle(.red)
            case .reviewRequired:
                Label("Review pending", systemImage: "clock").foregroundStyle(.orange)
            case .unknown, nil:
                Label("Review unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
        }
        // CI is independent of the review decision; nil means it was not fetched.
        switch pr.checkStatus {
        case .success:
            Label("Checks passing", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failure:
            Label("Checks failing", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Label("Checks pending", systemImage: "clock").foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }
}
