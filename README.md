# Meet Meet

A native macOS menu bar utility for upcoming and ongoing meeting countdowns.
The approved behavior is in [`spec.md`](spec.md); implementation is tracked in
the [MVP backlog](https://github.com/nnerik/meet-meet/issues/12).

## Current status

The app currently has a sandboxed agent foundation, persistent calendar menu,
editable General/Audio preferences, versioned local state and testable core
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
Hover to reveal all titles, drag to move the entire stack, or scroll when rows
exceed screen height. New/restored rows reveal titles for three elapsed seconds;
reordering alone does not. The stack grows upward from its lower-right anchor.
Dragged position is saved relative to the display's usable lower-right corner,
so resizing the display preserves its edge offsets, and disconnected
displays recover onto the primary usable area. Spaces/full-screen visibility is
best-effort where macOS permits, never a reason to switch Spaces or take focus.
No stack is shown without an eligible ongoing meeting or upcoming meeting inside
the configured lead time.

**Settings → Audio** offers independent start/end cues (both off by default),
bundled or system-sound selection, Preview and app-local volume. The bundled
`media/meet-meet.mp3` and `media/wrap-wrap.mp3` are the start/end defaults for new
settings; existing saved sound choices are preserved. Xcode copies these files
into the app bundle, so playback does not depend on the source folder at runtime.
Zero-minute offsets play
at the boundary; end warnings before a short meeting's start are skipped.
Only future cues are armed after startup, wake, pause, access loss or settings
changes. Coincident cues play once (start wins), with all receipts persisted
before playback. Handled cues do not replay after rescheduling or clock reversal.
Unreadable safety records disable automatic sounds rather than risking repeats;
Preview remains available. Playback errors appear in Audio settings. Playback is
best-effort while the app runs; mute/output changes and sleep may prevent sound.
No user-file import is supported and system volume is never changed.
Scheduled cues also wiggle each corresponding visible HUD icon five times with
a one-second pause between repeats, unless Reduce Motion is enabled. This never
reveals a hidden countdown or retains an ended meeting. Preview does not animate
the HUD; coincident cues animate all corresponding visible icons.

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
```

Or open `MeetMeet.xcodeproj`, select **MeetMeet**, and Run/Test. Settings and
Quit are available in the calendar menu; Finder/Spotlight reopening opens the
settings shell. A menu bar app has no Dock or Cmd+Tab entry.

Build output goes to ignored `build/DerivedData`. `make CONFIGURATION=Release
build` builds Release. Quit the running app before rebuilding to inspect a new
version. The target architecture defaults to this Mac; override `DESTINATION`
when explicitly testing a different supported architecture.

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
  SwiftUI rows, native dragging/scrolling and display recovery. Pure
  `HUDLayoutPolicy` tests placement/clamping/overflow without windows;
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
