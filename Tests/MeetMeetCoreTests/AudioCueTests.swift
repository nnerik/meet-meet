import Foundation
import Testing
@testable import MeetMeetCore

private let audioNow = Date(timeIntervalSince1970: 1_800_000_000)

#if !SWIFT_PACKAGE
import AppKit

@Test @MainActor func nativeSoundPickersOnlyOfferTheirOwnBundledDefaultWithFriendlyLabels() {
    let imported = "imported:\(UUID().uuidString)-custom.mp3"
    let selections = ["meet-meet", "wrap-wrap", imported, "Glass"]
    let start = SystemSoundPlayer.soundNames(isEnd: false, selectedNames: selections)
    let end = SystemSoundPlayer.soundNames(isEnd: true, selectedNames: selections)
    #expect(start.contains("meet-meet") && !start.contains("wrap-wrap"))
    #expect(end.contains("wrap-wrap") && !end.contains("meet-meet"))
    for names in [start, end] {
        #expect(names.contains("Glass") && names.contains(imported))
        #expect(names.count == Set(names).count)
    }
    #expect(CueMedia.label(for: "meet-meet") == "Meet Meet")
    #expect(CueMedia.label(for: "wrap-wrap") == "Wrap Wrap")
    #expect(CueMedia.label(for: "Glass") == "Glass")
    #expect(CueMedia.label(for: imported) == "custom.mp3")
}

@Test @MainActor func nativeBundledMP3CuesResolveAndDecodeWithoutPlayback() throws {
    let bundle = Bundle(for: SystemSoundPlayer.self)
    let player = SystemSoundPlayer(bundle: bundle)
    for name in SystemSoundPlayer.bundledSoundNames {
        let url = try #require(player.soundURL(named: name))
        #expect(url.pathExtension == "mp3")
        #expect(url.deletingLastPathComponent().path == bundle.resourceURL?.path)
        let sound = try #require(NSSound(contentsOf: url, byReference: false))
        #expect(sound.duration > 0)
        #expect(SystemSoundPlayer.soundNames.contains(name))
    }
    #expect(player.soundURL(named: "../meet-meet") == nil)
    #expect(player.soundURL(named: "Glass")?.path == "/System/Library/Sounds/Glass.aiff")
}

@Test @MainActor func nativeAudioOnlyAllowsSystemCatalogAndValidAppVolume() {
    let player = SystemSoundPlayer()
    #expect(!SystemSoundPlayer.soundNames.isEmpty)
    for name in ["../Glass", "/System/Library/Sounds/Glass.aiff", "../meet-meet", "unknown", ""] {
        #expect(throws: (any Error).self) { try player.play(named: name, volume: 1) }
    }
    for volume in [-1.0, 2.0, Double.nan, Double.infinity] {
        #expect(throws: (any Error).self) { try player.play(named: "Glass", volume: volume) }
    }
}

@Test @MainActor func nativeCueImportsCopyValidateAndRejectPathsOutsideManagedMedia() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = Bundle(for: SystemSoundPlayer.self)
    let audio = try #require(bundle.url(forResource: "meet-meet", withExtension: "mp3"))
    let imported = try CueMedia.importFile(audio, audio: true, directory: directory)
    let copy = try #require(CueMedia.url(for: imported, directory: directory))
    #expect(try Data(contentsOf: copy) == Data(contentsOf: audio))
    #expect(CueMedia.label(for: imported) == "meet-meet.mp3")
    let image = try #require(bundle.url(forResource: "wrap-wrap", withExtension: "png"))
    let importedImage = try CueMedia.importFile(image, audio: false, directory: directory)
    #expect(NSImage(contentsOf: try #require(CueMedia.url(for: importedImage, directory: directory))) != nil)
    #expect(throws: (any Error).self) { try CueMedia.importFile(image, audio: true, directory: directory) }
    #expect(throws: (any Error).self) { try CueMedia.importFile(audio, audio: false, directory: directory) }
    for name in ["imported:../Glass", "imported:/etc/passwd", "imported:\(UUID().uuidString)-../file", "imported:unknown", "/etc/passwd"] {
        #expect(CueMedia.url(for: name, directory: directory) == nil)
    }
}
#endif

