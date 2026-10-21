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
            messages.append("Some token results disagree. Conflicting pull request metadata is shown conservatively.")
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
    var label: String {
        if !errors.isEmpty || sections.contains(where: { $0.errorMessage != nil }) { return "GitHub needs attention" }
        return isWarning ? "Partial results" : "Discovery info"
    }
    var systemImage: String { isWarning ? "exclamationmark.triangle.fill" : "info.circle" }
    var details: String {
        let failures = errors.isEmpty ? sections.compactMap(\.errorMessage) : errors
        return Array(Set(failures + sections.flatMap(\.coverageMessages)))
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
    var isLoading: Bool { isRefreshing || authored.phase == .loading || reviews.phase == .loading }
    private(set) var isRefreshing = false
    private(set) var lastAttemptAt: Date?
    private(set) var lastSuccessfulRefreshAt: Date?
    let syncPreferences: BackgroundSyncPreferences
    var nextAutomaticRefresh: TimeInterval? { scheduler.deadline }

    @ObservationIgnored private let scheduler: BackgroundSyncScheduler
    @ObservationIgnored private let jitter: () -> Double
    @ObservationIgnored private var syncStates: [UUID: ConnectionSyncState] = [:]
    @ObservationIgnored private var running = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var flightErrors: [UUID: [any Error]] = [:]
    @ObservationIgnored private var flightResults: [String: PullRequestChangeInput.Sections] = [:]
    @ObservationIgnored private let changeDetector: PullRequestChangeDetector?
    @ObservationIgnored private var connectionGeneration: UInt64 = 0
    @ObservationIgnored private var refreshSequence: UInt64 = 0
    // One replaceable consumer, no replay buffer or accumulated activity history.
    @ObservationIgnored var onChanges: (@MainActor ([PullRequestChangeEvent]) -> Void)?
    // Invalidate downstream asynchronous delivery with the same lifecycle/session boundary.
    @ObservationIgnored var onChangeDeliveryInvalidated: (@MainActor () -> Void)?
    private(set) var changeDetectionStorageFailed = false

    @ObservationIgnored private let credential: (String) throws -> String?
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var connections: [GitHubTokenConnection] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var hasRequested = false

    init(credentials: KeychainCredentialStore = KeychainCredentialStore(),
         discovery: GitHubPullRequestDiscovery = GitHubPullRequestDiscovery(),
         changeDetector: PullRequestChangeDetector? = nil,
         preferences: BackgroundSyncPreferences = BackgroundSyncPreferences(defaults: .standard)) {
        self.changeDetector = changeDetector
        syncPreferences = preferences
        scheduler = BackgroundSyncScheduler(clock: .continuous)
        jitter = { Double.random(in: 0...1) }
        credential = { try credentials.load(account: $0) }
        fetch = { account, token, reviews in
            if reviews { return try await discovery.reviewRequestedPullRequests(for: account, token: token) }
            return try await discovery.authoredPullRequests(for: account, token: token)
        }
        now = Date.init
    }

    init(credential: @escaping () throws -> String?, now: @escaping () -> Date = Date.init,
         clock: SyncClock = .continuous, jitter: @escaping () -> Double = { Double.random(in: 0...1) },
         fetch: @escaping Fetch) {
        changeDetector = nil
        syncPreferences = BackgroundSyncPreferences()
        scheduler = BackgroundSyncScheduler(clock: clock)
        self.jitter = jitter
        self.credential = { _ in try credential() }
        self.now = now
        self.fetch = fetch
    }

    init(scopedCredential: @escaping (String) throws -> String?, now: @escaping () -> Date = Date.init,
         clock: SyncClock = .continuous, jitter: @escaping () -> Double = { Double.random(in: 0...1) },
         changeDetector: PullRequestChangeDetector? = nil,
         preferences: BackgroundSyncPreferences = BackgroundSyncPreferences(), fetch: @escaping Fetch) {
        self.changeDetector = changeDetector
        syncPreferences = preferences
        scheduler = BackgroundSyncScheduler(clock: clock)
        self.jitter = jitter
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
        guard rows != connections else { return }
        invalidateRefresh()
        connectionGeneration += 1
        let generation = connectionGeneration
        let scopes = rows.compactMap(PullRequestChangeScope.init)
        if let changeDetector {
            Task {
                let failed = await changeDetector.reconcile(scopes: scopes, generation: generation)
                if connectionGeneration == generation { changeDetectionStorageFailed = failed }
            }
        }
        syncStates = Dictionary(uniqueKeysWithValues: rows.map { row in
            let sameCredential = sources[row.id]?.connection.storageAccount == row.storageAccount
            return (row.id, sameCredential ? syncStates[row.id] ?? .init() : .init())
        })
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
        lastSuccessfulRefreshAt = sources.values.flatMap { [$0.authored.updatedAt, $0.reviews.updatedAt] }.compactMap { $0 }.max()
        if rows.isEmpty {
            lastSuccessfulRefreshAt = nil
            lastAttemptAt = nil
        }
        if shouldRefresh || hasRequested {
            if task != nil { pendingRefresh = true } else { refresh() }
        }
        reschedule()
    }

    func startBackgroundSync() {
        guard !running else { return }
        running = true
        syncPreferences.onChange = { [weak self] in self?.reschedule() }
        reschedule()
    }

    func shutdown() {
        running = false
        syncPreferences.onChange = nil
        scheduler.cancel()
        invalidateRefresh()
        rebuild()
    }

    func systemWillSleep() {
        sleeping = true
        scheduler.cancel()
        invalidateRefresh()
        rebuild()
    }

    func systemDidWake() {
        sleeping = false
        reschedule()
    }

    private func invalidateRefresh() {
        onChangeDeliveryInvalidated?()
        session = UUID()
        task?.cancel()
        watchdog?.cancel()
        watchdog = nil
        pendingRefresh = false
        isRefreshing = false
        for id in sources.keys {
            guard var source = sources[id] else { continue }
            if source.authored.phase == .loading {
                source.authored.phase = source.authored.result == nil ? .idle : .loaded
            }
            if source.reviews.phase == .loading {
                source.reviews.phase = source.reviews.result == nil ? .idle : .loaded
            }
            sources[id] = source
        }
    }

    private func reschedule() {
        let deadline = running && syncPreferences.enabled && !sleeping && task == nil
            ? connections.filter { $0.account != nil }.compactMap {
                syncStates[$0.id]?.deadline(interval: syncPreferences.interval)
            }.min() : nil
        scheduler.schedule(at: deadline) { [weak self] in self?.refresh(automatic: true) }
    }

    func loadIfNeeded() {
        hasRequested = true
        guard lastAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        refresh()
    }

    // Active requests coalesce into the current flight. Only identity changes queue one follow-up,
    // after cancelled workers drain; this also prevents old/new credentials from overlapping.
    func refresh(automatic: Bool = false) {
        guard !connections.isEmpty, !sleeping else { return }
        if let task {
            if task.isCancelled { pendingRefresh = true }
            return
        }
        let time = scheduler.clock.now()
        let eligible = connections.filter { row in
            let state = syncStates[row.id] ?? .init()
            if let rateDeadline = state.rateLimitedUntil, rateDeadline > time { return false }
            if automatic {
                guard row.account != nil, let deadline = state.deadline(interval: syncPreferences.interval) else { return false }
                return deadline <= time
            }
            return true
        }
        guard !eligible.isEmpty else { reschedule(); return }
        scheduler.cancel()
        session = UUID()
        lastAttempt = now()
        refreshSequence += 1
        lastAttemptAt = lastAttempt
        flightErrors = [:]
        flightResults = [:]
        var work: [(GitHubTokenConnection, String)] = []
        for row in eligible {
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
                syncStates[row.id]?.failed(error, time: time, date: now(), jitter: jitter())
            }
        }
        rebuild()
        guard !work.isEmpty else { reschedule(); return }
        isRefreshing = true
        let session = session
        let sleep = scheduler.clock.sleep
        watchdog = Task { [weak self] in
            do { try await sleep(time + 120) } catch { return }
            guard !Task.isCancelled, let self, self.session == session else { return }
            for row in eligible {
                for review in [false, true] {
                    guard var state = review ? self.sources[row.id]?.reviews : self.sources[row.id]?.authored,
                          state.phase == .loading else { continue }
                    state.phase = .failed
                    state.errorMessage = "Refresh timed out. Try again later."
                    if review { self.sources[row.id]?.reviews = state } else { self.sources[row.id]?.authored = state }
                }
                self.syncStates[row.id]?.failed(GitHubAPIError.networkUnavailable,
                                                time: self.scheduler.clock.now(), date: self.now(), jitter: self.jitter())
            }
            self.session = UUID()
            self.task?.cancel()
            self.rebuild()
        }
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
            watchdog?.cancel()
            watchdog = nil
            if self.session == session, !Task.isCancelled, let changeDetector {
                let input = PullRequestChangeInput(sequence: refreshSequence, scopes: connections.compactMap(PullRequestChangeScope.init),
                                                   results: flightResults, observedAt: now())
                let output = await changeDetector.process(input, generation: connectionGeneration)
                if self.session == session, !Task.isCancelled {
                    changeDetectionStorageFailed = output.storageFailed
                    if !output.events.isEmpty { onChanges?(output.events) }
                }
            }
            task = nil
            isRefreshing = false
            if pendingRefresh && !sleeping {
                pendingRefresh = false
                refresh()
            }
            reschedule()
        }
    }

    private func loadSource(_ row: GitHubTokenConnection, token: String, session: UUID) async {
        guard let account = row.account, !Task.isCancelled else { return }
        async let authored: Void = loadSection(id: row.id, account: account, token: token, reviews: false, session: session)
        async let reviews: Void = loadSection(id: row.id, account: account, token: token, reviews: true, session: session)
        _ = await (authored, reviews)
        guard self.session == session, !Task.isCancelled else { return }
        if let errors = flightErrors[row.id], !errors.isEmpty {
            let apiErrors = errors.compactMap { $0 as? GitHubAPIError }
            let authError = apiErrors.first { $0 == .invalidToken || $0 == .forbidden }
            let rateError = apiErrors.compactMap(\.retryDeadline).max().map { GitHubAPIError.rateLimitedUntil($0) }
                ?? (apiErrors.contains(.rateLimited) ? .rateLimited : nil)
            var state = syncStates[row.id] ?? .init()
            state.failed(rateError ?? authError ?? errors[0], time: scheduler.clock.now(), date: now(), jitter: jitter())
            if authError != nil { state.requiresAttention = true; state.retryAt = nil }
            syncStates[row.id] = state
        } else {
            syncStates[row.id] = ConnectionSyncState(succeededAt: scheduler.clock.now())
        }
    }

    private func loadSection(id: UUID, account: GitHubAccount, token: String, reviews isReview: Bool, session: UUID) async {
        do {
            try Task.checkCancellation()
            let result = try await fetch(account, token, isReview)
            guard self.session == session, !Task.isCancelled else { return }
            guard let connection = sources[id]?.connection else { return }
            if isReview { flightResults[connection.storageAccount, default: .init()].requested = result }
            else { flightResults[connection.storageAccount, default: .init()].authored = result }
            lastSuccessfulRefreshAt = now()
            let state = PullRequestSectionState(phase: .loaded, result: result, updatedAt: lastSuccessfulRefreshAt)
            if isReview { sources[id]?.reviews = state } else { sources[id]?.authored = state }
        } catch {
            guard self.session == session, !Task.isCancelled, let source = sources[id] else { return }
            var state = isReview ? source.reviews : source.authored
            if error is CancellationError {
                state.phase = state.result == nil ? .idle : .loaded
                flightErrors[id, default: []].append(GitHubAPIError.networkUnavailable)
            } else {
                state.phase = .failed
                state.errorMessage = Self.message(for: error)
                flightErrors[id, default: []].append(error)
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

    deinit {
        task?.cancel()
        watchdog?.cancel()
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
        return "\(name) \(countText(in: state))"
    }

    func countText(in state: PullRequestSectionState) -> String {
        state.result == nil ? "—" : String(pullRequests(in: state).count)
    }
}
