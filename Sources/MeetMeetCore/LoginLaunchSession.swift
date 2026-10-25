import Foundation
import Observation

public enum LoginLaunchStatus: Equatable, Sendable {
    case off, enabled, requiresApproval, unavailable, unknown

    public var isRequested: Bool { self == .enabled || self == .requiresApproval }

    public var description: String {
        switch self {
        case .off: "Off"
        case .enabled: "Enabled"
        case .requiresApproval: "Approval needed in System Settings"
        case .unavailable: "Service unavailable"
        case .unknown: "Unknown service status"
        }
    }
}

@MainActor
public protocol LoginLaunchServicing {
    var status: LoginLaunchStatus { get }
    func register() throws
    func unregister() async throws
}

/// OS service state is authoritative. There is intentionally no persisted toggle
/// and no registration from initialization, refresh, launch, or onboarding completion.
@MainActor @Observable
public final class LoginLaunchSession {
    public private(set) var status: LoginLaunchStatus
    public private(set) var isChanging = false
    public private(set) var errorMessage: String?
    private let service: any LoginLaunchServicing

    public init(service: any LoginLaunchServicing) {
        self.service = service
        status = service.status
    }

    public func refresh() { status = service.status }

    public func setEnabled(_ enabled: Bool) async {
        guard !isChanging else { return }
        refresh()
        guard enabled != status.isRequested else { return }
        isChanging = true
        errorMessage = nil
        defer { refresh(); isChanging = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
        } catch {
            errorMessage = "Could not change launch at login. \(error.localizedDescription) Keep Meet Meet in a stable location, then retry. Check Login Items in System Settings for approval or restrictions."
        }
    }
}
