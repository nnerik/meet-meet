import Foundation
import Testing
@testable import MeetMeetCore

@MainActor
private final class MemoryStateStore: LocalStateStoring {
    var records: [String: Data] = [:]
    var writeCount = 0
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data; writeCount += 1 }
}

@Test @MainActor
func freshStateHasApprovedDefaultsWithoutWriting() {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    #expect(state.preferences.hudLeadMinutes == 30)
    #expect(state.preferences.secondsThresholdMinutes == 5)
    #expect(state.preferences.menuTitleLimit == 24)
    #expect(!state.preferences.shortenGoogleRoomNames)
    #expect(!state.preferences.startCue.isEnabled)
    #expect(!state.preferences.endCue.isEnabled)
    #expect(state.preferences.startCue.offsetMinutes == 1)
    #expect(state.preferences.endCue.offsetMinutes == 2)
    #expect(state.preferences.audioVolume == 1)
    #expect(state.preferences.splashCueEnabled)
    #expect(state.preferences.splashLeadMinutes == 1)
    #expect(state.selectedCalendarIDs.isEmpty)
    #expect(!state.onboardingCompleted)
    #expect(state.pauseUntil == nil)
    #expect(state.hudPosition == nil)
    #expect(state.hiddenEvents.isEmpty)
    #expect(state.countdownSuppressions.isEmpty)
    #expect(state.handledCues.isEmpty)
    #expect(state.dismissedSplashCues.isEmpty)
    #expect(state.recoveryNotices.isEmpty)
    #expect(storage.writeCount == 0)
}

@Test @MainActor
func committingUnchangedPreferencesDoesNotWrite() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    try state.updatePreferences { $0.hudLeadMinutes = 30 }
    #expect(storage.writeCount == 0)
    try state.updatePreferences { $0.hudLeadMinutes = 45 }
    try state.updatePreferences { $0.hudLeadMinutes = 45 }
    #expect(storage.writeCount == 1)
}

@Test @MainActor
func allRecordsSurviveReconstruction() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    let boundary = Date(timeIntervalSince1970: 10_000)
    let occurrence = OccurrenceKey(calendarID: "work", occurrenceID: "instance")
    let position = HUDPosition(rightOffset: 120, bottomOffset: 80, displayID: "external")
    let rules = [HiddenEventRule(scope: .series, calendarID: "work", sourceID: "account", localItemID: "local",
                                externalItemID: "external", title: "Lunch", calendarTitle: "Work")]
    let suppressions = [CountdownSuppression(occurrence: occurrence, phase: .upcoming, boundary: boundary)]
    let cues = [HandledCue(occurrence: occurrence, kind: .start, handledAt: boundary)]
    try state.updatePreferences {
        $0.hudLeadMinutes = 120
        $0.secondsThresholdMinutes = 0
        $0.menuTitleLimit = 80
        $0.shortenGoogleRoomNames = true
        $0.startCue.isEnabled = true
        $0.startCue.soundName = "Basso"
        $0.startCue.offsetMinutes = 0
        $0.endCue.offsetMinutes = 60
        $0.audioVolume = 0.4
        $0.splashCueEnabled = false
        $0.splashLeadMinutes = 10
        $0.endSplashCueEnabled = false
        $0.endSplashLeadMinutes = 5
        $0.startSplashImage = "imported-start.png"
        $0.endSplashImage = "imported-end.png"
    }
    try state.setSelectedCalendarIDs(["work", "personal"])
    try state.setOnboardingCompleted(true)
    try state.setPauseUntil(boundary)
    try state.setHUDPosition(position)
    try state.setHiddenEvents(rules)
    try state.setCountdownSuppressions(suppressions)
    try state.setHandledCues(cues)
    try state.setDismissedSplashCues([occurrence])
    try state.setDismissedEndSplashCues([occurrence])

    let restored = AppState(storage: storage)
    #expect(restored.preferences == state.preferences)
    #expect(restored.selectedCalendarIDs == ["work", "personal"])
    #expect(restored.onboardingCompleted)
    #expect(restored.pauseUntil == boundary)
    #expect(restored.hudPosition == position)
    #expect(restored.hiddenEvents == rules)
    #expect(restored.countdownSuppressions == suppressions)
    #expect(restored.handledCues == cues)
    #expect(restored.dismissedSplashCues == [occurrence])
    #expect(restored.dismissedEndSplashCues == [occurrence])
    #expect(restored.recoveryNotices.isEmpty)
    #expect(storage.records.count == AppStateRecord.allCases.count)
}

