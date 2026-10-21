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
            if result.truncationReasons.contains(.invalidCursor) {
                messages.append("Results are incomplete: GitHub returned an unusable pagination cursor.")
            }
            if !result.truncationReasons.subtracting([.invalidCursor]).isEmpty {
                messages.append("Results are incomplete: a search, page, or review request limit was reached.")
            }
        }
        if result.coverageLimitations.contains(.conflictingMetadata) {
            messages.append("Some token results disagree. Conflicting review information is shown as unknown.")
        }
        if result.coverageLimitations.contains(.tokenVisibility) {
            messages.append("Only repositories visible to your tokens are included. Some repositories may be inaccessible.")
        }
        if result.coverageLimitations.contains(.directReviewRequestsOnly) {
            messages.append("Direct requests only. Team review requests aren’t included.")
        }
        return messages
    }
}

// Structural scope stays informational; only observed problems raise a warning.
struct DiscoveryCoveragePresentation {
    let sections: [PullRequestSectionState]
    let errors: [String]

    var isWarning: Bool {
        !errors.isEmpty || sections.contains {
            $0.errorMessage != nil || $0.result?.isTruncated == true
                || $0.result?.coverageLimitations.contains(.conflictingMetadata) == true
        }
    }
    var label: String { isWarning ? "Partial results" : "Discovery info" }
    var systemImage: String { isWarning ? "exclamationmark.triangle.fill" : "info.circle" }
    var details: String {
        Array(Set(errors + sections.compactMap(\.errorMessage) + sections.flatMap(\.coverageMessages)))
            .sorted().joined(separator: "\n")
    }
    var accessibilityLabel: String { "\(label). \(details)" }
}

@MainActor
@Observable
final class PullRequestDashboard {
    typealias Fetch = @Sendable (GitHubAccount, String, Bool) async throws -> GitHubPullRequestDiscoveryResult
    struct SourceState: Equatable {
        let connection: GitHubTokenConnection
        var authored = PullRequestSectionState()
        var reviews = PullRequestSectionState()
    }
    private(set) var authored = PullRequestSectionState()
    private(set) var reviews = PullRequestSectionState()
    private(set) var account: GitHubAccount?
    private(set) var sources: [UUID: SourceState] = [:]
    var isLoading: Bool { authored.phase == .loading || reviews.phase == .loading }

    @ObservationIgnored private let credential: (String) throws -> String?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var connections: [GitHubTokenConnection] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var hasRequested = false

    init(credentials: KeychainCredentialStore = KeychainCredentialStore(),
         discovery: GitHubPullRequestDiscovery = GitHubPullRequestDiscovery()) {
        credential = { try credentials.load(account: $0) }
        fetch = { account, token, reviews in
            if reviews { return try await discovery.reviewRequestedPullRequests(for: account, token: token) }
            return try await discovery.authoredPullRequests(for: account, token: token)
        }
        now = Date.init
    }

    init(credential: @escaping () throws -> String?, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch) {
        self.credential = { _ in try credential() }
        self.now = now
        self.fetch = fetch
    }

    init(scopedCredential: @escaping (String) throws -> String?, now: @escaping () -> Date = Date.init,
         fetch: @escaping Fetch) {
        credential = scopedCredential
        self.now = now
        self.fetch = fetch
    }

    func setAccount(_ account: GitHubAccount?) {
        // Legacy deterministic seam: a fresh session even for the same identity.
        setConnections(account.map {
            [GitHubTokenConnection(id: UUID(), account: $0, resourceOwner: $0.login)]
        } ?? [], refresh: false)
    }

    func setConnections(_ rows: [GitHubTokenConnection], refresh shouldRefresh: Bool) {
        task?.cancel()
        task = nil
        session = UUID()
        connections = rows
        if rows.isEmpty { hasRequested = false }
        account = rows.compactMap(\.account).first
        sources = Dictionary(uniqueKeysWithValues: rows.map { row in
            let previous = sources[row.id]
            // Replacement changes the storage reference and must discard its private data.
            let state = previous?.connection.storageAccount == row.storageAccount ? previous : nil
            var next = SourceState(connection: row, authored: state?.authored ?? .init(), reviews: state?.reviews ?? .init())
            for review in [false, true] {
                var section = review ? next.reviews : next.authored
                if section.phase == .loading { section.phase = section.result == nil ? .idle : .loaded }
                if review { next.reviews = section } else { next.authored = section }
            }
            return (row.id, next)
        })
        lastAttempt = nil
        rebuild()
        if shouldRefresh || hasRequested { refresh() }
    }

    func loadIfNeeded() {
        hasRequested = true
        guard lastAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        refresh()
    }

