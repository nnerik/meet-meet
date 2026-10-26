import Foundation
import Testing
@testable import MeetMeetCore

private let splashNow = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor private final class SplashStorage: LocalStateStoring {
    var records: [String: Data] = [:]
    var writes = 0
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data; writes += 1 }
}

private func splashMeeting(_ id: String = "one", startsIn: TimeInterval = 60, calendar: String = "work") -> MeetingOccurrence {
    MeetingOccurrence(id: id, calendarID: calendar, title: "Meeting \(id)",
                      start: splashNow.addingTimeInterval(startsIn), end: splashNow.addingTimeInterval(startsIn + 600))
}

@MainActor private func splashState(_ store: SplashStorage = SplashStorage()) throws -> AppState {
    let state = AppState(storage: store)
    try state.setSelectedCalendarIDs(["work"])
    return state
}

@Test @MainActor func splashAppearsAtThresholdCatchesUpAndDisappearsAtStart() throws {
    let session = SplashCueSession(state: try splashState())
    let event = splashMeeting()
    session.update(occurrences: [event], isActive: true, at: splashNow.addingTimeInterval(-0.001))
    #expect(session.meetings.isEmpty)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.meetings == [event])
    session.reset() // Launch/wake/refresh can rediscover a still-upcoming meeting.
    session.update(occurrences: [event], isActive: true, at: splashNow.addingTimeInterval(45))
    #expect(session.meetings == [event])
    session.update(occurrences: [event], isActive: true, at: event.start)
    #expect(session.meetings.isEmpty)
}

@Test @MainActor func splashDismissalCoalescesCurrentMeetingsAndSurvivesRestart() throws {
    let store = SplashStorage()
    let state = try splashState(store)
    let session = SplashCueSession(state: state)
    let events = [splashMeeting("two"), splashMeeting("one")]
    session.update(occurrences: events, isActive: true, at: splashNow)
    #expect(session.meetings.map(\.id) == ["one", "two"])
    session.dismiss()
    #expect(session.meetings.isEmpty)
    let writes = store.writes
    let restored = SplashCueSession(state: AppState(storage: store))
    restored.update(occurrences: events, isActive: true, at: splashNow)
    #expect(restored.meetings.isEmpty)
    #expect(store.writes == writes)
    let next = splashMeeting("next")
    restored.update(occurrences: events + [next], isActive: true, at: splashNow)
    #expect(restored.meetings == [next])
}

@Test @MainActor func splashSettingsSelectionAndInactiveInputRemoveIt() throws {
    let state = try splashState()
    let session = SplashCueSession(state: state)
    let event = splashMeeting(startsIn: 120)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty)
    try state.updatePreferences { $0.splashLeadMinutes = 2; $0.hudLeadMinutes = 0 }
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.meetings == [event])
    session.update(occurrences: [event], isActive: false, at: splashNow)
    #expect(session.meetings.isEmpty)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.meetings == [event])
    try state.updatePreferences { $0.splashCueEnabled = false }
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty)
    try state.updatePreferences { $0.splashCueEnabled = true }
    try state.setSelectedCalendarIDs([])
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty)
}

@Test @MainActor func splashRejectsAmbiguousUnselectedAndInvalidMeetings() throws {
    let session = SplashCueSession(state: try splashState())
    let duplicate = splashMeeting()
    let other = splashMeeting("other", calendar: "personal")
    let ongoing = splashMeeting("ongoing", startsIn: -1)
    let invalid = MeetingOccurrence(id: "invalid", calendarID: "work", title: "Invalid", start: splashNow, end: splashNow)
    session.update(occurrences: [duplicate, duplicate, other, ongoing, invalid], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty)
    session.update(occurrences: [splashMeeting()], isActive: true, at: Date(timeIntervalSince1970: .nan))
    #expect(session.meetings.isEmpty)
}

@Test @MainActor func splashReconcilesEditsAndRemovalWithoutWritingOnEveryTick() throws {
    let store = SplashStorage()
    let session = SplashCueSession(state: try splashState(store))
    let event = splashMeeting()
    let writes = store.writes
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.update(occurrences: [event], isActive: true, at: splashNow.addingTimeInterval(1))
    #expect(session.meetings == [event])
    #expect(store.writes == writes)
    session.update(occurrences: [splashMeeting(startsIn: 300)], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.meetings == [event])
    session.update(occurrences: [], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty)
    #expect(store.writes == writes)
}

@Test @MainActor func unreadableSplashDismissalsDisableAutomaticPresentation() throws {
    let store = SplashStorage()
    store.records[AppStateRecord.dismissedSplashCues.storageKey] = Data(#"{"version":99,"value":[]}"#.utf8)
    let state = try splashState(store)
    let session = SplashCueSession(state: state)
    session.update(occurrences: [splashMeeting()], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty)
    #expect(session.errorMessage != nil)
    #expect(state.recoveryNotices.contains { $0.record == .dismissedSplashCues })
}

@Test func splashPreferencesDecodeOldAndMalformedSettingsAndExtendFetchHorizon() throws {
    let old = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"hudLeadMinutes":0}"#.utf8))
    #expect(old.splashCueEnabled)
    #expect(old.splashLeadMinutes == 1)
    #expect(old.calendarFetchHorizonMinutes == 1)
    var preferences = old
    preferences.splashLeadMinutes = 60
    #expect(preferences.calendarFetchHorizonMinutes == 60)
    preferences.splashCueEnabled = false
    #expect(preferences.calendarFetchHorizonMinutes == 0)
    let malformed = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"splashLeadMinutes":0,"splashCueEnabled":"yes","menuTitleLimit":40}"#.utf8))
    #expect(malformed.splashLeadMinutes == 1)
    #expect(malformed.splashCueEnabled)
    #expect(malformed.menuTitleLimit == 40)
}
