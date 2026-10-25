# Meeting Countdown — MVP Specification

Status: approved product decisions, ready for implementation.

## 1. Purpose and scope

A personal-first native macOS utility for noticing upcoming meetings and keeping ongoing meetings on time. Read the local EventKit store, including synced accounts, without a backend or calendar writes. Both upcoming and ongoing countdowns are core.

MVP includes a persistent calendar menu, one floating countdown stack, calendar selection, permanent and temporary hiding, optional bundled/system sounds, and opt-in launch at login.

Out of scope: accounts for this app, analytics/telemetry, a backend, user audio-file import, public distribution, notarization, automatic updates, and older-OS compatibility work. No additional appearance controls were specified beyond system appearance; no other draft feature is silently deferred. No promise of waking the Mac, alarms after Quit, exact real-time playback, or visibility above every system/full-screen surface.

## 2. Platform and boundaries

- Initial deployment target: macOS 26+. Older systems must not impose compatibility shims or testing overhead.
- Swift 6, SwiftUI for views/settings, AppKit for agent lifecycle and `NSPanel`, EventKit for calendar reads, and `SMAppService.mainApp` for login launch.
- Verified development tools: Xcode 27.1 (27A9275), Swift 6.4, macOS SDK 27.0. Keep the deployment target distinct from the installed SDK.
- Enable App Sandbox and the calendars entitlement. Supply `NSCalendarsFullAccessUsageDescription`. macOS requires full calendar authorization to read events; explain honestly that this app never edits events.
- No contacts, reminders, microphone, or notification permission. Audio uses normal local sound playback, not notification delivery.
- Set `LSUIElement = YES`: no Dock icon or Cmd+Tab entry. Keep a calendar menu bar icon visible whenever the app runs.
- Keep calendar reading, deterministic meeting/countdown/alert policies, local persistence, and native presentation separate. Policy tests must accept a controllable clock and dummy calendar/audio adapters.

## 3. Calendar eligibility and time semantics

Use the glossary in `CONTEXT.md`.

- A meeting is any timed occurrence in a selected calendar, including focus blocks and appointments without attendees or meeting URLs.
- Exclude all-day, cancelled, declined, and non-positive-duration events. Include tentative/unanswered invitations and events marked free.
- Offer every calendar available through EventKit, including synced Google, Exchange and iCloud calendars and On My Mac calendars when present.
- Onboarding asks the user to select calendars; do not enable all implicitly. Newly discovered calendars default unselected. Preserve selections across restarts and permission loss/regrant.
- Each recurring occurrence is separate. Keep entries from different calendars separate even if titles/times match; no heuristic deduplication.
- Ongoing means `start <= now < end`. Ended meetings are not remaining meetings.
- Today's remaining list includes unended eligible meetings overlapping the current local calendar day, including meetings that started on a prior day. Use calendar-day boundaries, not fixed 24-hour arithmetic; display event times in the Mac's current timezone.
- Overnight meetings remain ongoing through midnight without resetting countdowns.
- HUD lead times cross midnight. At 23:58, a 00:02 meeting can already have a HUD. The summary may show that imminent next-day meeting with `Tomorrow` before its time; the today list remains scoped to today.
- Empty titles display `Untitled meeting`. Use full source titles in meeting details; menu-summary truncation does not alter source data.

## 4. Calendar access and reconciliation

- Distinguish access not requested, denied/restricted or otherwise unreadable, no selected calendars, a refresh failure, and an authorized empty result.
- Fetch away from the main UI path. Use bounded date-range queries that include ongoing meetings, today's remaining meetings, and the upcoming lead/alert horizons across midnight.
- Treat EventKit change notifications as invalidation; refetch and reconcile rather than retaining stale event objects. Do not promise instantaneous remote-account sync.
- Reconcile on launch, calendar changes, relevant settings changes, wake, local-day/timezone changes, clock changes, pause expiry/resume, and access recovery.
- Derive remaining time from timestamps and current time, not accumulated timer ticks. Sleep and delayed timers do not extend a meeting.
- On loss of permission or failure that makes current data untrustworthy, clear meeting information/HUDs and suppress sounds. Retain the status menu, actionable explanation and Retry; retry automatically with backoff.
- Preserve calendar choices and app rules during access errors. Restore presentation only after fresh authorized data is available. Do not log event content.

