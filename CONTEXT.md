# Meeting Countdown

## Language

**Meeting**:
A timed calendar occurrence eligible for countdowns in a selected calendar, whether or not it has attendees or a meeting link. This includes appointments and focus blocks, but excludes all-day, cancelled, declined, and non-positive-duration events.
_Avoid_: Using “meeting” to mean only events with attendees.

**Occurrence**:
A single scheduled instance of a calendar event. Each instance of a recurring series is a separate occurrence.

**Selected calendar**:
A calendar the user has explicitly chosen to monitor, including calendars synced from external accounts into macOS.

**Ongoing meeting**:
A meeting whose start has been reached and whose end has not yet been reached.

**Remaining meetings**:
Meetings that have not ended and overlap the current day in the Mac's current timezone, including meetings that started on a previous day.

**Pause for Today**:
A temporary suspension of countdown presentation and sounds until resumed or the next local midnight. Calendar information continues to refresh, and the menu remains available.

**Same-start conflict**:
Two or more upcoming meetings sharing the next start time. Meetings that merely overlap are not a same-start conflict.

**Hidden occurrence**:
A single occurrence excluded from meeting entries, countdowns, and sounds by an explicit hide rule. Hiding expresses reminder relevance, not attendance status.

**Hidden series**:
A recurring series excluded from meeting entries, countdowns, and sounds within its calendar by an explicit hide rule.

**Countdown phase**:
The upcoming interval counting toward a meeting's start, or the ongoing interval counting toward its end.

**Meeting info**:
A meeting's title, available location and video-meeting join link, available for both upcoming and ongoing meetings. Opening meeting info manually is distinct from its automatic start visual cue.
_Avoid_: Using “pre-meeting splash” to imply meeting info is only available before start.

**Start visual cue**:
An automatic reminder that presents meeting info at the configured interval before a meeting starts. A manually opened meeting info screen does not consume or dismiss this reminder.

**Hide countdown until final minute**:
A temporary suppression of one meeting's HUD row until the final 60 seconds of its current countdown phase. Its menu entry and configured sounds remain available; this is distinct from hiding the occurrence or series.