    func refresh() {
        guard !connections.isEmpty, !isLoading else { return }
        session = UUID()
        lastAttempt = now()
        var work: [(GitHubTokenConnection, String)] = []
        for row in connections {
            sources[row.id]?.authored.phase = .loading
            sources[row.id]?.authored.errorMessage = nil
            sources[row.id]?.reviews.phase = .loading
            sources[row.id]?.reviews.errorMessage = nil
            do {
                guard row.account != nil, let token = try credential(row.storageAccount) else {
                    throw GitHubAPIError.invalidToken
                }
                work.append((row, token))
            } catch {
                sources[row.id]?.authored.phase = .failed
                sources[row.id]?.reviews.phase = .failed
                sources[row.id]?.authored.errorMessage = Self.message(for: error)
                sources[row.id]?.reviews.errorMessage = Self.message(for: error)
            }
        }
        rebuild()
        let session = session
        task = Task {
            // At most two token scopes, each with two independent section queries.
            await withTaskGroup(of: Void.self) { group in
                var iterator = work.makeIterator()
                for _ in 0..<2 {
                    if let (row, token) = iterator.next() {
                        group.addTask { await self.loadSource(row, token: token, session: session) }
                    }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    if let (row, token) = iterator.next() {
                        group.addTask { await self.loadSource(row, token: token, session: session) }
                    }
                }
            }
            if self.session == session { task = nil }
        }
    }

    private func loadSource(_ row: GitHubTokenConnection, token: String, session: UUID) async {
        guard let account = row.account, !Task.isCancelled else { return }
        async let authored: Void = loadSection(id: row.id, account: account, token: token, reviews: false, session: session)
        async let reviews: Void = loadSection(id: row.id, account: account, token: token, reviews: true, session: session)
        _ = await (authored, reviews)
    }

    private func loadSection(id: UUID, account: GitHubAccount, token: String, reviews isReview: Bool, session: UUID) async {
        do {
            try Task.checkCancellation()
            let result = try await fetch(account, token, isReview)
            guard self.session == session, !Task.isCancelled else { return }
            let state = PullRequestSectionState(phase: .loaded, result: result, updatedAt: now())
            if isReview { sources[id]?.reviews = state } else { sources[id]?.authored = state }
        } catch {
            guard self.session == session, !Task.isCancelled, let source = sources[id] else { return }
            var state = isReview ? source.reviews : source.authored
            if error is CancellationError {
                state.phase = state.result == nil ? .idle : .loaded
            } else {
                state.phase = .failed
                state.errorMessage = Self.message(for: error)
            }
            if isReview { sources[id]?.reviews = state } else { sources[id]?.authored = state }
        }
        rebuild()
    }

    private func rebuild() {
        authored = aggregate(review: false)
        reviews = aggregate(review: true)
    }

    private func aggregate(review: Bool) -> PullRequestSectionState {
        let entries = connections.compactMap { row -> (String, PullRequestSectionState)? in
            guard let source = sources[row.id] else { return nil }
            return (row.resourceOwner, review ? source.reviews : source.authored)
        }
        let states = entries.map(\.1)
        let results = states.compactMap(\.result)
        let failures = entries.compactMap { label, state in state.errorMessage.map { "\(label): \($0)" } }
        let phase: PullRequestSectionState.Phase = states.contains { $0.phase == .loading } ? .loading
            : !failures.isEmpty ? .failed : results.isEmpty ? .idle : .loaded
        return PullRequestSectionState(phase: phase,
                                       result: results.isEmpty ? nil : .merged(results),
                                       errorMessage: failures.isEmpty ? nil : entries.count == 1 ? states.first?.errorMessage : failures.joined(separator: "\n"),
                                       updatedAt: states.compactMap(\.updatedAt).min())
    }

    private static func message(for error: Error) -> String {
        if let error = error as? GitHubAPIError {
            switch error {
            case .invalidToken: return "Your GitHub connection needs attention. Replace its token in Settings."
            case .forbidden: return "GitHub denied access. Check token permissions and organization approval in Settings."
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

// Presentation categories share the same cached authored result, including its errors and coverage.
enum PullRequestInbox: String, CaseIterable, Identifiable {
    case review, authored, drafts
    var id: Self { self }
    var title: String {
        switch self {
        case .review: "Needs your review"
        case .authored: "My pull requests"
        case .drafts: "Draft pull requests"
        }
    }

    func pullRequests(in state: PullRequestSectionState) -> [GitHubPullRequest] {
        let requests = state.result?.pullRequests ?? []
        switch self {
        case .review: return requests
        case .authored: return requests.filter { !$0.isDraft }
        case .drafts: return requests.filter(\.isDraft)
        }
    }

    func label(in state: PullRequestSectionState) -> String {
        let name = switch self {
        case .review: "Review"
        case .authored: "My PRs"
        case .drafts: "Drafts"
        }
        return "\(name) \(state.result == nil ? "—" : String(pullRequests(in: state).count))"
    }
}
