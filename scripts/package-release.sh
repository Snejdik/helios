#!/bin/bash
# Packages a Release build for GitHub Releases: DMG, ZIP and SHA256SUMS.txt.
# Local only. It never uploads, tags, launches Helios or touches the helper.
#
#   scripts/package-release.sh [--build] [path/to/Helios.app]
#
# --build makes a fresh Release build into .build/DerivedData-release first.
# Output: .build/dist/<tag>/Helios-<version>.dmg|.zip and SHA256SUMS.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

build=0
if [[ "${1:-}" == "--build" ]]; then build=1; shift; fi
derived=".build/DerivedData-release"
app="${1:-$derived/Build/Products/Release/Helios.app}"

if (( build )); then
  xcodebuild -project Helios.xcodeproj -scheme HeliosApp -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
    -disableAutomaticPackageResolution build -quiet
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -d "$app" ]] || fail "no app at $app (build it or pass --build)"

plist="$app/Contents/Info.plist"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }
version="$(read_key CFBundleShortVersionString "$plist")"
build_number="$(read_key CFBundleVersion "$plist")"
tag="$(read_key HeliosReleaseTag "$plist")"
[[ -n "$version" && -n "$build_number" && -n "$tag" ]] || fail "bundle identity is incomplete"

# The tag core must equal the bundle version, or About and update checks fall back to unavailable.
core="${tag#v}"; core="${core%%-*}"; core="${core%%+*}"
[[ "$core" == "$version" ]] || fail "tag $tag does not match bundle version $version"

helper_plist="$app/Contents/Library/LaunchDaemons/com.snejda.Helios.Daemon.plist"
helper_binary="$app/Contents/Library/HelperTools/HeliosDaemon"
[[ -f "$helper_binary" ]] || fail "helper binary is missing from the bundle"
[[ -f "$helper_plist" ]] || fail "helper launchd plist is missing from the bundle"

archs="$(lipo -archs "$app/Contents/MacOS/Helios")"
[[ "$archs" == "arm64" ]] || fail "app binary is '$archs', expected arm64 only"
codesign --verify --deep --strict "$app" || fail "signature does not verify"
stage="$(mktemp -d "${TMPDIR:-/tmp}/helios-dmg.XXXXXX")"
trap 'hdiutil detach -quiet "$stage/mount" 2>/dev/null; rm -rf "$stage"' EXIT
# The helper carries its own Info.plist inside the binary; it must be the same release.
otool -P "$helper_binary" | tail -n +3 > "$stage/helper-info.plist"
helper_version="$(read_key CFBundleShortVersionString "$stage/helper-info.plist")"
[[ "$helper_version" == "$version" ]] || fail "helper is version '$helper_version', app is $version"
rm "$stage/helper-info.plist"

name="Helios-${tag#v}"
out=".build/dist/$tag"
rm -rf "$out"
mkdir -p "$out"
mkdir "$stage/dmg"
ditto "$app" "$stage/dmg/Helios.app"
ln -s /Applications "$stage/dmg/Applications"
mkdir "$stage/dmg/.background"
swift scripts/dmg-background.swift "$stage"
tiffutil -cathidpicheck "$stage/background.png" "$stage/background@2x.png" \
  -out "$stage/dmg/.background/background.tiff" 2>/dev/null

# A writable image first, so Finder can store the window layout (.DS_Store) on it.
hdiutil create -quiet -volname "Helios" -srcfolder "$stage/dmg" -fs HFS+ -format UDRW -ov "$stage/rw.dmg"
mountpoint="$stage/mount"
mkdir "$mountpoint"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$mountpoint" "$stage/rw.dmg"
# Finder lays out the window: Helios on the left, Applications on the right, the arrow
# background between them. Needs permission to control Finder; without it the DMG stays plain.
# The window is found by its target, never by "front window", so another open Finder window
# cannot receive the layout. .background is hidden and parked outside the window, so it stays
# out of sight even when Finder shows hidden files.
chflags hidden "$mountpoint/.background"
layout="$(osascript <<OSA 2>&1
tell application "Finder"
  set volumeFolder to (POSIX file "$mountpoint" as alias)
  open volumeFolder
  delay 1
  set found to 0
  set windowNumber to 0
  repeat with candidate in (get every Finder window)
    set windowNumber to windowNumber + 1
    try
      if (((get target of candidate) as alias) as text) is (volumeFolder as text) then set found to windowNumber
    end try
  end repeat
  if found is 0 then error "window not found"
  set theWindow to Finder window found
  set current view of theWindow to icon view
  try
    set toolbar visible of theWindow to false
  end try
  try
    set statusbar visible of theWindow to false
  end try
  try
    set sidebar width of theWindow to 0
  end try
  set bounds of theWindow to {200, 120, 800, 548}
  set viewOptions to icon view options of theWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 112
  set text size of viewOptions to 13
  set background picture of viewOptions to (POSIX file "$mountpoint/.background/background.tiff" as alias)
  set position of item "Helios.app" of volumeFolder to {150, 185}
  set position of item "Applications" of volumeFolder to {450, 185}
  try
    set position of item ".background" of volumeFolder to {900, 900}
  end try
  update volumeFolder without registering applications
  delay 1
  set placed to (position of item "Helios.app" of volumeFolder as text) & "|" & (position of item "Applications" of volumeFolder as text)
  close theWindow
  return placed
end tell
OSA
)" || true
if [[ "$layout" == "150, 185|450, 185" || "$layout" == "150185|450185" ]]; then
  styled="yes"
else
  styled="no (Finder layout failed: $layout); the DMG is plain"
fi
sync
rm -rf "$mountpoint/.fseventsd"
hdiutil detach -quiet "$mountpoint"
hdiutil convert -quiet "$stage/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$out/$name.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$name.zip"
(cd "$out" && shasum -a 256 "$name.dmg" "$name.zip" > SHA256SUMS.txt)

# Check the packages before anyone downloads them.
hdiutil verify -quiet "$out/$name.dmg" || fail "DMG verification failed"
unzip -tq "$out/$name.zip" >/dev/null || fail "ZIP verification failed"
(cd "$out" && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || fail "checksums do not match"

echo "PASS packaged $tag (version $version, build $build_number, $archs; DMG window styled: $styled)"
ls -l "$out"
channel=""
if [[ "$tag" == "v$version-"* ]]; then
  channel=" $(sed -E 's/^beta\.([0-9]+)$/Beta \1/; s/^prebeta\.([0-9]+)$/Pre-beta \1/' <<<"${tag#v$version-}")"
fi
prerelease="no"; [[ -n "$channel" ]] && prerelease="yes"
echo "GitHub release title: Helios $version$channel (pre-release: $prerelease)"
