# Install Meet Meet

Requires an Apple silicon Mac (M1 or newer) running macOS 26 or newer.
Intel Macs and older macOS versions are not supported.

## Download and install

1. Download the `MeetMeet-VERSION-arm64.dmg` asset from the
   [latest GitHub release](https://github.com/nnerik/meet-meet/releases/latest).
   GitHub's automatic "Source code" downloads are not the app.
2. Open the DMG and drag **MeetMeet.app** onto **Applications**.
3. Eject the DMG and launch Meet Meet from Applications. Do not run it directly
   from the disk image; use a stable install location for login launch.
4. Follow setup to allow calendar access and select calendars. Meet Meet is a
   menu bar app: look for its calendar icon, not a Dock icon.

## macOS security warning

These releases are **ad-hoc signed, not Developer ID signed or notarized**.
macOS may block the first launch because it cannot verify the developer.

Only proceed if you trust this project and downloaded the release from its
official GitHub repository:

1. Attempt to open the installed app, then dismiss the security warning.
2. Open **System Settings → Privacy & Security**.
3. Find the message about Meet Meet and choose **Open Anyway**, then confirm
   and authenticate if requested.

The exact wording varies by macOS version. Organization-managed Macs may not
allow this override. Do not disable Gatekeeper or other system-wide security
protections. A warning that the app is damaged or has been modified can also
indicate a corrupt download: verify the checksum and download it again rather
than bypassing integrity checks.

## Verify a download (optional)

Download the matching `.dmg.sha256` asset into the same folder as the DMG, then
run this in Terminal from that folder (replace the version):

```sh
shasum -a 256 -c MeetMeet-0.1.0-arm64.dmg.sha256
```

It should report `OK`. This detects corruption, not an independently trusted
publisher: the DMG and checksum are hosted together.

## Update

There is no automatic updater. Choose **Quit Meet Meet** from its menu, download
the newer DMG, and replace the copy in Applications. Launch the replacement.

Settings should remain saved because the bundle identifier and local storage
are preserved. With ad-hoc signing, macOS may require the security override and
calendar permission again after each update. If calendar access appears enabled
but does not work, quit Meet Meet, toggle its access off/on in **System Settings
→ Privacy & Security → Calendars**, and relaunch. Use **Settings → Calendars →
Allow Calendar Access** if permission is not yet granted. Recheck **Settings →
General → Launch at login** after updating; macOS may require approval again.

Calendar permission behavior depends on macOS. Release packaging verifies the
bundle and its metadata, but does not prove permission retention or first-launch
Gatekeeper behavior on a different Mac.

## License

The source code and bundled artwork and sounds are available under the
[MIT License](https://github.com/nnerik/meet-meet/blob/main/LICENSE).