## 5. Persistent menu bar

Use a calendar icon followed by time and summary when relevant:

| State | Example after icon |
| --- | --- |
| Earliest upcoming meeting | `14:00 Weekly team meeting` |
| Multiple meetings sharing that next start | `14:00 2 meetings` |
| Only one ongoing meeting remains | `Until 14:30 Weekly team meeting` |
| Only multiple ongoing meetings remain | `Until 14:30 2 ongoing` |
| Imminent next-day meeting | `Tomorrow 00:02 Weekly team meeting` |
| No remaining/relevant meetings | No additional text |
| Paused | `Paused` |
| Access/setup problem | `Calendar access needed` or `Select calendars` |

- Upcoming meetings take priority over ongoing ones. For multiple ongoing meetings, display the earliest end and actual count.
- Same-start conflicts count meetings at the earliest upcoming start; partial overlaps remain separate dropdown entries.
- Truncate summary titles at a configurable character limit, default 24, with an ellipsis when truncated; preserve time. Count user-perceived characters rather than splitting Unicode sequences.
- Pause takes precedence over meeting text; access problems remain visible inside the dropdown while paused.
- The dropdown exposes current/upcoming meeting details including full title and available location/URL, today's remaining list, occurrence/series hide actions, temporary countdown suppression/restoration, Manage Hidden Events, Pause/Resume, Settings and Quit. An imminent tomorrow meeting represented by the summary must have accessible details/actions even though it is outside today's list.
- Keep menu ordering stable and make ongoing/upcoming states distinguishable. Never hide the entire status item on an idle day.

## 6. Floating countdown stack

### Layout and interaction

- One borderless, transparent, floating, nonactivating `NSPanel`; one row per currently relevant meeting. This replaces the original separate-window-per-meeting design.
- Upcoming rows appear at their own configured lead time; ongoing meetings appear immediately on launch/resume. Lead time zero means ongoing-only HUDs.
- Order by next boundary: upcoming start or ongoing end, soonest first. Reorder at transitions and preserve a stable tie order.
- Compact rows show only a state icon and prominent countdown. Use actual SF Symbols: `bell.fill` upcoming, `play.fill` ongoing. State must not depend on color alone.
- Hovering anywhere on the stack reveals all titles. Titles are left-aligned and wrap to at most two lines; no visible `Starts in`/`Ends in` labels. Full titles remain available in the menu.
- Newly arriving or restored rows reveal all titles for 3 seconds. Hover holds them open; reordering alone does not trigger expansion.
- Drag the entire stack. No meeting click actions on the HUD; actions live in the menu. If rows exceed available height, constrain the stack and permit vertical scrolling.
- HUD appearance, hover, drag, scrolling and transitions must not activate the app, steal keyboard focus, or switch Spaces. Settings/onboarding may accept focus normally.

### Timing, formatting and pulse

- Default lead time is 30 minutes. At start, change the bell to play and count toward end. At end, remove the row; never show negative time.
- Show hours/minutes (`1h 15m`), minutes (`15m`), or minutes:seconds (`4:59`) when below the seconds threshold, default 5 minutes. A zero seconds threshold disables seconds.
- Round upward at the displayed precision so positive time does not display zero. Evaluate state boundaries from actual timestamps, not rounded display values.
- Pulse the relevant SF Symbol continuously during the last 60 seconds of either phase. Switch/stop at the boundary; honor Reduce Motion by disabling pulse. Retain accessible state semantics without animation.

### Placement and accessibility

- Initial placement: upper-right of the primary display's usable area. Persist the dragged stack location across restarts.
- Anchor the right edge during expansion; temporarily shift if necessary to keep expansion onscreen. Keep the stack within usable bounds.
- Only one stack, draggable between displays. Show across Spaces and over full-screen apps where macOS permits, without a universal always-on-top guarantee.
- Recover onto the primary display if its display disappears. Re-evaluate usable bounds on display configuration changes.
- Respect system light/dark appearance and accessibility settings, using semantic colors/materials. Provide VoiceOver meeting identity, upcoming/ongoing state and remaining time even while titles are visually collapsed; avoid continual intrusive announcements.

## 7. Permanent hiding and temporary suppression

### Hide meeting / series

