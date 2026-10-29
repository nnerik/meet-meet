#!/bin/bash
set -euo pipefail

fail() { echo "Release error: $*" >&2; exit 1; }

version="${1:-}"
[[ $# == 1 && "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail "Usage: bash scripts/package-release.sh MAJOR.MINOR.PATCH"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail "Use an Apple silicon Mac."

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[[ -z "$(git status --porcelain)" ]] || fail "Commit or otherwise resolve working-tree changes before packaging."
[[ -f "releases/$version.md" ]] || fail "Add releases/$version.md before packaging."
if [[ "${GITHUB_REF_TYPE:-}" == tag ]]; then
    [[ "$GITHUB_REF_NAME" == "v$version" ]] || fail "Version does not match the release tag."
fi

output="$root/build/releases/$version"
name="MeetMeet-$version-arm64.dmg"
[[ ! -e "$output/$name" ]] || fail "$output/$name already exists; do not replace published binaries."
mkdir -p "$root/build" "$output"
work="$(mktemp -d "$root/build/release-work.XXXXXX")"
mounted=false
cleanup() {
    if $mounted; then hdiutil detach "$work/mount" -quiet || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

revision="$(git rev-parse HEAD)"
build_number="$(git rev-list --count HEAD)"

make test
make test-xcode DESTINATION=platform=macOS,arch=arm64
xcodebuild -quiet -project MeetMeet.xcodeproj -scheme MeetMeet \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$work/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=26.0 \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build

mkdir -p "$work/staging"
app="$work/staging/MeetMeet.app"
ditto "$work/DerivedData/Build/Products/Release/MeetMeet.app" "$app"
cp LICENSE "$app/Contents/Resources/LICENSE"
codesign --force --sign - --options runtime --timestamp=none \
    --entitlements App/MeetMeet.entitlements "$app"

verify_app() {
    local app="$1"
    local plist="$app/Contents/Info.plist"
    codesign --verify --deep --strict "$app"
    [[ "$(lipo -archs "$app/Contents/MacOS/MeetMeet")" == arm64 ]] || fail "Unexpected architectures."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == dev.nnerik.meetmeet ]] || fail "Bundle ID changed."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] || fail "Version mismatch."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]] || fail "Build number mismatch."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 26.0 ]] || fail "Minimum macOS version changed."
    codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2>/dev/null
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$work/entitlements.plist")" == true ]] || fail "Sandbox missing."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.personal-information.calendars' "$work/entitlements.plist")" == true ]] || fail "Calendar entitlement missing."
    codesign -dv "$app" 2> "$work/signature.txt"
    grep -q 'Signature=adhoc' "$work/signature.txt" || fail "Expected ad-hoc signing."
    grep -q 'flags=.*runtime' "$work/signature.txt" || fail "Hardened runtime missing."
    cmp LICENSE "$app/Contents/Resources/LICENSE"
    for resource in meet-meet.png wrap-wrap.png meet-meet.mp3 wrap-wrap.mp3; do
        [[ -s "$app/Contents/Resources/$resource" ]] || fail "Missing bundled media: $resource"
    done
}
verify_app "$app"

cp LICENSE "$work/staging/LICENSE"
cp docs/installation.md "$work/staging/INSTALL.md"
{
    echo "Meet Meet $version (build $build_number)"
    echo "Source: https://github.com/nnerik/meet-meet/commit/$revision"
    echo "Architecture: arm64; minimum macOS: 26.0"
    echo "Signing: ad-hoc; not Developer ID signed; not notarized"
    xcodebuild -version
} > "$work/staging/BUILD-INFO.txt"
ln -s /Applications "$work/staging/Applications"
hdiutil create -quiet -volname "Meet Meet $version" -srcfolder "$work/staging" \
    -format UDZO -ov "$work/$name"
hdiutil verify "$work/$name"

# Exercise the actual download/install path without launching or requesting access.
mkdir "$work/mount"
hdiutil attach "$work/$name" -readonly -nobrowse -mountpoint "$work/mount" -quiet
mounted=true
[[ "$(readlink "$work/mount/Applications")" == /Applications ]] || fail "Applications shortcut missing."
mkdir "$work/installed"
ditto "$work/mount/MeetMeet.app" "$work/installed/MeetMeet.app"
verify_app "$work/installed/MeetMeet.app"
hdiutil detach "$work/mount" -quiet
mounted=false

mv "$work/$name" "$output/$name"
cp "$work/staging/BUILD-INFO.txt" "$output/BUILD-INFO.txt"
cp "releases/$version.md" "$output/RELEASE-NOTES.md"
(
    cd "$output"
    shasum -a 256 "$name" > "$name.sha256"
    shasum -a 256 -c "$name.sha256"
    # GitHub's /releases/latest/download/ URL resolves a stable asset name.
    cp "$name" MeetMeet-latest-arm64.dmg
    shasum -a 256 MeetMeet-latest-arm64.dmg > MeetMeet-latest-arm64.dmg.sha256
    shasum -a 256 -c MeetMeet-latest-arm64.dmg.sha256
)
echo "Release artifacts: $output"
