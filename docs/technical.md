# Meet Meet: technical guide

Detailed behavior, development commands, architecture and implementation caveats.
Start with the [README](../README.md) for an introduction, Google Calendar setup
and screenshots, or the [installation guide](installation.md) for downloads and
macOS security warnings.

The approved behavior is in [`spec.md`](../spec.md); implementation is tracked in
the [MVP backlog](https://github.com/nnerik/meet-meet/issues/12). Source code and
bundled media are available under the [MIT License](../LICENSE).

## Current status

The app currently has a sandboxed agent foundation, persistent calendar menu,
editable General/Cues preferences, versioned local state and testable core
boundaries. Deterministic policies now cover event eligibility, menu selection,
countdown rows, formatting, ordering and pulse thresholds. Read-only EventKit
access, explicit calendar selection and live menu summaries are now connected.
Occurrence/series hiding and the recovery view are connected, as is temporary
HUD-row suppression. Pause/Resume is available from the always-present menu.
The floating countdown stack and optional audio cues are connected to live
meetings. First-run onboarding and opt-in launch-at-login controls are connected.
The app loads no prototype/dummy meetings. The shared live-session pipeline has
end-to-end deterministic regression coverage; native acceptance is still in progress.

First launch shows a three-step setup: menu-bar introduction, calendar
permission/selection, and optional launch at login. You may finish without
calendar access or any selections. Completing setup is saved; later launches
stay quiet. Closing setup before finishing leaves it available from Settings
and on the next launch, without resetting saved choices. Use **Settings →
General → Review Setup** to revisit it.

Open **Settings → Calendars → Allow Calendar Access**, then select calendars
to monitor. Nothing is selected automatically. Permission is requested only
from that button; subsequent launches reuse existing consent and choices.
Denied/restricted access has a privacy-settings link; fetch errors have Retry.
Open a meeting's submenu to hide its occurrence/series or suppress its
countdown until the final minute. **Manage Hidden Events** opens the saved
Meetings/Series rules with Unhide and confirmed Unhide All. Temporary hiding
leaves the menu/audio eligibility intact and removes only that meeting's HUD row.

Relevant meetings appear in one lower-right floating stack: bell for upcoming,
play for ongoing, with a Reduce Motion-aware pulse during the final minute.
Click a row to open meeting info for an upcoming or ongoing meeting, hover to
reveal all titles, drag to move the entire stack, or scroll when rows
exceed screen height. New/restored rows reveal titles for three elapsed seconds;
reordering alone does not. The stack grows upward from its lower-right anchor.
Dragged position is saved relative to the display's usable lower-right corner,
so resizing the display preserves its edge offsets, and disconnected
displays recover onto the primary usable area. Spaces/full-screen visibility is
best-effort where macOS permits, never a reason to switch Spaces or take focus.
No stack is shown without an eligible ongoing meeting or upcoming meeting inside
the configured lead time.

**Settings → Cues** groups audio and visual reminders into before-start and
before-end sections. Visual cues default on one minute before start and two
minutes before end (each configurable from 1–60 minutes), centered on the primary
display. Default artwork is `meet-meet.png` for start and `wrap-wrap.png` for end,
independent of system appearance; each can be replaced with an imported image.
Start cues automatically open meeting info: the title, available location and a
camera-icon **Join** button for an available link, opened in its default app.
Successful joining closes the info panel so it does not obscure the meeting;
failed opening keeps it available with an error. Conferencing links in event
locations and notes are recognized, including Google Meet. End cues show only the
title. Close with **×**, or click the artwork then press **Escape**; presentation
does not take keyboard focus. Meeting info stays through meeting start until
closed or the meeting ends; end visuals close at meeting end. Cue dismissals
survive restart independently for start and end. Overlapping reminders
share one scrollable panel without losing meeting details. Launch/wake/resume
catches up inside either visual cue interval, but end visuals never appear before
the meeting starts. Pause and hidden meetings suppress both; temporary countdown
hiding and the regular HUD's lead time do not affect them.

HUD clicks open the same meeting info even with visual cues disabled or already
dismissed. Manually opening or closing info does not consume a future cue. A newly
due visual cue raises the panel even if manual info is still open, without
activating the app. Once an automatic cue has presented, closing the panel
dismisses that cue normally. Manual-only opens do not write cue history. Open info
is temporarily hidden during calendar refresh and restored from fresh eligible
data, including after meeting start; it is cleared on pause, access loss, removal,
hiding or meeting end. Dragging does not open info, and scrolling is accounted for
when resolving a clicked row. Screen readers can invoke the row's open action too.

**Settings → General → Meeting locations → Shorten meeting room names** is
off by default and supports only Google Workspace structured room names. For
example, `HQ-3-D-Boardroom (16) [Google Meet, TV]` displays as `Boardroom` in
meeting details and start visual cues. The optional resource type, building,
floor, section, capacity and features are removed only when the structured
pattern matches; other locations remain unchanged. The setting changes display
text only, never calendar events or meeting-link detection. Menu location
tooltips retain the original location.

The same **Cues** tab offers independent start/end audio cues (both off by default),
bundled, system or imported sound selection, Preview and app-local volume. The bundled
`media/meet-meet.mp3` and `media/wrap-wrap.mp3` are the start/end defaults for new
settings and are offered only for their respective phases. System and imported
sounds work for either phase. Valid saved choices are preserved; an unsupported
opposite-phase bundled choice loads as that phase's default without changing
enablement or timing. Preference edits reject opposite-phase bundled choices.
Xcode copies these files
into the app bundle, so playback does not depend on the source folder at runtime.
Zero-minute offsets play
at the boundary; end warnings before a short meeting's start are skipped.
Only future cues are armed after startup, wake, pause, access loss or settings
changes. Coincident cues play once (start wins), with all receipts persisted
before playback. Handled cues do not replay after rescheduling or clock reversal.
Unreadable safety records disable automatic sounds rather than risking repeats;
Preview remains available. Playback errors appear in Cues settings. Playback is
best-effort while the app runs; mute/output changes and sleep may prevent sound.
Imported audio and images are validated and copied into the sandbox's Application
Support/MeetMeet/CueMedia directory, so the originals need not remain accessible.
Import uses user-selected read-only access; no permanent external-file access or
security-scoped bookmark is needed. System volume is never changed.
Scheduled cues also wiggle each corresponding visible HUD icon five times with
a one-second pause between repeats, unless Reduce Motion is enabled. This never
reveals a hidden countdown or retains an ended meeting. Preview does not animate
the HUD; coincident cues animate all corresponding visible icons.

Unreadable visual-cue dismissal history disables automatic visuals but still
allows explicitly opening trusted meeting info from a countdown. Manual opens
and closes do not overwrite that history. Unreadable selection, hiding, pause
or preference records still block info because eligibility is untrusted.

**Pause for Today** keeps the menu and calendar refresh available but hides
HUD rows and withholds audio-eligible input. Its next-local-midnight deadline
is saved as a timestamp, so restart or sleeping through that deadline does not
extend it. Resume restores current eligible presentation without changing hide
rules or temporary suppression. Access problems remain visible inside the
dropdown while the menu bar says Paused.

Settings save immediately and survive relaunch. **Settings → General → Launch
at login** uses the actual macOS service state, not a stored toggle. Registration
only happens after an explicit toggle; setup completion never enables it.
Pending approval is shown separately from Enabled, with a Login Items settings
button and actionable errors. Quitting stays quit until manual launch or the
next login if enabled. Finder/Spotlight reopen shows setup/settings, not another
agent instance. Closing settings leaves the app running in the menu bar.
Numeric settings support direct entry (Return or leaving the field saves) and
optional steppers. New preferences default to a 30-minute upcoming lead time;
existing saved choices are preserved.

## Develop

Requires macOS 26+ and full Xcode selected as the active developer tools.
Verified with Xcode 27.1 (27A9275), Swift 6.4 and macOS SDK 27.0. The deployment
target is macOS 26.0; the SDK version is not the deployment target.

```sh
make build       # Build the app with local ad-hoc signing
make run         # Build and open the persistent calendar menu
make test        # Deterministic core tests via Swift Package Manager
make test-xcode  # Core tests plus native HUD checks (brief fixture window)
make verify     # Verify the built signature and inspect entitlements
make release VERSION=0.2.0  # Test and package an arm64 DMG from a clean tree
```

Or open `MeetMeet.xcodeproj`, select **MeetMeet**, and Run/Test. Settings and
Quit are available in the calendar menu; Finder/Spotlight reopening opens the
settings shell. A menu bar app has no Dock or Cmd+Tab entry.

Build output goes to ignored `build/DerivedData`. `make CONFIGURATION=Release
build` builds Release. Quit the running app before rebuilding to inspect a new
version. The target architecture defaults to this Mac; override `DESTINATION`
when explicitly testing a different supported architecture.

See [release management](releases.md) for version tags, GitHub Actions
publishing, packaging checks and distribution limitations.

## Code layout

- `App/`: AppKit lifecycle/menu and SwiftUI presentation, sandbox entitlements,
  usage description and stable bundle identifier `dev.nnerik.meetmeet`.
- `Sources/MeetMeetCore/`: local Swift package with immutable calendar values
  and testable time/calendar/audio/state boundaries. `AppState` owns validated
  observable preferences and separate versioned records for selection,
  onboarding, pause, placement, hiding, suppression and cue history. No AppKit
  or EventKit.
- `MeetingPolicy` consumes an explicit timestamp and calendar timezone and
  returns today's remaining meetings, menu summary and HUD rows. No timers or
  UI objects are involved. The menu and native HUD consume this same policy.
  Internal `MeetingCountdown` shares the phase, deadline and exact final-minute
  decisions between HUD rows, menu actions and suppression writes/reconciliation.
- `MeetingSession` coordinates the real `CalendarSession`, `AudioCueSession`
  and lifecycle events behind the same public interface used by the app and
  integration fixtures. All outputs share the reconciled calendar timestamp,
  including audio arming after settings edits between native timer ticks.
  It disarms synchronously on external changes and guards observation rearming,
  while normal timestamp-driven hide cleanup preserves other eligible due cues.
  Calendar refreshes retire stale queued settings callbacks. The native
  delegate now translates OS lifecycle notifications into this shared session,
  rather than owning a separate audio orchestration path. The menu title reacts
  to session changes, and unchanged titles are not rewritten on every tick.
- `App/CountdownHUDController.swift` owns the nonactivating panel and passive
  SwiftUI rows, native dragging/scrolling and display-change notifications.
  `HUDPlacementSession` owns preferred-anchor recovery, compact-before-expanded
  layout ordering, movement persistence and failed-save live fallback. A failed
  save leaves the durable record untouched and reports the error; refresh uses
  the live anchor, while restart uses only durable state and normal recovery.
  Its update result tells the native caller to hide, retain the current frame,
  or apply a layout. Movement holds title expansion and reflow until completion,
  including overlapping view/native callbacks and temporary empty refreshes.
  Display changes are detected from the supplied geometry and can recover during
  movement; that layout-generated frame becomes accounted for, not a new dragged
  anchor when a later view callback ends. Native-only movement releases when the
  pointer is up; stopping explicitly cancels the interaction.
  Native moves arriving with unreconciled display geometry do not establish a
  new anchor; the next update recovers from the known preference first. Delayed
  notifications for an already applied/observed frame are ignored as well.
  Pure `HUDLayoutPolicy` tests placement/clamping/overflow without windows;
  `HUDRevealState` uses elapsed monotonic time for arrival-title timing.
  Native window-move notifications save the authoritative anchor; controller
  layout moves are excluded so refreshes and title expansion cannot reset it.
  Accessibility hit-testing routes directly to the SwiftUI document (or native
  scroller), separately from pointer capture for dragging. This lets the
  VoiceOver cursor target individual rows without giving the HUD keyboard focus.
  Spoken countdown values use full units (for example, “Starts in 8 minutes”),
  with the same rounding/precision as the compact on-screen text.
- `App/EventKitCalendarReader.swift` owns its EventKit store on an actor and
  converts events to immutable values, retaining recurrence/exception evidence
  without calendar writes. `CalendarSession` handles access, coalesced refresh,
  stale-response rejection and retry, with a replaceable scheduler for tests.
- `ReminderRules` owns persisted hide/suppression actions. Its pure visibility
  policy filters permanent hides before menu/audio eligibility, and temporary
  suppression only from HUD rows. Matching uses scoped identifiers and original
  recurrence dates, never titles; uncertain identity fails visible.
- `MenuBarState` gives pause priority over calendar status and meeting summaries;
  the dropdown still exposes the underlying status and meeting details. Menu
  entries include full-title tooltips/accessibility labels, calendar and times.
  `CalendarSession.meetingMenu` captures phase, countdown boundary, hide choices
  and suppression availability from the same reconciled time and occurrence
  snapshot as the HUD. The native `MeetingMenuItem` only renders those decisions;
  it never samples wall time. `MeetingSession.performReminderAction` resolves
  an occurrence key against current calendar values and validates fresh clock
  time, readiness, selection, eligibility and unique identity before any write.
  A captured menu's availability never authorizes a reminder change. Successful
  actions use the normal live reconciliation path; rejected actions leave
  reminder state untouched and native error presentation remains in the delegate.
- `OnboardingSession` owns setup progress and persisted completion without
  requiring access or calendar selection. `LoginLaunchSession` reads a
  replaceable OS service adapter and serializes explicit registration changes;
  it has no mirrored preference or launch-time side effects. Native
  `App/LoginLaunchService.swift` uses `SMAppService.mainApp`, and
  `App/SetupViews.swift` shares calendar and login controls between setup/settings.
- `Tests/MeetMeetCoreTests/`: shared deterministic Swift Testing cases, with no
  real calendars, permission prompts, network requests or wall-clock timer waits
  in core tests. `MeetingSessionTests.swift` supplies fake clock/calendar/storage/
  sound adapters to the production pipeline, covering start/end consistency,
  fast pause/resume, settings edits, hiding versus HUD suppression, permission
  loss, retry and empty recovery, midnight/overnight/short/coincident meetings,
  rescheduling, sleep/wake, backward clocks and restart receipts. Observation
  delivery uses bounded task yields where needed, not timing sleeps.
  Xcode additionally compiles the native controller for passive-window
  configuration, scrolling and appearance/pause/resume focus checks. Those
  native checks require a GUI session and briefly show a fixture HUD, with
  bounded async UI waits. Setup rendering uses fake calendar/login services;
  tests never request real permission or register a login item.
  The HUD accessibility test initializes/restores the assistive-technology
  bridge only in its test process and inspects SwiftUI's bridged AX nodes,
  including the exact pointer target with titles expanded/collapsed. It never
  enables system VoiceOver. Actual speech/navigation still needs owner testing.

Keep calendar access read-only. Store no event-content logs or telemetry. Real
provider identity and production lifecycle/accessibility checks belong to the
integration acceptance tickets. Actual pointer dragging/wheel input, Spaces,
full-screen, display unplugging and VoiceOver still need live acceptance;
geometry and window-configuration tests do not prove that whole matrix.

HUD placement validation for #29 (2026-10-27): deterministic tests cover frozen
expansion, overlapping/missing movement callbacks, display recovery during an
empty refresh, protected-record save failures, and live versus durable restart.
Native tests replay the real view-adapter callbacks and native window-move
notifications, including deferred reflow and failed saves. Real pointer dragging
and physical display unplugging were **not performed** in this agent run; no
hardware-disconnection or physical-input control was available through the test
harness. Those checks still need owner validation and are not implied by the
synthetic results.

Review follow-up regressions also cover relocation notifications arriving before
display reconciliation, repeated or delayed notifications, view completion before
reconciliation, temporary display unavailability, and resizing without changing
the display ID. Both normal and protected storage preserve the compact anchor;
subsequent genuine movement still updates it. Physical notification ordering
remains unverified.

State uses app-local UserDefaults data records. Loading does not rewrite saved
data: malformed preference fields fall back individually, unreadable records
do not reset siblings, and unknown schema versions remain protected from
overwrite. Recovery notices contain record names/reasons, not private event
content. Single-occurrence hide rules are cleaned only when a matching source
snapshot proves the event has ended; unmatched rules remain manually removable.
Series rules persist. Temporary suppression follows an identifiable phase's
edited boundary, restores in its final minute, and does not carry from upcoming
to ongoing. Audio scheduling persists handled cue metadata before playback.

Hide matching deliberately does not trust external identifiers alone after
local-identifier churn or a series split. Detached exceptions are linked only
when a current, unambiguous parent is identifiable. A series action on an
unidentifiable exception reports that limitation and leaves it visible. Provider
rewrites/full sync may require hiding an event again; old unmatched rules remain
available for removal.

Calendar queries overlap the current local day and extend across midnight for
configured HUD/audio horizons. Source notifications are coalesced; wake,
activation, day/timezone/clock changes and query-horizon/selection changes
trigger reconciliation. Display-only and volume edits reuse current calendar
data rather than blanking the menu and refetching.
Access is also rechecked periodically because store notifications are not a
guaranteed revocation callback. Untrusted data is cleared on access/error
transitions, and fetch errors retry with 1–60 second bounded backoff. EventKit
does not expose a Swift error for every provider/sync problem, so an authorized
empty fetch is treated as empty, not invented into an error. Remote freshness
and universal identifier stability are not guaranteed.

## Local signing and permissions

The project uses ad-hoc signing so it builds without a developer account. The
app carries App Sandbox and the calendar entitlement; no network, contacts,
reminders, microphone or notification permissions are enabled. Debug builds
allow debugger attachment. Xcode may additionally re-sign products with test
runner exceptions during `test`; use a normal `build` or Release build when
inspecting the app's ordinary entitlements.

Before real calendar/login acceptance testing, use a stable app path and a
consistent development signing identity if available. Ad-hoc rebuilds are not
a guarantee that macOS will preserve privacy consent or login registration.
Build Release, quit the development copy, and copy
`build/DerivedData/Build/Products/Release/MeetMeet.app` to a stable Applications location before opting
in. Launch that copy; do not enable a temporary test-runner/build-path copy and
then remove it. Test approval, disable, explicit Quit and actual logout/login
manually; these are not established by fake-service tests. Moving the app to
Applications and enabling login are user actions, never build-script side effects.
No provisioning profile, private signing credentials, login registration or
global Xcode setting is added by these commands.
