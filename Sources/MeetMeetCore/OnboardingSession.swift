import Foundation
import Observation

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, calendars, login
}

@MainActor @Observable
public final class OnboardingSession {
    public private(set) var isPresented: Bool
    public private(set) var step = OnboardingStep.welcome
    public private(set) var errorMessage: String?
    private let state: AppState

    public init(state: AppState) {
        self.state = state
        // An unreadable/newer completion record is recovery, not a fresh install.
        isPresented = !state.onboardingCompleted && !state.recoveryNotices.contains { $0.record == .onboarding }
    }

    public func present() { step = .welcome; errorMessage = nil; isPresented = true }

    public func next() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    public func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Access, calendar selection and login launch are optional, never prerequisites.
    public func finish() {
        do {
            try state.setOnboardingCompleted(true)
            errorMessage = nil
            isPresented = false
        } catch {
            errorMessage = "Could not save setup completion. \(error.localizedDescription) Your calendar choices are unchanged."
        }
    }
}