@Test func audioBundledDefaultsPreservePreviouslySavedSystemChoices() throws {
    let defaults = AppPreferences()
    #expect(defaults.startCue.soundName == "meet-meet")
    #expect(defaults.endCue.soundName == "wrap-wrap")
    #expect(!defaults.startCue.isEnabled && !defaults.endCue.isEnabled)
    var saved = defaults
    saved.startCue = AudioCuePreference(isEnabled: true, soundName: "Glass", offsetMinutes: 3)
    saved.endCue = AudioCuePreference(soundName: "Ping", offsetMinutes: 4)
    let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(saved))
    #expect(restored == saved)
    let missingFields = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
    #expect(missingFields == defaults)
}

private func audioMeeting(_ id: String = "one", start: Double = 61, end: Double = 241,
                          allDay: Bool = false, cancelled: Bool = false, attendance: MeetingAttendance = .accepted) -> MeetingOccurrence {
    MeetingOccurrence(id: id, calendarID: "work", title: "Fixture", start: audioNow.addingTimeInterval(start),
                      end: audioNow.addingTimeInterval(end), isAllDay: allDay, isCancelled: cancelled, attendance: attendance)
}

private func audioPreferences() -> AppPreferences {
    var preferences = AppPreferences()
    preferences.startCue.isEnabled = true
    preferences.endCue.isEnabled = true
    return preferences
}

private func update(_ scheduler: inout AudioCueScheduler, events: [MeetingOccurrence] = [audioMeeting()],
                    preferences: AppPreferences = audioPreferences(), handled: [HandledCue] = [], seconds: Double) -> [ScheduledAudioCue] {
    scheduler.update(occurrences: events, selectedCalendarIDs: ["work"], preferences: preferences,
                     handled: handled, at: audioNow.addingTimeInterval(seconds))
}

@Test func audioArmsFutureAndFiresOnceOnBoundary() {
    var scheduler = AudioCueScheduler()
    #expect(update(&scheduler, seconds: 0).isEmpty)
    #expect(update(&scheduler, seconds: 1).map(\.kind) == [.start])
    #expect(update(&scheduler, seconds: 2).isEmpty)
}

@Test func audioDefaultsAreSilentAndEndCueCanFireIndependently() {
    var scheduler = AudioCueScheduler()
    _ = update(&scheduler, preferences: AppPreferences(), seconds: 0)
    #expect(update(&scheduler, preferences: AppPreferences(), seconds: 1).isEmpty)
    var preferences = audioPreferences()
    preferences.startCue.isEnabled = false
    let events = [audioMeeting(start: -100, end: 121)]
    scheduler.reset()
    _ = update(&scheduler, events: events, preferences: preferences, seconds: 0)
    #expect(update(&scheduler, events: events, preferences: preferences, seconds: 1).map(\.kind) == [.end])
}

@Test func audioNeverCatchesUpOnStartupOrDiscontinuities() {
    for interruption in [0, 1, 2] {
        var scheduler = AudioCueScheduler()
        _ = update(&scheduler, seconds: 0)
        if interruption == 0 { scheduler.reset() }
        if interruption == 1 { _ = update(&scheduler, seconds: -1) }
        let next = interruption == 2 ? 10.0 : 1.0
        // A backward jump rearms future cues; it does not immediately catch up.
        if interruption == 1 {
            #expect(update(&scheduler, seconds: 10).isEmpty)
        } else {
            #expect(update(&scheduler, seconds: next).isEmpty)
        }
    }
    var late = AudioCueScheduler()
    #expect(update(&late, seconds: 1).isEmpty)
}

@Test func audioReschedulesOnlyUnchangedFutureCues() {
    var scheduler = AudioCueScheduler()
    _ = update(&scheduler, seconds: 0)
    #expect(update(&scheduler, events: [audioMeeting(start: 60)], seconds: 1).isEmpty)
    #expect(update(&scheduler, events: [audioMeeting(start: 64)], seconds: 2).isEmpty)
    #expect(update(&scheduler, events: [audioMeeting(start: 64)], seconds: 4).map(\.kind) == [.start])
    let receipt = HandledCue(occurrence: audioMeeting().key, kind: .start, handledAt: audioNow)
    _ = update(&scheduler, events: [audioMeeting(start: 66)], handled: [receipt], seconds: 5)
    #expect(update(&scheduler, events: [audioMeeting(start: 66)], handled: [receipt], seconds: 6).isEmpty)
}

