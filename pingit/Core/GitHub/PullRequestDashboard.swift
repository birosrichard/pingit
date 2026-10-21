import Foundation
import Observation

struct PullRequestSectionState: Equatable {
    enum Phase { case idle, loading, loaded, failed }
    var phase: Phase = .idle
    var result: GitHubPullRequestDiscoveryResult?
    var errorMessage: String?
    var updatedAt: Date?

    var coverageMessages: [String] {
        guard let result else { return [] }
        var messages: [String] = []
        if result.isTruncated {
            messages.append("Results are incomplete: a search, page, or reviewer limit was reached.")
        }
        if result.coverageLimitations.contains(.tokenVisibility) {
            messages.append("Only repositories visible to your token are included. Some repositories may be inaccessible.")
        }
        if result.coverageLimitations.contains(.directReviewRequestsOnly) {
            messages.append("Direct requests only. Team review requests aren’t included.")
        }
        return messages
    }
}

@MainActor
@Observable
final class PullRequestDashboard {
    typealias Fetch = @Sendable (GitHubAccount, String, Bool) async throws -> GitHubPullRequestDiscoveryResult

    private(set) var authored = PullRequestSectionState()
    private(set) var reviews = PullRequestSectionState()
    private(set) var account: GitHubAccount?
    var isLoading: Bool { authored.phase == .loading || reviews.phase == .loading }

    @ObservationIgnored private let credential: () throws -> String?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var lastAttempt: Date?

    init(credentials: KeychainCredentialStore = KeychainCredentialStore(),
         discovery: GitHubPullRequestDiscovery = GitHubPullRequestDiscovery()) {
        credential = { try credentials.load() }
        fetch = { account, token, reviews in
            if reviews { return try await discovery.reviewRequestedPullRequests(for: account, token: token) }
            return try await discovery.authoredPullRequests(for: account, token: token)
        }
        now = Date.init
    }

    // Narrow deterministic seams; production uses the existing Keychain and discovery services.
    init(credential: @escaping () throws -> String?, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch) {
        self.credential = credential
        self.now = now
        self.fetch = fetch
    }

    func setAccount(_ account: GitHubAccount?) {
        task?.cancel()
        task = nil
        session = UUID()
        self.account = account
        authored = PullRequestSectionState()
        reviews = PullRequestSectionState()
        lastAttempt = nil
    }

    func loadIfNeeded() {
        guard lastAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        refresh()
    }

    func refresh() {
        guard let account, !isLoading else { return }
        lastAttempt = now()
        authored.phase = .loading
        authored.errorMessage = nil
        reviews.phase = .loading
        reviews.errorMessage = nil
        let token: String
        do {
            guard let saved = try credential() else { throw GitHubAPIError.invalidToken }
            token = saved
        } catch {
            let message = Self.message(for: error)
            authored.phase = .failed
            authored.errorMessage = message
            reviews.phase = .failed
            reviews.errorMessage = message
            return
        }
        let session = session
        task = Task {
            async let authored: Void = loadSection(account: account, token: token, reviews: false, session: session)
            async let reviews: Void = loadSection(account: account, token: token, reviews: true, session: session)
            _ = await (authored, reviews)
            if self.session == session { task = nil }
        }
    }

    private func loadSection(account: GitHubAccount, token: String, reviews isReview: Bool, session: UUID) async {
        do {
            let result = try await fetch(account, token, isReview)
            guard self.session == session, !Task.isCancelled else { return }
            let state = PullRequestSectionState(phase: .loaded, result: result, updatedAt: now())
            if isReview { reviews = state } else { authored = state }
        } catch {
            guard self.session == session, !Task.isCancelled else { return }
            var state = isReview ? reviews : authored
            if error is CancellationError {
                state.phase = state.result == nil ? .idle : .loaded
            } else {
                state.phase = .failed
                state.errorMessage = Self.message(for: error)
            }
            if isReview { reviews = state } else { authored = state }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? GitHubAPIError {
            switch error {
            case .invalidToken: return "Your GitHub connection needs attention. Reconnect in Settings."
            case .forbidden: return "Some repositories may be inaccessible. Check token permissions and organization approval in Settings."
            default: return error.localizedDescription
            }
        }
        if let error = error as? GitHubDiscoveryError { return error.localizedDescription }
        if error is KeychainCredentialStore.StorageError {
            return "Couldn’t read the saved credential. Check Keychain access and your GitHub connection in Settings."
        }
        return "Couldn’t load pull requests. Check your connection and refresh to retry."
    }
}