@Test func roomShorteningDefaultsOffForOldOrMalformedPreferences() throws {
    for json in [#"{}"#, #"{"shortenGoogleRoomNames":"yes","menuTitleLimit":40}"#] {
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        #expect(!preferences.shortenGoogleRoomNames)
    }
    let saved = try JSONDecoder().decode(AppPreferences.self, from: Data(#"{"shortenGoogleRoomNames":true,"menuTitleLimit":40}"#.utf8))
    #expect(saved.shortenGoogleRoomNames)
    #expect(saved.menuTitleLimit == 40)
}

@Test @MainActor
func invalidPreferenceEditsDoNotMutateStateOrStorage() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    try state.updatePreferences { $0.menuTitleLimit = 40 }
    let prior = storage.records
    let edits: [(inout AppPreferences) -> Void] = [
        { $0.hudLeadMinutes = -1 }, { $0.hudLeadMinutes = 121 },
        { $0.secondsThresholdMinutes = -1 }, { $0.secondsThresholdMinutes = 61 },
        { $0.menuTitleLimit = 7 }, { $0.menuTitleLimit = 81 },
        { $0.splashLeadMinutes = 0 }, { $0.splashLeadMinutes = 61 },
        { $0.endSplashLeadMinutes = 0 }, { $0.endSplashLeadMinutes = 61 },
        { $0.startCue.offsetMinutes = -1 }, { $0.startCue.offsetMinutes = 61 },
        { $0.endCue.offsetMinutes = -1 }, { $0.endCue.offsetMinutes = 61 },
        { $0.audioVolume = -0.1 }, { $0.audioVolume = 1.1 },
        { $0.audioVolume = .nan }, { $0.audioVolume = .infinity },
        { $0.startCue.soundName = "  " }, { $0.endCue.soundName = "" },
    ]
    for edit in edits {
        #expect(throws: PreferenceError.self) { try state.updatePreferences(edit) }
        #expect(storage.records == prior)
        #expect(state.preferences.menuTitleLimit == 40)
    }
}

@Test @MainActor
func inclusivePreferenceBoundsAreAccepted() throws {
    let state = AppState(storage: MemoryStateStore())
    try state.updatePreferences {
        $0.hudLeadMinutes = 0; $0.secondsThresholdMinutes = 0; $0.menuTitleLimit = 8
        $0.startCue.offsetMinutes = 0; $0.endCue.offsetMinutes = 0; $0.audioVolume = 0
    }
    try state.updatePreferences {
        $0.hudLeadMinutes = 120; $0.secondsThresholdMinutes = 60; $0.menuTitleLimit = 80
        $0.startCue.offsetMinutes = 60; $0.endCue.offsetMinutes = 60; $0.audioVolume = 1
    }
}

@Test @MainActor
func corruptedRecordDoesNotLoseSiblingRecords() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["work"])
    try state.setOnboardingCompleted(true)
    let calendarsBefore = storage.records[AppStateRecord.selectedCalendars.storageKey]
    storage.records[AppStateRecord.preferences.storageKey] = Data("broken JSON".utf8)

    let recovered = AppState(storage: storage)
    #expect(recovered.preferences == AppPreferences())
    #expect(recovered.selectedCalendarIDs == ["work"])
    #expect(recovered.onboardingCompleted)
    #expect(recovered.recoveryNotices == [StateRecoveryNotice(record: .preferences, reason: .unreadable)])
    try recovered.updatePreferences { $0.hudLeadMinutes = 10 }
    #expect(recovered.recoveryNotices.isEmpty)
    #expect(storage.records[AppStateRecord.selectedCalendars.storageKey] == calendarsBefore)
}

