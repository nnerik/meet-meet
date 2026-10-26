import Foundation
import Observation

public enum AppStateRecord: String, CaseIterable, Sendable {
    case preferences, selectedCalendars, onboarding, pause, hudPosition, hiddenEvents, countdownSuppressions, handledCues, dismissedSplashCues

    public var storageKey: String { "meetmeet.\(rawValue)" }
}

public struct StateRecoveryNotice: Equatable, Sendable {
    public let record: AppStateRecord
    public let reason: Reason

    public enum Reason: Equatable, Sendable {
        case unreadable
        case unsupportedVersion(Int)
    }
}

public enum AppStateError: Error, LocalizedError, Equatable {
    case newerRecord(AppStateRecord)
    case invalidPosition

    public var errorDescription: String? {
        switch self {
        case .newerRecord: "These settings were saved by another app version and have been preserved. Use that version to change them."
        case .invalidPosition: "The countdown position must contain finite screen coordinates."
        }
    }
}

@MainActor @Observable
public final class AppState {
    public private(set) var preferences: AppPreferences
    public private(set) var selectedCalendarIDs: Set<String>
    public private(set) var onboardingCompleted: Bool
    public private(set) var pauseUntil: Date?
    public private(set) var hudPosition: HUDPosition?
    public private(set) var hiddenEvents: [HiddenEventRule]
    public private(set) var countdownSuppressions: [CountdownSuppression]
    public private(set) var handledCues: [HandledCue]
    public private(set) var dismissedSplashCues: Set<OccurrenceKey>
    public private(set) var recoveryNotices: [StateRecoveryNotice]

    private let storage: any LocalStateStoring
    private let protectedRecords: Set<AppStateRecord>

    public init(storage: any LocalStateStoring) {
        self.storage = storage
        var notices: [StateRecoveryNotice] = []
        var protected: Set<AppStateRecord> = []

        func load<Value: Decodable>(_ record: AppStateRecord, fallback: Value) -> Value {
            guard let data = storage.data(forKey: record.storageKey) else { return fallback }
            do {
                let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
                guard probe.version == 1 else {
                    notices.append(StateRecoveryNotice(record: record, reason: .unsupportedVersion(probe.version)))
                    protected.insert(record)
                    return fallback
                }
                return try JSONDecoder().decode(Envelope<Value>.self, from: data).value
            } catch {
                notices.append(StateRecoveryNotice(record: record, reason: .unreadable))
                return fallback
            }
        }

        preferences = load(.preferences, fallback: AppPreferences())
        selectedCalendarIDs = load(.selectedCalendars, fallback: [])
        onboardingCompleted = load(.onboarding, fallback: false)
        pauseUntil = load(.pause, fallback: Optional<Date>.none)
        hudPosition = load(.hudPosition, fallback: Optional<HUDPosition>.none)
        hiddenEvents = load(.hiddenEvents, fallback: [])
        countdownSuppressions = load(.countdownSuppressions, fallback: [])
        handledCues = load(.handledCues, fallback: [])
        dismissedSplashCues = load(.dismissedSplashCues, fallback: [])
        recoveryNotices = notices
        protectedRecords = protected
    }

    public func updatePreferences(_ change: (inout AppPreferences) -> Void) throws {
        var next = preferences
        change(&next)
        next = try next.validated()
        guard next != preferences else { return }
        try save(next, record: .preferences)
        preferences = next
    }

    public func setSelectedCalendarIDs(_ ids: Set<String>) throws {
        try save(ids, record: .selectedCalendars)
        selectedCalendarIDs = ids
    }

    /// Changing discovery results never changes stored choices or selects new calendars.
    public func selectedCalendars(in available: [CalendarDescriptor]) -> [CalendarDescriptor] {
        available.filter { selectedCalendarIDs.contains($0.id) }
    }

    public func setOnboardingCompleted(_ completed: Bool) throws {
        try save(completed, record: .onboarding)
        onboardingCompleted = completed
    }

    public func setPauseUntil(_ expiry: Date?) throws {
        try save(expiry, record: .pause)
        pauseUntil = expiry
    }

    public func setHUDPosition(_ position: HUDPosition?) throws {
        if let position, !position.isFinite {
            throw AppStateError.invalidPosition
        }
        try save(position, record: .hudPosition)
        hudPosition = position
    }

    public func setHiddenEvents(_ rules: [HiddenEventRule]) throws {
        try save(rules, record: .hiddenEvents)
        hiddenEvents = rules
    }

    public func setCountdownSuppressions(_ suppressions: [CountdownSuppression]) throws {
        try save(suppressions, record: .countdownSuppressions)
        countdownSuppressions = suppressions
    }

    public func setHandledCues(_ cues: [HandledCue]) throws {
        try save(cues, record: .handledCues)
        handledCues = cues
    }

    public func setDismissedSplashCues(_ occurrences: Set<OccurrenceKey>) throws {
        try save(occurrences, record: .dismissedSplashCues)
        dismissedSplashCues = occurrences
    }

    private func save<Value: Encodable>(_ value: Value, record: AppStateRecord) throws {
        guard !protectedRecords.contains(record) else { throw AppStateError.newerRecord(record) }
        let data = try JSONEncoder().encode(EncodingEnvelope(version: 1, value: value))
        storage.set(data, forKey: record.storageKey)
        recoveryNotices.removeAll { $0.record == record }
    }
}

private struct VersionProbe: Decodable { let version: Int }
private struct Envelope<Value: Decodable>: Decodable { let version: Int; let value: Value }
private struct EncodingEnvelope<Value: Encodable>: Encodable { let version: Int; let value: Value }
