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
    #expect(old.endSplashCueEnabled)
    #expect(old.endSplashLeadMinutes == 2)
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

@Test(arguments: [AppStateRecord.dismissedSplashCues, .dismissedEndSplashCues],
      [Data("invalid".utf8), Data(#"{"version":99,"value":[]}"#.utf8)])
@MainActor func unreadableCueHistoryAllowsManualInfoWithoutWriting(record: AppStateRecord, data: Data) throws {
    let store = SplashStorage()
    store.records[record.storageKey] = data
    let state = try splashState(store)
    let session = SplashCueSession(state: state)
    let upcoming = splashMeeting()
    let ongoing = splashMeeting("ongoing", startsIn: -500)
    let writes = store.writes
    session.update(occurrences: [upcoming, ongoing], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty && session.endMeetings.isEmpty && session.infoMeetings.isEmpty)
    for event in [upcoming, ongoing] { session.showMeetingInfo(for: event.key) }
    #expect(Set(session.infoMeetings.map(\.key)) == [upcoming.key, ongoing.key])
    session.suspend()
    #expect(session.infoMeetings.isEmpty)
    session.update(occurrences: [upcoming, ongoing], isActive: true, at: splashNow)
    #expect(session.infoMeetings.count == 2)
    session.dismiss()
    #expect(session.infoMeetings.isEmpty)
    #expect(session.errorMessage != nil)
    #expect(store.writes == writes)
    #expect(store.records[record.storageKey] == data)
    session.update(occurrences: [upcoming, ongoing], isActive: true, at: splashNow)
    #expect(session.meetings.isEmpty && session.endMeetings.isEmpty && session.infoMeetings.isEmpty)
    session.showMeetingInfo(for: ongoing.key)
    #expect(session.infoMeetings == [ongoing])
    session.update(occurrences: [upcoming, ongoing], isActive: false, at: splashNow)
    session.showMeetingInfo(for: ongoing.key)
    #expect(session.infoMeetings.isEmpty)
    #expect(store.writes == writes)
}

@Test(arguments: [AppStateRecord.hiddenEvents, .pause, .selectedCalendars, .preferences])
@MainActor func unreadableEligibilityRecordsStillBlockManualInfo(record: AppStateRecord) throws {
    let store = SplashStorage()
    _ = try splashState(store)
    store.records[record.storageKey] = Data(#"{"version":99,"value":[]}"#.utf8)
    let state = AppState(storage: store)
    let session = SplashCueSession(state: state)
    let event = splashMeeting()
    let writes = store.writes
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings.isEmpty && session.meetings.isEmpty && session.endMeetings.isEmpty)
    #expect(session.errorMessage != nil)
    #expect(store.writes == writes)
}

@Test @MainActor func endSplashCatchesUpOnlyDuringOngoingPhaseAndHidesAtEnd() throws {
    let state = try splashState()
    let session = SplashCueSession(state: state)
    let event = splashMeeting(startsIn: -480) // Ends in two minutes.
    session.update(occurrences: [event], isActive: true, at: splashNow.addingTimeInterval(-0.001))
    #expect(session.endMeetings.isEmpty)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.endMeetings == [event])
    #expect(session.meetings.isEmpty)
    session.reset()
    session.update(occurrences: [event], isActive: true, at: splashNow.addingTimeInterval(90))
    #expect(session.endMeetings == [event])
    session.update(occurrences: [event], isActive: true, at: event.end)
    #expect(session.endMeetings.isEmpty)

    let short = MeetingOccurrence(id: "short", calendarID: "work", title: "Short",
                                  start: splashNow.addingTimeInterval(30), end: splashNow.addingTimeInterval(60))
    session.update(occurrences: [short], isActive: true, at: splashNow)
    #expect(session.endMeetings.isEmpty)
    session.update(occurrences: [short], isActive: true, at: short.start)
    #expect(session.endMeetings == [short])
    try state.updatePreferences { $0.endSplashCueEnabled = false }
    session.update(occurrences: [short], isActive: true, at: short.start)
    #expect(session.endMeetings.isEmpty)
}

@Test @MainActor func startDismissalDoesNotSuppressEndAndBothPersistIndependently() throws {
    let store = SplashStorage()
    let state = try splashState(store)
    let event = splashMeeting()
    let session = SplashCueSession(state: state)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.dismiss()
    let restored = SplashCueSession(state: AppState(storage: store))
    restored.update(occurrences: [event], isActive: true, at: event.end.addingTimeInterval(-120))
    #expect(restored.endMeetings == [event])
    restored.dismiss()
    let again = SplashCueSession(state: AppState(storage: store))
    again.update(occurrences: [event], isActive: true, at: event.end.addingTimeInterval(-60))
    #expect(again.endMeetings.isEmpty)
    #expect(AppState(storage: store).dismissedEndSplashCues == [event.key])
}

@Test @MainActor func overlappingStartAndEndVisualsDismissTogetherAndRespectSafetyFilters() throws {
    let store = SplashStorage()
    let state = try splashState(store)
    let session = SplashCueSession(state: state)
    let upcoming = splashMeeting("upcoming")
    let ongoing = splashMeeting("ongoing", startsIn: -500)
    session.update(occurrences: [upcoming, ongoing], isActive: true, at: splashNow)
    #expect(session.meetings == [upcoming])
    #expect(session.endMeetings == [ongoing])
    session.update(occurrences: [upcoming, ongoing], isActive: false, at: splashNow)
    #expect(session.meetings.isEmpty && session.endMeetings.isEmpty)
    session.update(occurrences: [ongoing, ongoing], isActive: true, at: splashNow)
    #expect(session.endMeetings.isEmpty)
    session.update(occurrences: [upcoming, ongoing], isActive: true, at: splashNow)
    session.dismiss()
    #expect(state.dismissedSplashCues == [upcoming.key])
    #expect(state.dismissedEndSplashCues == [ongoing.key])
    store.records[AppStateRecord.dismissedEndSplashCues.storageKey] = Data("invalid".utf8)
    let unsafe = SplashCueSession(state: AppState(storage: store))
    unsafe.update(occurrences: [splashMeeting("next"), ongoing], isActive: true, at: splashNow)
    #expect(unsafe.meetings.isEmpty && unsafe.endMeetings.isEmpty)
    #expect(unsafe.errorMessage != nil)
}

@Test func meetingLinksResolveExplicitURLsLocationsAndConferenceNotesSafely() {
    let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
    #expect(MeetingLink.resolve(url: meet, location: "Room 2") == meet)
    #expect(MeetingLink.resolve(url: nil, location: "Join: \(meet.absoluteString)") == meet)
    #expect(MeetingLink.resolve(url: nil, location: "Room 2", notes: "Agenda https://example.com then join \(meet.absoluteString)") == meet)
    #expect(MeetingLink.resolve(url: URL(string: "https://calendar.google.com/event"), location: "Room 2", notes: meet.absoluteString) == meet)
    #expect(MeetingLink.resolve(url: nil, location: nil, notes: "https://meet.google.com.evil.test/join") == nil)
    #expect(MeetingLink.resolve(url: URL(string: "file:///etc/passwd"), location: nil) == nil)
    #expect(MeetingLink.resolve(url: URL(string: "javascript:alert(1)"), location: nil) == nil)
    #expect(MeetingLink.resolve(url: URL(string: "zoommtg://zoom.us/join?confno=123"), location: nil) != nil)
}

@Test @MainActor func automaticallyPresentedMeetingInfoStaysThroughStartUntilEnd() throws {
    let state = try splashState()
    try state.updatePreferences { $0.endSplashCueEnabled = false }
    let session = SplashCueSession(state: state)
    let event = splashMeeting()
    session.update(occurrences: [event], isActive: true, at: splashNow)
    #expect(session.infoMeetings == [event])
    let revision = session.presentationRevision
    session.update(occurrences: [event], isActive: true, at: event.start)
    #expect(session.meetings.isEmpty)
    #expect(session.infoMeetings == [event])
    #expect(session.presentationRevision == revision)
    session.update(occurrences: [event], isActive: true, at: event.end)
    #expect(session.infoMeetings.isEmpty)

    let lateLaunch = SplashCueSession(state: state)
    lateLaunch.update(occurrences: [event], isActive: true, at: event.start)
    #expect(lateLaunch.infoMeetings.isEmpty) // No new start cue for an ongoing meeting.
}

@Test @MainActor func manuallyOpeningAndClosingInfoDoesNotConsumeFutureVisualOrAudioCues() throws {
    let store = SplashStorage()
    let state = try splashState(store)
    let session = SplashCueSession(state: state)
    let event = splashMeeting(startsIn: 300)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    let writes = store.writes
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings == [event])
    #expect(session.meetings.isEmpty)
    session.dismiss()
    #expect(session.infoMeetings.isEmpty)
    #expect(state.dismissedSplashCues.isEmpty && state.dismissedEndSplashCues.isEmpty && state.handledCues.isEmpty)
    #expect(store.writes == writes)
    session.update(occurrences: [event], isActive: true, at: event.start.addingTimeInterval(-60))
    #expect(session.meetings == [event])
    #expect(session.infoMeetings == [event])
    session.dismiss()
    #expect(state.dismissedSplashCues == [event.key])
}

@Test @MainActor func automaticCueRaisesInfoEvenWhenManuallyOpenedAndStillVisible() throws {
    let session = SplashCueSession(state: try splashState())
    let event = splashMeeting(startsIn: 300)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.showMeetingInfo(for: event.key)
    let manualRevision = session.presentationRevision
    session.update(occurrences: [event], isActive: true, at: event.start.addingTimeInterval(-60))
    #expect(session.infoMeetings == [event])
    #expect(session.presentationRevision > manualRevision)
    let cueRevision = session.presentationRevision
    session.update(occurrences: [event], isActive: true, at: event.start.addingTimeInterval(-59))
    #expect(session.presentationRevision == cueRevision)
}

@Test @MainActor func manuallyOpenedOngoingInfoWorksWithDisabledOrDismissedCues() throws {
    let state = try splashState()
    try state.updatePreferences { $0.splashCueEnabled = false; $0.endSplashCueEnabled = false }
    let session = SplashCueSession(state: state)
    let event = splashMeeting(startsIn: -60)
    try state.setDismissedSplashCues([event.key])
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings == [event])
    #expect(session.meetings.isEmpty && session.endMeetings.isEmpty)
    session.dismiss()
    #expect(state.dismissedSplashCues == [event.key])
    #expect(state.dismissedEndSplashCues.isEmpty)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings.isEmpty) // Reset discards the stale available snapshot.
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings == [event])
}

