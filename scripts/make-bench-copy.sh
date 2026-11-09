#!/bin/bash
# For checks, screenshots and agents: copies build/Karuta.app to a "Karuta Bench" with its own bundle ID
# (com.trkw.karuta.bench) and prints where it is. Running it next to the real Karuta is safe:
#   - its settings are its own (UserDefaults are per bundle ID), so the real ones are untouched
#   - it registers no global shortcuts (AppDelegate skips them for this bundle ID)
#   - it has no karuta:// URL scheme, so links still go to the real Karuta
# Launch it without taking the screen:  open -g "$(scripts/make-bench-copy.sh)"
# Screen Recording permission is asked for separately (it's a different app to macOS).
set -euo pipefail

source="${1:-build/Karuta.app}"
[ -d "$source" ] || { echo "no $source (run make app first)" >&2; exit 1; }
dest="${TMPDIR:-/tmp}/karuta-bench/Karuta Bench.app"

rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -R "$source" "$dest"
plist="$dest/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.trkw.karuta.bench" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Karuta Bench" "$plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$plist" 2>/dev/null || true
codesign --force --sign - "$dest" >/dev/null 2>&1
echo "$dest"
