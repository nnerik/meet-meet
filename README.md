# Meet Meet

A native macOS menu bar utility for upcoming and ongoing meeting countdowns.
The approved behavior is in [`spec.md`](spec.md); implementation is tracked in
the [MVP backlog](https://github.com/nnerik/meet-meet/issues/12).

## Current status

The first implementation slice is the sandboxed agent foundation: persistent
calendar menu, a SwiftUI settings shell, pure meeting snapshots and testable
calendar/clock/audio/storage boundaries. Calendar reading, countdown HUDs,
preferences and alerts are not implemented yet. This app does not request
calendar permission at startup or load prototype/dummy meetings.

## Develop

Requires macOS 26+ and full Xcode selected as the active developer tools.
Verified with Xcode 27.1 (27A9275), Swift 6.4 and macOS SDK 27.0. The deployment
target is macOS 26.0; the SDK version is not the deployment target.

```sh
make build       # Build the app with local ad-hoc signing
make run         # Build and open the persistent calendar menu
make test        # Deterministic core tests via Swift Package Manager
make test-xcode  # The same tests through the shared Xcode scheme
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
  and testable time/calendar/audio/state boundaries. No AppKit or EventKit.
- `Tests/MeetMeetCoreTests/`: Swift Testing cases, shared by SwiftPM and Xcode;
  no real calendars, permission prompts, network requests or timer waits.

Keep calendar access read-only. Store no event-content logs or telemetry. Real
provider identity and production lifecycle/accessibility checks belong to the
integration acceptance tickets, not to this initial scaffold.

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
No provisioning profile, private signing credentials, login registration or
global Xcode setting is added by these commands.
