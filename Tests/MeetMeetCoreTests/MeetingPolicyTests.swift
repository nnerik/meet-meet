import Foundation
import Testing
@testable import MeetMeetCore

private func instant(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private var noon: Date { instant("2026-10-25T12:00:00Z") }

private func meeting(_ id: String, start: TimeInterval = 60, duration: TimeInterval = 600,
                     calendarID: String = "work", title: String = "Meeting",
                     isAllDay: Bool = false, isCancelled: Bool = false,
                     attendance: MeetingAttendance = .notApplicable,
                     availability: MeetingAvailability = .unspecified) -> MeetingOccurrence {
    MeetingOccurrence(id: id, calendarID: calendarID, title: title, start: noon.addingTimeInterval(start),
                      end: noon.addingTimeInterval(start + duration), isAllDay: isAllDay,
                      isCancelled: isCancelled, attendance: attendance, availability: availability)
}

private func present(_ events: [MeetingOccurrence], at now: Date? = nil, preferences: AppPreferences = AppPreferences(),
                     zone: String = "UTC", selected: Set<String> = ["work"]) throws -> MeetingPresentation {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return try MeetingPolicy(calendar: calendar, preferences: preferences)
        .presentation(for: events, selectedCalendarIDs: selected, at: now ?? noon)
}

@Test
func eligibilityExcludesOnlyTheAgreedCases() throws {
    let events = [
        meeting("appointment"), meeting("free", availability: .free),
        meeting("tentative", attendance: .tentative), meeting("unanswered", attendance: .unanswered),
        meeting("accepted", attendance: .accepted),
        meeting("all-day", isAllDay: true), meeting("cancelled", isCancelled: true),
        meeting("declined", attendance: .declined), meeting("zero", duration: 0),
        meeting("negative", duration: -1), meeting("ended", start: -600, duration: 600),
        meeting("unselected", calendarID: "personal"),
    ]
    let snapshot = try present(events)
    #expect(Set(snapshot.remainingToday.map(\.id)) == ["appointment", "free", "tentative", "unanswered", "accepted"])
    #expect(snapshot.hudRows.count == 5)
}

@Test
func emptySelectionProducesNoMeetings() throws {
    let result = try present([meeting("one")], selected: [])
    #expect(result.remainingToday.isEmpty)
    #expect(result.hudRows.isEmpty)
    #expect(result.summary == .idle)
}

@Test
func duplicateCalendarCopiesRemainDistinct() throws {
    let first = meeting("same-id", calendarID: "work")
    let second = meeting("same-id", calendarID: "personal")
    let result = try present([first, second], selected: ["work", "personal"])
    #expect(result.remainingToday.count == 2)
    #expect(Set(result.hudRows.map(\.id)).count == 2)
    #expect(result.summary.text(titleLimit: 24, formatTime: { _ in "12:01" }) == "12:01 2 meetings")
}

@Test
func futureTodayMeetingHasSummaryBeforeItsHUDLeadTime() throws {
    let event = meeting("later", start: 7_200)
    let result = try present([event])
    #expect(result.summary == .upcoming(meetings: [event], isTomorrow: false))
    #expect(result.hudRows.isEmpty)
    #expect(result.remainingToday == [event])
}

@Test
func upcomingWinsOverOngoingAndOnlySameStartCountsAsConflict() throws {
    let ongoing = meeting("ongoing", start: -300, duration: 3_600)
    let nextA = meeting("a", start: 600)
    let nextB = meeting("b", start: 600)
    let overlapping = meeting("later", start: 650)
    let result = try present([overlapping, nextB, ongoing, nextA])
    #expect(result.summary == .upcoming(meetings: [nextA, nextB], isTomorrow: false))
    #expect(result.remainingToday == [ongoing, nextA, nextB, overlapping])
}

@Test
func ongoingOnlyUsesEarliestEndAndActualCount() throws {
    let long = meeting("long", start: -600, duration: 1_800)
    let short = meeting("short", start: -300, duration: 600)
    let result = try present([long, short])
    #expect(result.summary == .ongoing(meetings: [short, long]))
    #expect(result.summary.text(titleLimit: 24, formatTime: { _ in "12:05" }) == "Until 12:05 2 ongoing")
    #expect(try present([short]).summary.text(titleLimit: 24, formatTime: { _ in "12:05" }) == "Until 12:05 Meeting")
}

@Test(arguments: [(-0.001, 0), (0.0, 1), (0.001, 1)])
func leadTimeIncludesItsExactThreshold(offset: Double, expectedCount: Int) throws {
    let event = meeting("next", start: 1_800)
    #expect(try present([event], at: noon.addingTimeInterval(offset)).hudRows.count == expectedCount)
}

@Test
func zeroLeadIsOngoingOnlyAndMaximumLeadIsSupported() throws {
    var preferences = AppPreferences()
    preferences.hudLeadMinutes = 0
    let future = meeting("future", start: 1)
    let active = meeting("active", start: -1)
    let result = try present([future, active], preferences: preferences)
    #expect(result.hudRows.map(\.meeting.id) == ["active"])
    #expect(result.summary == .upcoming(meetings: [future], isTomorrow: false))

    preferences.hudLeadMinutes = 120
    #expect(try present([meeting("max", start: 7_200)], preferences: preferences).hudRows.count == 1)
    #expect(try present([meeting("outside", start: 7_201)], preferences: preferences).hudRows.isEmpty)
}

@Test
func phasesSwitchAtStartAndRowsDisappearAtEnd() throws {
    let event = meeting("one", start: 8, duration: 90)
    let before = try present([event]).hudRows.first
    #expect(before?.phase == .upcoming)
    #expect(before?.symbolName == "bell.fill")
    #expect(before?.boundary == event.start)
    let atStart = try present([event], at: event.start).hudRows.first
    #expect(atStart?.phase == .ongoing)
    #expect(atStart?.symbolName == "play.fill")
    #expect(atStart?.remaining == 90)
    #expect(atStart?.boundary == event.end)
    let atEnd = try present([event], at: event.end)
    #expect(atEnd.hudRows.isEmpty)
    #expect(atEnd.remainingToday.isEmpty)
    #expect(atEnd.summary == .idle)
}

@Test
func rowsOrderByNextBoundaryAndReorderAtStart() throws {
    let startsSoon = meeting("starts", start: 8, duration: 87)
    let endsSoon = meeting("ends", start: -100, duration: 130)
    let later = meeting("later", start: 45)
    #expect(try present([later, endsSoon, startsSoon]).hudRows.map(\.meeting.id) == ["starts", "ends", "later"])
    #expect(try present([later, endsSoon, startsSoon], at: startsSoon.start).hudRows.map(\.meeting.id) == ["ends", "later", "starts"])
}

@Test
func tieOrderIgnoresFetchOrderAndTitleEdits() throws {
    let a = meeting("a", title: "Zebra")
    let b = meeting("b", title: "Apple")
    #expect(try present([b, a]).hudRows.map(\.meeting.id) == ["a", "b"])
    #expect(try present([a, b]).hudRows.map(\.meeting.id) == ["a", "b"])
    #expect(try present([b, meeting("a", title: "Renamed")]).hudRows.map(\.meeting.id) == ["a", "b"])
}

@Test(arguments: [(60.001, false), (60.0, true), (0.1, true)])
func pulseUsesUnroundedFinalMinute(remaining: Double, expected: Bool) throws {
    let upcoming = meeting("upcoming", start: remaining)
    let ongoing = meeting("ongoing", start: -100, duration: 100 + remaining)
    let result = try present([upcoming, ongoing])
    #expect(result.hudRows.count == 2)
    #expect(result.hudRows.allSatisfy { $0.shouldPulse == expected })
}

@Test
func midnightKeepsOngoingMeetingWithoutResetting() throws {
    let event = MeetingOccurrence(id: "overnight", calendarID: "work", title: "Overnight", start: instant("2026-10-25T23:30:00Z"), end: instant("2026-10-26T00:30:00Z"))
    let result = try present([event], at: instant("2026-10-26T00:00:00Z"))
    #expect(result.remainingToday == [event])
    #expect(result.hudRows.first?.phase == .ongoing)
    #expect(result.hudRows.first?.remaining == 1_800)
    #expect(result.summary == .ongoing(meetings: [event]))
}

@Test
func tomorrowLeadCrossesMidnightButTodayListDoesNot() throws {
    let event = MeetingOccurrence(id: "tomorrow", calendarID: "work", title: "Early", start: instant("2026-10-26T00:02:00Z"), end: instant("2026-10-26T00:32:00Z"))
    let result = try present([event], at: instant("2026-10-25T23:58:00Z"))
    #expect(result.remainingToday.isEmpty)
    #expect(result.hudRows.first?.remaining == 240)
    #expect(result.summary == .upcoming(meetings: [event], isTomorrow: true))
    #expect(result.summary.text(titleLimit: 24, formatTime: { _ in "00:02" }) == "Tomorrow 00:02 Early")
}

@Test
func tomorrowOutsideLeadDoesNotReplaceIdleOrOngoingSummary() throws {
    let tomorrow = meeting("tomorrow", start: 86_400)
    #expect(try present([tomorrow]).summary == .idle)
    #expect(try present([tomorrow]).hudRows.isEmpty)
    let ongoing = meeting("ongoing", start: -100)
    #expect(try present([tomorrow, ongoing]).summary == .ongoing(meetings: [ongoing]))
}

@Test(arguments: [
    ("2026-03-08T06:59:00Z", "2026-03-09T03:30:00Z", "2026-03-09T04:00:00Z"),
    ("2026-11-01T04:30:00Z", "2026-11-02T04:30:00Z", "2026-11-02T05:00:00Z"),
])
func localDayUsesDSTBoundaries(now: String, sameDay: String, nextDay: String) throws {
    let within = MeetingOccurrence(id: "within", calendarID: "work", title: "Late", start: instant(sameDay), end: instant(sameDay).addingTimeInterval(60))
    let outside = MeetingOccurrence(id: "outside", calendarID: "work", title: "Tomorrow", start: instant(nextDay), end: instant(nextDay).addingTimeInterval(60))
    let result = try present([outside, within], at: instant(now), zone: "America/New_York")
    #expect(result.remainingToday == [within])
    #expect(result.summary == .upcoming(meetings: [within], isTomorrow: false))
}

@Test
func timezoneChangeReclassifiesTheLocalDay() throws {
    let now = instant("2026-10-25T23:00:00Z")
    let event = MeetingOccurrence(id: "next", calendarID: "work", title: "Next", start: instant("2026-10-26T00:00:00Z"), end: instant("2026-10-26T00:30:00Z"))
    #expect(try present([event], at: now, zone: "UTC").remainingToday.isEmpty)
    #expect(try present([event], at: now, zone: "America/Los_Angeles").remainingToday == [event])
}

@Test
func clockJumpRebuildsPresentationWithoutAccumulatingTicks() throws {
    let event = meeting("one", start: 60, duration: 600)
    #expect(try present([event]).hudRows.first?.remaining == 60)
    #expect(try present([event], at: noon.addingTimeInterval(300)).hudRows.first?.remaining == 360)
    #expect(try present([event], at: noon.addingTimeInterval(700)).hudRows.isEmpty)
    #expect(try present([event], at: noon).hudRows.first?.phase == .upcoming)
}

@Test
func invalidPreferencesAreRejectedBeforePolicyEvaluation() {
    var preferences = AppPreferences()
    preferences.menuTitleLimit = 0
    #expect(throws: PreferenceError.menuTitleLimit) { try present([], preferences: preferences) }
}

@Test
func malformedDatesNeverProduceCountdowns() throws {
    let invalid = MeetingOccurrence(id: "invalid", calendarID: "work", title: "Invalid",
                                    start: Date(timeIntervalSince1970: .nan), end: noon.addingTimeInterval(600))
    #expect(try present([invalid]).hudRows.isEmpty)
    #expect(try present([meeting("valid")], at: Date(timeIntervalSince1970: .nan)).summary == .idle)
}

@Test(arguments: [
    (4_500.0, "1h 15m"), (3_600.0, "1h 0m"), (3_599.9, "1h 0m"),
    (901.0, "16m"), (900.0, "15m"), (300.0, "5m"),
    (299.5, "5:00"), (299.0, "4:59"), (60.0, "1:00"),
    (0.01, "0:01"), (0.0, "0m"), (-10.0, "0m"),
])
func countdownRoundsUpAtDisplayedPrecision(remaining: Double, expected: String) {
    #expect(MeetingText.countdown(remaining, secondsThresholdMinutes: 5) == expected)
}

@Test
func zeroAndMaximumSecondsThresholds() {
    #expect(MeetingText.countdown(0.01, secondsThresholdMinutes: 0) == "1m")
    #expect(MeetingText.countdown(60.01, secondsThresholdMinutes: 0) == "2m")
    #expect(MeetingText.countdown(3_599, secondsThresholdMinutes: 60) == "59:59")
    #expect(MeetingText.countdown(3_600, secondsThresholdMinutes: 60) == "1h 0m")
    #expect(MeetingText.countdown(.infinity, secondsThresholdMinutes: 5) == "—")
}

@Test
func titleFormattingPreservesUnicodeAndUsesUntitledFallback() throws {
    #expect(MeetingText.displayTitle(" \n ") == "Untitled meeting")
    #expect(MeetingText.truncatedTitle("1234567👨‍👩‍👧‍👦89", limit: 8) == "1234567👨‍👩‍👧‍👦…")
    #expect(MeetingText.truncatedTitle("12345678", limit: 8) == "12345678")
    let event = meeting("one", title: "")
    let result = try present([event])
    #expect(result.hudRows.first?.title == "Untitled meeting")
    #expect(result.summary.text(titleLimit: 24, formatTime: { _ in "12:01" }) == "12:01 Untitled meeting")
    #expect(MenuSummary.idle.text(titleLimit: 24, formatTime: { _ in "unused" }).isEmpty)
}