- Hiding expresses reminder relevance (e.g. daily Lunch or focus time), not attendance. Declining a meeting remains an action in the source calendar.
- `Hide this meeting` suppresses one occurrence. `Hide this series` suppresses identifiable occurrences and exceptions of that series within its calendar.
- Both immediately remove meeting entries/HUD rows and suppress sounds without writing to the calendar. Rules persist across restarts and calendar deselection/reselection.
- Follow edits/rescheduling only where identity is confidently preserved. Never match by title alone. On ambiguous identity, fail visible rather than hide an unrelated meeting.
- Treat deleted/recreated events, cross-calendar moves and this-and-future series splits as new unless identity/relationship is reliably established. Do not promise identifiers survive provider rewrites or full sync.
- Manage Hidden Events has separate Meetings and Series lists with saved title, calendar and occurrence date where applicable. Offer Unhide and confirmed Unhide All.
- Keep unmatched rules for manual removal. Clean up occurrence rules after their meeting has ended where that is known; keep series rules until explicitly removed.
- Unhiding restores presentation only if normal eligibility/calendar filters still permit it.

### Hide countdown until final minute

- A distinct menu action suppresses only that meeting's HUD row for its current phase. Its menu entry and configured sounds remain unchanged.
- Restore at 60 seconds before the current boundary with the normal pulse. Disable the action when already in the final minute.
- Offer `Show countdown now`. Persist suppression across restarts and clear it at the phase boundary.
- Upcoming suppression does not carry into ongoing: normal ongoing presentation resumes at start and may be suppressed separately.
- If an edit moves the current boundary within the final minute, restore immediately. If the phase has already ended, reconcile to the current phase or remove the ended occurrence.

## 8. Pause, onboarding and lifecycle

- `Pause for Today` hides meeting countdown text/HUDs and suppresses sounds, but keeps the calendar icon with `Paused`, Resume, Settings and Quit. Calendar refresh continues silently.
- Persist pause through restart until explicit Resume or the next local midnight. Waking after expiry must not extend pause; reconcile local time/timezone changes.
- Resume shows current relevant countdowns without replaying missed audio. Permanent hide rules and phase-specific temporary suppression still apply.
- First launch opens onboarding: calendar permission, calendar selection and optional login launch. Allow completion with no selected calendars and retain actionable status.
- Subsequent launches run quietly. Reopening via Finder/Spotlight opens settings/status even if already running.
- Launch at login defaults off; provide onboarding/settings controls through `SMAppService.mainApp`. Reflect actual service approval/status and registration failures, not merely a stored toggle.
- Explicit Quit stays quit until manual launch or a subsequent login with login launch enabled. No automatic crash-restart guarantee.

## 9. Audio

- App-bundled MP3 cues plus system sounds. No custom audio import. Two independent global opt-in cues: before start and before end; each has a sound and offset. Default sounds are `meet-meet.mp3` before start and `wrap-wrap.mp3` before end; preserve existing saved sound choices.
- Both default off. Suggested offsets: 1 minute before start and 2 minutes before end. Offsets 0–60 minutes; zero means at the boundary.
- Provide Preview and app-level volume without changing system volume. Surface actionable playback failures.
- Scheduled cues also wiggle each corresponding already-visible HUD icon five times, with a one-second pause between repeats, respecting Reduce Motion. Do not reveal hidden/out-of-window rows or retain ended rows for this effect. Preview does not trigger the HUD cue. Coincident cues animate all corresponding visible icons even when audio is coalesced.
- Best-effort playback while running; no wake-from-sleep, after-Quit, or exact-deadline guarantee. Muted/unavailable output cannot guarantee audibility.
- After sleep, late startup, pause or lost access, skip already-passed alerts. Settings changes also never replay missed sounds. Schedule future eligible cues after reconciliation.
- At most once per occurrence per cue type, persisted across restarts. Edits may move an unplayed cue into the future but never replay a played/handled cue; backward clock changes do not replay it.
- Coalesce coincident cues into one playback; start wins over end. Mark all coincident cues handled, do not queue them.
- Skip an end-warning cue whose scheduled time is before the meeting's start. Do not replay missed cues for short meetings.
- Permanent hiding and pause suppress audio. Temporary HUD-only suppression does not.

## 10. Settings and local persistence

