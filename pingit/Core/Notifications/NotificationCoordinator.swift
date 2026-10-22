import Foundation
import Observation

@MainActor
@Observable
final class NotificationCoordinator {
    let preferences: NotificationPreferences
    private(set) var permission: NotificationPermission = .unknown
    private(set) var isRequestingPermission = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any NotificationService
    @ObservationIgnored private var permissionGeneration: UInt64 = 0
    @ObservationIgnored private var deliveryGeneration: UInt64 = 0
    @ObservationIgnored private var delivery: Task<Void, Never>?
    @ObservationIgnored private var pending: [NotificationMessage] = []
    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var seenOrder: [String] = []
    @ObservationIgnored private weak var dashboard: PullRequestDashboard?
    @ObservationIgnored private var stopped = false
    private(set) var isDelivering = false
    // Best effort, bounded memory; Phase 5B owns durable baseline deduplication.
    static let pendingLimit = 100
    static let deduplicationLimit = 512

    init(service: any NotificationService, preferences: NotificationPreferences) {
        self.service = service
        self.preferences = preferences
        preferences.onChange = { [weak self] in self?.cancelPending() }
    }

    func start(dashboard: PullRequestDashboard) {
        if let previous = self.dashboard, previous !== dashboard {
            previous.onChanges = nil
            previous.onChangeDeliveryInvalidated = nil
            cancelPending()
        }
        stopped = false
        self.dashboard = dashboard
        dashboard.onChanges = { [weak self] in self?.consume($0) }
        dashboard.onChangeDeliveryInvalidated = { [weak self] in self?.cancelPending() }
    }

    func stop() {
        stopped = true
        permissionGeneration += 1
        dashboard?.onChanges = nil
        dashboard?.onChangeDeliveryInvalidated = nil
        dashboard = nil
        cancelPending()
    }

    func consume(_ events: [PullRequestChangeEvent]) {
        guard !stopped, preferences.enabled else { return }
        for event in events {
            guard preferences.allows(event.kind),
                  let message = NotificationMessage(event: event, sound: preferences.sound),
                  seen.insert(message.identifier).inserted else { continue }
            seenOrder.append(message.identifier)
            if seenOrder.count > Self.deduplicationLimit {
                seen.remove(seenOrder.removeFirst())
            }
            if pending.count < Self.pendingLimit { pending.append(message) }
        }
        beginDeliveryIfNeeded()
    }

    private func beginDeliveryIfNeeded() {
        guard delivery == nil, !pending.isEmpty else { return }
        let generation = deliveryGeneration
        isDelivering = true
        delivery = Task { [weak self] in
            guard let self else { return }
            await self.drain(generation: generation)
        }
    }

    private func drain(generation: UInt64) async {
        defer {
            if generation == deliveryGeneration { delivery = nil; isDelivering = false }
        }
        while !pending.isEmpty {
            guard generation == deliveryGeneration, !Task.isCancelled, preferences.enabled else { return }
            let status = await readAuthorization()
            guard generation == deliveryGeneration, !Task.isCancelled, preferences.enabled else { return }
            let message = pending.removeFirst()
            guard status.allowsDelivery else { continue }
            do {
                try await service.deliver(message)
                guard generation == deliveryGeneration, !Task.isCancelled else { return }
                errorMessage = nil
            } catch {
                guard generation == deliveryGeneration, !Task.isCancelled else { return }
                // No raw framework error or private content is logged or persisted.
                errorMessage = "Couldn’t deliver a notification. Check macOS notification settings."
            }
        }
    }

    #if DEBUG
    func sendDebugNotification() {
        guard !stopped, preferences.enabled, permission.allowsDelivery, pending.count < Self.pendingLimit else { return }
        pending.append(NotificationMessage(identifier: "pingit.debug.\(UUID().uuidString)",
            threadIdentifier: "pingit.debug", title: "pingit test notification",
            subtitle: "octocat/Hello-World #1", body: "Synthetic sample — click to open the public example PR.",
            pullRequestURL: "https://github.com/octocat/Hello-World/pull/1", sound: preferences.sound))
        beginDeliveryIfNeeded()
    }
    #endif

    func cancelPending() {
        deliveryGeneration += 1
        delivery?.cancel()
        delivery = nil
        pending.removeAll()
        isDelivering = false
    }

    func refreshAuthorization() async {
        _ = await readAuthorization()
    }

    private func readAuthorization() async -> NotificationPermission {
        guard !stopped else { return .unavailable }
        permissionGeneration += 1
        let generation = permissionGeneration
        let status = await service.authorizationStatus()
        guard !stopped, !Task.isCancelled else { return .unavailable }
        // A newer UI refresh must not discard the permission result needed by this caller.
        if generation == permissionGeneration { permission = status }
        return status
    }

    deinit { delivery?.cancel() }

    // Called only by the explicit Settings button, never by launch, polling or a toggle.
    func requestPermission() async {
        guard !stopped, !isRequestingPermission else { return }
        isRequestingPermission = true
        errorMessage = nil
        defer { isRequestingPermission = false }
        let status = await readAuthorization()
        guard !stopped, !Task.isCancelled, status == .notDetermined else { return }
        do { try await service.requestAuthorization() }
        catch {
            guard !stopped, !Task.isCancelled else { return }
            errorMessage = "Couldn’t request notification permission. Try again in Settings."
        }
        await refreshAuthorization()
    }
}