@Test @MainActor func refreshRestoresOpenMeetingInfoAcrossStartUsingFreshSnapshots() throws {
    let session = SplashCueSession(state: try splashState())
    let event = splashMeeting()
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.suspend()
    #expect(session.infoMeetings.isEmpty)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings.isEmpty)
    let edited = MeetingOccurrence(id: event.id, calendarID: event.calendarID, title: "Edited",
                                   start: event.start, end: event.end, location: "New room")
    session.update(occurrences: [edited], isActive: true, at: event.start)
    #expect(session.infoMeetings == [edited])
    session.update(occurrences: [], isActive: true, at: event.start)
    #expect(session.infoMeetings.isEmpty)
    session.update(occurrences: [edited], isActive: true, at: event.start)
    #expect(session.infoMeetings.isEmpty) // A removed meeting is not silently reopened.
}

@Test @MainActor func infoDismissalAfterStartPersistsOnlyTheAlreadyPresentedStartCue() throws {
    let state = try splashState()
    let session = SplashCueSession(state: state)
    let event = splashMeeting()
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.update(occurrences: [event], isActive: true, at: event.start)
    session.dismiss()
    #expect(state.dismissedSplashCues == [event.key])
    #expect(state.dismissedEndSplashCues.isEmpty)
    session.update(occurrences: [event], isActive: true, at: event.end.addingTimeInterval(-120))
    #expect(session.endMeetings == [event])
}

@Test @MainActor func meetingInfoRejectsInactiveAmbiguousHiddenAndEndedSnapshots() throws {
    let state = try splashState()
    let session = SplashCueSession(state: state)
    let event = splashMeeting(startsIn: -60)
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings == [event])
    session.update(occurrences: [event], isActive: false, at: splashNow)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings.isEmpty)
    session.update(occurrences: [event, event], isActive: true, at: splashNow)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings.isEmpty)
    try state.setSelectedCalendarIDs([])
    session.update(occurrences: [event], isActive: true, at: splashNow)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings.isEmpty)
    try state.setSelectedCalendarIDs([event.calendarID])
    session.update(occurrences: [event], isActive: true, at: event.end)
    session.showMeetingInfo(for: event.key)
    #expect(session.infoMeetings.isEmpty)
}
