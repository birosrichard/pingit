import Foundation
import Observation

// ContinuousClock includes time asleep and is unaffected by wall-clock changes.
@MainActor
struct SyncClock {
    var now: () -> TimeInterval
    var sleep: (TimeInterval) async throws -> Void

    static var continuous: Self {
        let clock = ContinuousClock()
        let origin = clock.now
        return Self(now: {
            let duration = origin.duration(to: clock.now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }, sleep: { deadline in
            try await clock.sleep(until: origin.advanced(by: .seconds(deadline)), tolerance: .seconds(1))
        })
    }
}

@MainActor
@Observable
final class BackgroundSyncPreferences {
    static let intervals = [2, 5, 10, 15, 30]
    var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults?.set(enabled, forKey: "sync.enabled")
            onChange?()
        }
    }
    var intervalMinutes: Int {
        didSet {
            guard Self.intervals.contains(intervalMinutes) else { intervalMinutes = oldValue; return }
            guard oldValue != intervalMinutes else { return }
            defaults?.set(intervalMinutes, forKey: "sync.intervalMinutes")
            onChange?()
        }
    }
    var interval: TimeInterval { Double(intervalMinutes * 60) }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        enabled = defaults?.object(forKey: "sync.enabled") as? Bool ?? true
        let minutes = defaults?.integer(forKey: "sync.intervalMinutes") ?? 5
        intervalMinutes = Self.intervals.contains(minutes) ? minutes : 5
    }
}

// One cancellable deadline, rearmed only by lifecycle/refresh/preference events.
@MainActor
final class BackgroundSyncScheduler {
    let clock: SyncClock
    private(set) var deadline: TimeInterval?
    private var sleeper: Task<Void, Never>?
    private var generation = UUID()

    init(clock: SyncClock) { self.clock = clock }

    func schedule(at deadline: TimeInterval?, action: @escaping @MainActor () -> Void) {
        guard self.deadline != deadline else { return }
        cancel()
        guard let deadline else { return }
        self.deadline = deadline
        let generation = generation
        let sleep = clock.sleep
        sleeper = Task { [weak self] in
            do { try await sleep(deadline) } catch { return }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.deadline = nil
            self.sleeper = nil
            action()
        }
    }

    func cancel() {
        generation = UUID()
        sleeper?.cancel()
        sleeper = nil
        deadline = nil
    }

    deinit { sleeper?.cancel() }
}

struct ConnectionSyncState {
    var succeededAt: TimeInterval?
    var retryAt: TimeInterval?
    var rateLimitedUntil: TimeInterval?
    var failures = 0
    var requiresAttention = false

    func deadline(interval: TimeInterval) -> TimeInterval? {
        if requiresAttention { return nil }
        return retryAt ?? succeededAt.map { $0 + interval } ?? 0
    }

    mutating func failed(_ error: any Error, time: TimeInterval, date: Date, jitter: Double) {
        failures = min(failures + 1, 10)
        if let api = error as? GitHubAPIError, api == .invalidToken || api == .forbidden {
            requiresAttention = true
            retryAt = nil
            return
        }
        // Never retry a secondary limit earlier than one minute. Cap transient delay at 30 minutes.
        let delay = min(1800, 60 * pow(2, Double(failures - 1)) * (1 + max(0, min(1, jitter)) * 0.2))
        if let api = error as? GitHubAPIError {
            switch api {
            case .rateLimitedUntil(let deadline):
                rateLimitedUntil = max(rateLimitedUntil ?? 0, time + max(1, deadline.timeIntervalSince(date)))
                retryAt = rateLimitedUntil
                return
            case .rateLimited:
                rateLimitedUntil = time + delay
            default: break
            }
        }
        retryAt = max(retryAt ?? 0, time + delay)
    }
}
