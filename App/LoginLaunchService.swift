import ServiceManagement
import MeetMeetCore

@MainActor
final class LoginLaunchService: LoginLaunchServicing {
    var status: LoginLaunchStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .off
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unknown
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
