import Foundation
import Testing
@testable import MeetMeetCore

private struct FixedClock: AppClock {
    let now: Date
}

private let start = Date(timeIntervalSince1970: 1_000)
private let end = Date(timeIntervalSince1970: 1_600)

@Test("Meeting phase uses exact timestamps, not elapsed timer ticks", arguments: [
    (999.0, MeetingPhase.upcoming),
    (1_000.0, MeetingPhase.ongoing),
    (1_599.999, MeetingPhase.ongoing),
    (1_600.0, MeetingPhase.ended),
    (1_700.0, MeetingPhase.ended),
])
func phaseBoundaries(timestamp: Double, expected: MeetingPhase) {
    let clock = FixedClock(now: Date(timeIntervalSince1970: timestamp))
    let meeting = MeetingOccurrence(id: "occurrence", calendarID: "work", title: "Example", start: start, end: end)

    #expect(meeting.phase(at: clock.now) == expected)
}

private actor FixtureCalendar: CalendarReading {
    private(set) var requestedCalendarIDs: Set<String> = []

    func access() -> CalendarAccess { .fullAccess }
    func requestAccess() -> CalendarAccess { .fullAccess }
    func calendars() -> [CalendarDescriptor] {
        [CalendarDescriptor(id: "work", title: "Work", sourceTitle: "Fixture")]
    }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) -> [MeetingOccurrence] {
        requestedCalendarIDs = calendarIDs
        guard calendarIDs.contains("work") else { return [] }
        return [MeetingOccurrence(id: "occurrence", calendarID: "work", title: "Example", start: start, end: end)]
    }
}

@Test("A calendar adapter can be replaced without EventKit or user permission")
func calendarBoundary() async throws {
    let fixture = FixtureCalendar()
    let reader: any CalendarReading = fixture
    let events = try await reader.occurrences(in: DateInterval(start: start, end: end), calendarIDs: ["work"])

    #expect(events.count == 1)
    #expect(events.first?.calendarID == "work")
    #expect(await fixture.requestedCalendarIDs == ["work"])
    #expect(await reader.access() == .fullAccess)
}

@Test(arguments: [
    ("HQ-3-Boardroom", "Boardroom"),
    ("US-NYC-02-D-Boardroom (16) [Google Meet, TV]", "Boardroom"),
    ("HQ_Annex-B1-Laboratory (2)", "Laboratory"),
    ("(Microscope) HQ-3-Laboratory [VC]", "Laboratory"),
    ("HQ-LL-Lounge", "Lounge"),
    ("HQ-G-Lounge", "Lounge"),
    ("HQ-M-Lounge", "Lounge"),
    ("HQ-MZ-Lounge", "Lounge"),
    ("HQ-PH-Lounge", "Lounge"),
    ("HQ-Lobby-Lounge", "Lounge"),
    ("HQ-Mezzanine-Lounge", "Lounge"),
    ("HQ-Basement-Lounge", "Lounge"),
    ("HQ-Ground-Lounge", "Lounge"),
    ("HQ-3A-2-Boardroom", "Boardroom"),
    ("HQ-3-Board-Room-2 (8) [VC]", "Board-Room-2"),
    ("  HQ-02-会議室 (8) [Google Meet]  ", "会議室"),
])
func googleWorkspaceLocationsShortenToRoomNames(location: String, expected: String) {
    #expect(GoogleLocationShortener.shorten(location: location) == expected)
    #expect(MeetingText.displayLocation(location, shortenGoogleRoomNames: true) == expected)
    #expect(MeetingText.displayLocation(location, shortenGoogleRoomNames: false) == location)
}

@Test(arguments: [
    "", "  ", "  Meeting room  ", "Boardroom (16) [Google Meet, TV]",
    "(Microscope) Laboratory (2)", "HQ-second-Boardroom [VC]",
    "HQ-3- (16) [VC]", "HQ-3-", "https://meet.google.com/abc-defg-hij",
    "123 Main Street", "Room [VC]", "Building / Floor 3 / Boardroom",
])
func nonmatchingOrEmptyGoogleRoomNamesRemainUntouched(location: String) {
    #expect(GoogleLocationShortener.shorten(location: location) == location)
}
