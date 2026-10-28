import EventKit
import MeetMeetCore

/// Store creation, fetching and mapping stay on this actor, never the UI actor.
actor EventKitCalendarReader: CalendarReading {
    private var eventStore: EKEventStore?

    private func store() -> EKEventStore {
        if let eventStore { return eventStore }
        let created = EKEventStore()
        eventStore = created
        return created
    }

    func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notRequested
        case .fullAccess: .fullAccess
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .unreadable
        @unknown default: .unreadable
        }
    }

    func requestAccess() async throws -> CalendarAccess {
        let eventStore = store()
        let _: Bool = try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if error != nil { continuation.resume(throwing: CalendarReadError.requestFailed) }
                else { continuation.resume(returning: granted) }
            }
        }
        eventStore.reset()
        return access()
    }

    func calendars() throws -> [CalendarDescriptor] {
        guard access() == .fullAccess else { throw CalendarReadError.accessUnavailable }
        return store().calendars(for: .event).map {
            CalendarDescriptor(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source?.title ?? "Calendar")
        }
    }

    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) throws -> [MeetingOccurrence] {
        guard access() == .fullAccess else { throw CalendarReadError.accessUnavailable }
        guard interval.duration > 0, interval.duration <= 172_800 else { throw CalendarReadError.invalidInterval }
        let eventStore = store()
        let selected = eventStore.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: selected)
        let mapped = try eventStore.events(matching: predicate).map(Self.snapshot)
        guard access() == .fullAccess else { throw CalendarReadError.accessUnavailable }
        return mapped
    }

    private static func snapshot(_ event: EKEvent) throws -> MeetingOccurrence {
        guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate,
              !event.calendarItemIdentifier.isEmpty else { throw CalendarReadError.invalidEvent }
        let evidence = EventIdentityEvidence(
            sourceID: calendar.source?.sourceIdentifier, localItemID: event.calendarItemIdentifier,
            externalItemID: event.calendarItemExternalIdentifier, eventID: event.eventIdentifier,
            originalOccurrenceDate: event.occurrenceDate, isRecurring: event.hasRecurrenceRules,
            isDetached: event.isDetached
        )
        let participant = event.attendees?.first { $0.isCurrentUser }?.participantStatus
        let attendance: MeetingAttendance
        switch participant {
        case .accepted: attendance = .accepted
        case .declined: attendance = .declined
        case .tentative: attendance = .tentative
        case .pending, .unknown: attendance = .unanswered
        default: attendance = .notApplicable
        }
        let availability: MeetingAvailability
        switch event.availability {
        case .busy: availability = .busy
        case .free: availability = .free
        case .tentative: availability = .tentative
        case .unavailable: availability = .unavailable
        default: availability = .unspecified
        }
        return MeetingOccurrence(
            id: evidence.occurrenceID(start: start), calendarID: calendar.calendarIdentifier,
            title: event.title ?? "", start: start, end: end, isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled, attendance: attendance, availability: availability,
            identityEvidence: evidence, location: event.location,
            url: MeetingLink.resolve(url: event.url, location: event.location, notes: event.notes)
        )
    }
}

private enum CalendarReadError: Error { case requestFailed, accessUnavailable, invalidInterval, invalidEvent }
