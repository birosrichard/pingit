import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(GitHubConnection.self) private var connection
    @Environment(\.openSettings) private var openSettings
    @State private var isShowingConnection = false
    @State private var selection = PullRequestInbox.review
    @State private var isShowingDetails = false
    @State private var listContentHeight: CGFloat?
    @FocusState private var focusedTab: PullRequestInbox?

    init(selection: PullRequestInbox = .review) {
        _selection = State(initialValue: selection)
    }

    private var screenFrame: CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 492, height: 900)
    }

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
        .frame(width: DashboardLayout.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { dashboard.loadIfNeeded() }
        .onChange(of: selection) { _, _ in listContentHeight = nil }
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
                Text("pingit").font(.title.weight(.bold))
                if let account = connection.account {
                    Text("@\(account.login) · \(connection.connections.count) \(connection.connections.count == 1 ? "token" : "tokens")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Aggregated across configured tokens for @\(account.login)")
                }
            }
            Spacer(minLength: 8)
            if dashboard.isLoading && (dashboard.authored.result != nil || dashboard.reviews.result != nil) {
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
        .padding(.horizontal, DashboardLayout.horizontalInset)
        .padding(.vertical, 16)
    }

    private var inbox: some View {
        VStack(spacing: 0) {
            navigation
                .padding(.horizontal, DashboardLayout.horizontalInset)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(Color(nsColor: .windowBackgroundColor))

            HStack {
                Text(selection.contextTitle).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if selection == .review {
                    Text("Direct only").font(.caption).foregroundStyle(.secondary)
                        .help("Team review requests aren’t included.")
                }
            }
            .padding(.horizontal, DashboardLayout.horizontalInset)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if pullRequests.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pullRequests) { pr in
                            PullRequestRow(presentation: .init(pr: pr, inbox: selection))
                            if pr.id != pullRequests.last?.id {
                                Divider()
                                    .padding(.leading, DashboardLayout.rowInset + DashboardLayout.avatarSize + DashboardLayout.avatarSpacing)
                                    .padding(.trailing, DashboardLayout.rowInset)
                            }
                        }
                    }
                    .padding(4)
                    .padding(.trailing, 8) // Leave room for macOS overlay scroll indicators.
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: PullRequestListHeightKey.self, value: geometry.size.height)
                        }
                    }
                }
                .onPreferenceChange(PullRequestListHeightKey.self) { height in
                    if height > 0 { listContentHeight = height }
                }
                .id(selection)
                .frame(height: DashboardLayout.listHeight(rowCount: pullRequests.count, availableScreenHeight: screenFrame.height,
                                                        contentHeight: listContentHeight))
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary.opacity(0.6))
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, DashboardLayout.listInset)
                .padding(.bottom, 16)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 4) {
            ForEach(Array(PullRequestInbox.allCases.enumerated()), id: \.element.id) { index, tab in
                let tabState = tab == .review ? dashboard.reviews : dashboard.authored
                let isSelected = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 6) {
                        Text(tab.shortTitle)
                            .font(.body.weight(isSelected ? .semibold : .medium))
                        Text(tabState.result == nil ? "—" : String(tab.pullRequests(in: tabState).count))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background(isSelected ? Color(nsColor: .controlBackgroundColor) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(focusedTab == tab ? Color.accentColor : .clear, lineWidth: 2)
                    }
                }
                .buttonStyle(.plain)
                .focused($focusedTab, equals: tab)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityLabel(tab.label(in: tabState))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help("\(tab.title) (⌘\(index + 1))")
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .onKeyPress(.leftArrow) { moveTab(by: -1); return .handled }
        .onKeyPress(.rightArrow) { moveTab(by: 1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inbox navigation")
    }

    private func moveTab(by offset: Int) {
        let tabs = PullRequestInbox.allCases
        guard let index = tabs.firstIndex(of: focusedTab ?? selection) else { return }
        let next = tabs[min(tabs.count - 1, max(0, index + offset))]
        selection = next
        focusedTab = next
    }

    private var emptyState: some View {
        let display = PullRequestEmptyPresentation(inbox: selection, phase: state.phase)
        return VStack(spacing: 8) {
            if display.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: display.systemImage)
                    .font(.title2)
                    .foregroundStyle(display.isFailure ? Color.orange : .secondary)
            }
            Text(display.title).font(.headline)
            Text(display.message).font(.callout).foregroundStyle(.secondary)
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
                .font(.callout)
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
        .padding(.horizontal, DashboardLayout.horizontalInset)
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

private enum PullRequestListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