| Setting | Default | Allowed values |
| --- | --- | --- |
| Launch at login | Off | Actual service state with enable/disable action |
| HUD lead time | 30 minutes | 0–120 minutes; zero ongoing-only |
| Seconds threshold | 5 minutes | 0–60 minutes; zero disables seconds |
| Menu title limit | 24 characters | 8–80 characters |
| Start audio | Off; meet-meet; suggested offset 1 minute | Bundled or system sound, enable/disable, offset 0–60 minutes |
| End audio | Off; wrap-wrap; suggested offset 2 minutes | Bundled or system sound, enable/disable, offset 0–60 minutes |
| Audio volume | Normal playback level | App-local volume, never system volume |
| Calendar selection | Explicit onboarding choice | Available EventKit calendars; new calendars unselected |

Settings sections: General, Calendars, Audio and Hidden Events. General includes menu-title length as well as countdown/login controls. Validate input and apply changes immediately without retroactive audio.

Minute/count settings support direct whole-number entry as well as optional steppers. Commit typed values on Return or focus loss; show inline range errors without saving invalid input. The 30-minute lead-time default applies to fresh/missing preferences, not as an override of an existing saved choice.

Persist locally: preferences/calendar choices, onboarding completion, pause expiry, stack location, occurrence/series rules, phase-specific temporary suppression, and cue-handling history. Use app-local versioned records (UserDefaults/AppStorage or equivalent simple local storage); no server. Retain only metadata needed for behavior/recovery; no event-content logs or telemetry. Identifier evidence must be scoped to calendar/source, not a title-based global key.

## 11. Acceptance and implementation handoff

[Implementation backlog](https://github.com/nnerik/meet-meet/issues/12) contains eleven build tickets with native sub-issue relationships, blocking dependencies and acceptance criteria. Start with [Scaffold the sandboxed Swift macOS agent project](https://github.com/nnerik/meet-meet/issues/13). Build tickets summarize actionable requirements from this specification; the closed decision issues retain rationale.

Automated policy tests use fixed calendars and a controllable clock. Cover eligibility, overlaps/conflicts, overnight/DST/timezone changes, lead-time boundaries and zero settings, start/end transitions, rounding, stable ties, hide matching ambiguity, suppression restoration, pause expiry, rescheduling, cue coalescing/duplicate prevention, restart persistence and error recovery.

Native acceptance on the sandboxed app must cover:

1. First-run permission, denied/restricted access, revocation/regrant, empty selection and refresh retry.
2. Real calendar-provider identity through rename, moved occurrence, exception, split, deletion/recreation, deselection/reselection and identifier churn; document actual limitations without private event logs.
3. Login registration/status, real logout/login, reopen, explicit Quit and restart persistence from a stable app path.
4. Focus while typing elsewhere through appearance, hover, drag, scrolling and transitions; VoiceOver, Reduce Motion and system appearance.
5. Spaces, supported full-screen/Stage Manager combinations, multiple displays, scaling, display removal and offscreen recovery.
6. Sleep/wake, clock/timezone changes, missed alerts, simultaneous cues, muted/output-change playback and failure feedback.

These are implementation acceptance checks, not claims that the prototype validated every combination. The user accepted the running dummy-data native layout exploration; it did not request calendar access or validate production sandbox/login integration. Rewrite production code intentionally rather than promoting throwaway code wholesale.

## 12. Decision and exploration references

- [Planning map](https://github.com/nnerik/meet-meet/issues/1): index of the closed decision discussions and resulting build backlog.
- [Calendar eligibility](https://github.com/nnerik/meet-meet/issues/3), [menu/pause](https://github.com/nnerik/meet-meet/issues/4), [HUD](https://github.com/nnerik/meet-meet/issues/5), [hiding](https://github.com/nnerik/meet-meet/issues/6), [audio](https://github.com/nnerik/meet-meet/issues/7), [platform](https://github.com/nnerik/meet-meet/issues/8), [final defaults](https://github.com/nnerik/meet-meet/issues/11).
- [Apple-sourced platform research](https://github.com/nnerik/meet-meet/blob/research/macos-constraints/docs/research/macos-platform-constraints.md).
- [Browser layout exploration](https://github.com/nnerik/meet-meet/tree/prototype/hud-layout/prototypes).
- [Accepted native exploration](https://github.com/nnerik/meet-meet/tree/prototype/native-hud/prototypes/native-hud), [review](https://github.com/nnerik/meet-meet/issues/9).
