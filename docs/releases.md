# Releasing Meet Meet

Releases are Apple silicon-only DMGs with a minimum deployment target of macOS
26.0. They intentionally use ad-hoc signing, without Developer ID certificates,
Apple notarization, or paid Apple credentials. See [installation.md](installation.md)
for the resulting security warnings and permission caveats.

## Prepare a release

1. Choose a new `MAJOR.MINOR.PATCH` version. No prerelease suffixes are currently
   supported. Do not reuse a published version/tag or replace its binaries.
2. Add `releases/VERSION.md` with user-facing release notes and the installation
   warning. Update the project's `MARKETING_VERSION` for subsequent development
   as appropriate; packaging explicitly sets the version from the tag.
3. Run tests, review changes, and commit. Keep the bundle identifier
   `dev.nnerik.meetmeet` unchanged to preserve local settings.
4. Ensure media and code are licensed for redistribution. The root MIT license
   currently covers the source and all bundled artwork/sounds, as confirmed by
   the owner. No credentials or private calendar data should be committed.

## Local packaging

Requires an Apple silicon Mac, macOS 26+, full Xcode selected, and a GUI session
for the native HUD tests. The app has been tested locally with Xcode 27.1; CI
uses the explicitly selected Xcode 26.6 on GitHub's `macos-26` runner.

```sh
make release VERSION=0.1.0
```

The script requires a clean committed tree and release notes. It runs the core
and native tests, builds arm64 Release with minimum macOS 26.0, and stamps the
requested app version and a build number derived from the Git commit count.
It includes the MIT license in the app, re-signs ad-hoc with sandbox/calendar
entitlements and hardened runtime, then creates a compressed DMG containing:

- `MeetMeet.app` and an Applications shortcut;
- `LICENSE`, `INSTALL.md` and `BUILD-INFO.txt` with source revision/toolchain.

It verifies architectures, version/build/minimum OS, bundle ID, media, license,
signature and entitlements, then mounts the DMG read-only, copies the app into
a temporary install location, and verifies that copy. It does not launch the
production app or request real calendar access. Outputs are in
`build/releases/VERSION/`: DMG, SHA-256 checksum, build information and notes.
Existing DMG output is not overwritten. Temporary build/mount directories are
cleaned up on exit. Build and packaging checks are not a Gatekeeper approval.

## Publish with GitHub Actions

The repository must allow GitHub Actions and the workflow's `contents: write`
permission. No additional secrets are needed: the workflow uses `GITHUB_TOKEN`.
Private repositories may consume paid/included Actions minutes; public standard
hosted-runner usage follows GitHub's plan rules.

From a clean, reviewed commit on main:

```sh
git push origin main
git tag -a v0.1.0 -m "Meet Meet 0.1.0"
git push origin v0.1.0
```

The tag workflow checks out full history, selects Xcode, runs the same packaging
script, creates a draft release, uploads the DMG/checksum/build information, then
publishes it. A failed build cannot publish a release; failed uploads leave a
draft. Existing releases/assets are never silently overwritten. Inspect a failed
draft before deleting it and rerunning the workflow; do not move public tags.

Watch the workflow under **Actions → Release**. Check its version, source
revision, downloadable assets and notes under **Releases**. A private repository's
releases remain private until its visibility changes; publication does not itself
change repository visibility. GitHub automatically supplies tagged source archives.

The workflow also supports **Run workflow** with a version input for validation
without publishing. Failed native runs print their test summary and retain the
Xcode test results for seven days so CI-only assertions can be investigated.

If CI is unavailable, package locally from the exact clean tagged commit and use
`gh release create --verify-tag --draft`, upload the three artifacts, then publish
only after inspecting them. Never publish build output from a different revision.

## Before making the repository public

The owner changes visibility in GitHub settings. Review the full Git history,
issues and other repository content for credentials/private material first;
adding a license is not a security audit. Confirm the public release and install
links work without authentication afterward.

## Smoke-test a downloaded release

On a separate Mac or fresh account, download through a browser so quarantine is
preserved. Check the documented Gatekeeper override, installation into
Applications, calendar authorization/selection, settings retention after upgrade,
and launch-at-login approval. Do not clear quarantine or disable Gatekeeper to
make the acceptance test pass. Permissions may need reauthorization on each
ad-hoc-signed update; this is an accepted distribution limitation.