@Test func audioZeroOffsetsIncludeTheExactEndBoundary() {
    var preferences = audioPreferences()
    preferences.startCue.offsetMinutes = 0
    preferences.endCue.offsetMinutes = 0
    var scheduler = AudioCueScheduler()
    let events = [audioMeeting(start: 1, end: 2)]
    _ = update(&scheduler, events: events, preferences: preferences, seconds: 0)
    #expect(update(&scheduler, events: events, preferences: preferences, seconds: 1).map(\.kind) == [.start])
    #expect(update(&scheduler, events: events, preferences: preferences, seconds: 2).map(\.kind) == [.end])
}

@Test func audioSkipsShortMeetingEndWarningAndInvalidMeetings() {
    let invalid = [audioMeeting("all-day", allDay: true), audioMeeting("cancelled", cancelled: true),
                   audioMeeting("declined", attendance: .declined), audioMeeting("invalid", end: 0)]
    var scheduler = AudioCueScheduler()
    _ = update(&scheduler, events: invalid, seconds: 0)
    #expect(update(&scheduler, events: invalid, seconds: 1).isEmpty)
    let short = [audioMeeting(start: 62, end: 121)] // end warning at 1, before start
    scheduler.reset()
    _ = update(&scheduler, events: short, seconds: 0)
    #expect(update(&scheduler, events: short, seconds: 1).isEmpty)
    #expect(update(&scheduler, events: short, seconds: 2).map(\.kind) == [.start])
}

@Test func audioRemovedHiddenAndAmbiguousOccurrencesCannotFire() {
    var scheduler = AudioCueScheduler()
    _ = update(&scheduler, seconds: 0)
    #expect(update(&scheduler, events: [], seconds: 1).isEmpty)
    scheduler.reset()
    _ = update(&scheduler, seconds: 0)
    #expect(update(&scheduler, events: [audioMeeting(), audioMeeting()], seconds: 1).isEmpty)
    var preferences = audioPreferences()
    preferences.startCue.isEnabled = false
    scheduler.reset()
    _ = update(&scheduler, seconds: 0)
    #expect(update(&scheduler, preferences: preferences, seconds: 1).isEmpty)
}

@MainActor private final class AudioMemoryStore: LocalStateStoring {
    var records: [String: Data] = [:]
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data }
}

@MainActor private final class AudioPlayerSpy: SystemSoundPlaying {
    var calls: [String] = []
    var volumes: [Double] = []
    var fail = false
    var beforePlay: (() -> Void)?
    func play(named name: String, volume: Double) throws {
        beforePlay?()
        calls.append(name)
        volumes.append(volume)
        if fail { throw CocoaError(.fileReadUnknown) }
    }
}

@MainActor private func audioState(_ storage: AudioMemoryStore) throws -> AppState {
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["work"])
    try state.updatePreferences { $0 = audioPreferences() }
    return state
}