@Test @MainActor
func malformedPreferenceFieldsKeepValidSiblings() {
    let storage = MemoryStateStore()
    storage.records[AppStateRecord.preferences.storageKey] = Data(#"{"version":1,"value":{"hudLeadMinutes":999,"secondsThresholdMinutes":0,"menuTitleLimit":40,"audioVolume":"bad","startCue":{"isEnabled":true,"offsetMinutes":99,"soundName":"Basso"},"endCue":{"offsetMinutes":0}}}"#.utf8)
    let state = AppState(storage: storage)
    #expect(state.preferences.hudLeadMinutes == 30)
    #expect(state.preferences.secondsThresholdMinutes == 0)
    #expect(state.preferences.menuTitleLimit == 40)
    #expect(state.preferences.audioVolume == 1)
    #expect(state.preferences.startCue.isEnabled)
    #expect(state.preferences.startCue.offsetMinutes == 1)
    #expect(state.preferences.startCue.soundName == "Basso")
    #expect(state.preferences.endCue.offsetMinutes == 0)
    #expect(!state.preferences.endCue.isEnabled)
    #expect(storage.writeCount == 0)
}

@Test @MainActor
func newLeadTimeDefaultDoesNotOverwriteAnExistingChoice() {
    let storage = MemoryStateStore()
    storage.records[AppStateRecord.preferences.storageKey] = Data(#"{"version":1,"value":{"hudLeadMinutes":5}}"#.utf8)
    let state = AppState(storage: storage)
    #expect(state.preferences.hudLeadMinutes == 5)
    #expect(storage.writeCount == 0)
}

@Test @MainActor
func unknownSchemaIsPreservedAndBlocksOnlyItsOwnRecord() throws {
    let storage = MemoryStateStore()
    let newer = Data(#"{"version":99,"value":{"newData":"preserve me"}}"#.utf8)
    storage.records[AppStateRecord.preferences.storageKey] = newer
    let state = AppState(storage: storage)
    #expect(state.recoveryNotices == [StateRecoveryNotice(record: .preferences, reason: .unsupportedVersion(99))])
    #expect(throws: AppStateError.newerRecord(.preferences)) { try state.updatePreferences { $0.hudLeadMinutes = 10 } }
    try state.setSelectedCalendarIDs(["work"])
    #expect(state.selectedCalendarIDs == ["work"])
    #expect(storage.records[AppStateRecord.preferences.storageKey] == newer)
}

@Test @MainActor
func calendarDiscoveryDoesNotChangeSelection() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["work"])
    let work = CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Account")
    let newCalendar = CalendarDescriptor(id: "new", title: "New", sourceTitle: "Account")
    #expect(state.selectedCalendars(in: [work, newCalendar]) == [work])
    #expect(state.selectedCalendars(in: []).isEmpty)
    #expect(state.selectedCalendarIDs == ["work"])
    #expect(AppState(storage: storage).selectedCalendars(in: [newCalendar, work]) == [work])
    try state.setSelectedCalendarIDs([])
    #expect(AppState(storage: storage).selectedCalendarIDs.isEmpty)
}

@Test @MainActor
func optionalRecordsCanBeCleared() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    try state.setPauseUntil(Date(timeIntervalSince1970: 42))
    try state.setHUDPosition(HUDPosition(rightOffset: 100, bottomOffset: 200))
    try state.setPauseUntil(nil)
    try state.setHUDPosition(nil)
    #expect(state.pauseUntil == nil)
    #expect(state.hudPosition == nil)
    let restored = AppState(storage: storage)
    #expect(restored.pauseUntil == nil)
    #expect(restored.hudPosition == nil)
    #expect(restored.recoveryNotices.isEmpty)
    #expect(throws: AppStateError.invalidPosition) { try state.setHUDPosition(HUDPosition(rightOffset: .infinity, bottomOffset: 200)) }
}

@Test @MainActor
func calendarDeselectionDoesNotDeleteReminderState() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    let rule = HiddenEventRule(scope: .series, calendarID: "work", localItemID: "lunch", title: "Lunch", calendarTitle: "Work")
    let occurrence = OccurrenceKey(calendarID: "work", occurrenceID: "instance")
    let cue = HandledCue(occurrence: occurrence, kind: .start, handledAt: Date(timeIntervalSince1970: 100))
    try state.setHiddenEvents([rule])
    try state.setHandledCues([cue])
    try state.setSelectedCalendarIDs(["work"])
    try state.setSelectedCalendarIDs([])
    try state.setSelectedCalendarIDs(["work"])

    let restored = AppState(storage: storage)
    #expect(restored.hiddenEvents == [rule])
    #expect(restored.handledCues == [cue])
}

@Test @MainActor
func encodingFailureDoesNotReplaceExistingState() throws {
    let storage = MemoryStateStore()
    let state = AppState(storage: storage)
    let valid = Date(timeIntervalSince1970: 100)
    try state.setPauseUntil(valid)
    let previous = storage.records
    #expect(throws: EncodingError.self) { try state.setPauseUntil(Date(timeIntervalSince1970: .infinity)) }
    #expect(state.pauseUntil == valid)
    #expect(storage.records == previous)
}

@Test @MainActor
func userDefaultsAdapterRoundTripsInAnIsolatedSuite() throws {
    let suite = "dev.nnerik.meetmeet.tests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let state = AppState(storage: UserDefaultsStateStore(defaults: defaults))
    try state.updatePreferences { $0.hudLeadMinutes = 12 }
    try state.setSelectedCalendarIDs(["work"])
    let restored = AppState(storage: UserDefaultsStateStore(defaults: defaults))
    #expect(restored.preferences.hudLeadMinutes == 12)
    #expect(restored.selectedCalendarIDs == ["work"])
}
