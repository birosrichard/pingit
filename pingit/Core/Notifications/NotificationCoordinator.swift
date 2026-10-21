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

    init(service: any NotificationService, preferences: NotificationPreferences) {
        self.service = service
        self.preferences = preferences
    }

    func refreshAuthorization() async {
        permissionGeneration += 1
        let generation = permissionGeneration
        let status = await service.authorizationStatus()
        guard generation == permissionGeneration, !Task.isCancelled else { return }
        permission = status
    }

    // Called only by the explicit Settings button, never by launch, polling or a toggle.
    func requestPermission() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        errorMessage = nil
        defer { isRequestingPermission = false }
        await refreshAuthorization()
        guard !Task.isCancelled, permission == .notDetermined else { return }
        do { try await service.requestAuthorization() }
        catch { errorMessage = "Couldn’t request notification permission. Try again in Settings." }
        await refreshAuthorization()
    }
}