@Test @MainActor func audioPersistsAllCoincidentCuesBeforeStartWinsPlayback() throws {
    let storage = AudioMemoryStore()
    let state = try audioState(storage)
    let player = AudioPlayerSpy()
    let events = [audioMeeting(), audioMeeting("ending", start: -100, end: 121)]
    player.beforePlay = { #expect(AppState(storage: storage).handledCues.count == 2) }
    var visibleCues: [ScheduledAudioCue] = []
    let session = AudioCueSession(state: state, player: player) { cues in
        #expect(AppState(storage: storage).handledCues.count == 2)
        #expect(player.calls.isEmpty)
        visibleCues += cues
    }
    session.update(occurrences: events, isActive: true, at: audioNow)
    session.update(occurrences: events, isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(player.calls == ["meet-meet"])
    #expect(Set(visibleCues.map(\.occurrence)) == Set(events.map(\.key)))
    let restarted = AudioCueSession(state: AppState(storage: storage), player: player)
    restarted.update(occurrences: events, isActive: true, at: audioNow)
    restarted.update(occurrences: events, isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(player.calls.count == 1)
}

@Test @MainActor func audioVisualCuesDoNotRepeatOnPreviewPauseOrHandledReplay() throws {
    let state = try audioState(AudioMemoryStore())
    let player = AudioPlayerSpy()
    var cueCount = 0
    let session = AudioCueSession(state: state, player: player) { cueCount += $0.count }
    session.preview(named: "meet-meet")
    #expect(cueCount == 0)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow)
    player.fail = true
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(cueCount == 1) // A playback failure does not discard the visual cue.
    session.update(occurrences: [audioMeeting()], isActive: false, at: audioNow)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(cueCount == 1)
}

@Test @MainActor func audioFailureDoesNotReplayAndPreviewDoesNotHandleCues() throws {
    let storage = AudioMemoryStore()
    let state = try audioState(storage)
    try state.updatePreferences { $0.audioVolume = 0.25 }
    let player = AudioPlayerSpy()
    player.fail = true
    let session = AudioCueSession(state: state, player: player)
    session.preview(named: "Ping")
    #expect(state.handledCues.isEmpty)
    #expect(session.errorMessage != nil)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(state.handledCues.count == 1)
    #expect(session.errorMessage != nil)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(player.calls == ["Ping", "meet-meet"])
    #expect(player.volumes == [0.25, 0.25])
}

@Test @MainActor func audioPauseAndUnsafeHistoryFailClosed() throws {
    let storage = AudioMemoryStore()
    let state = try audioState(storage)
    let player = AudioPlayerSpy()
    let session = AudioCueSession(state: state, player: player)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow)
    session.update(occurrences: [], isActive: false, at: audioNow)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(player.calls.isEmpty)
    for data in [Data("broken".utf8), Data("{\"version\":99,\"value\":[]}".utf8)] {
        storage.records[AppStateRecord.handledCues.storageKey] = data
        let unsafe = AudioCueSession(state: AppState(storage: storage), player: player)
        unsafe.update(occurrences: [audioMeeting()], isActive: true, at: audioNow)
        unsafe.update(occurrences: [audioMeeting()], isActive: true, at: audioNow.addingTimeInterval(1))
        #expect(player.calls.isEmpty)
        #expect(unsafe.errorMessage != nil)
        #expect(storage.records[AppStateRecord.handledCues.storageKey] == data)
    }
}

@Test @MainActor func audioSettingsChangesNeverReplayPassedCues() throws {
    let state = try audioState(AudioMemoryStore())
    let player = AudioPlayerSpy()
    let session = AudioCueSession(state: state, player: player)
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow)
    try state.updatePreferences { $0.audioVolume = 0.5 }
    session.update(occurrences: [audioMeeting()], isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(player.calls.isEmpty)
    #expect(state.handledCues.isEmpty)
}

@Test @MainActor func audioTemporaryHUDSuppressionDoesNotAffectSound() throws {
    let state = try audioState(AudioMemoryStore())
    let meeting = audioMeeting()
    try state.setCountdownSuppressions([CountdownSuppression(occurrence: meeting.key, phase: .upcoming, boundary: meeting.start)])
    let player = AudioPlayerSpy()
    let session = AudioCueSession(state: state, player: player)
    session.update(occurrences: [meeting], isActive: true, at: audioNow)
    session.update(occurrences: [meeting], isActive: true, at: audioNow.addingTimeInterval(1))
    #expect(player.calls == ["meet-meet"])
}

@Test func audioNewlyDiscoveredPastCuesAndUnselectedCalendarsStaySilent() {
    var scheduler = AudioCueScheduler()
    _ = update(&scheduler, events: [], seconds: 0)
    #expect(update(&scheduler, seconds: 1).isEmpty)
    scheduler.reset()
    _ = scheduler.update(occurrences: [audioMeeting()], selectedCalendarIDs: [], preferences: audioPreferences(), handled: [], at: audioNow)
    #expect(scheduler.update(occurrences: [audioMeeting()], selectedCalendarIDs: [], preferences: audioPreferences(), handled: [], at: audioNow.addingTimeInterval(1)).isEmpty)
}
