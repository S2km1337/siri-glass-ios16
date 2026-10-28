#!/bin/bash
# Builds SiriGlassHost.framework (arm64e), stages it into the tweak and
# packages the deb. Bump Version in src/SiriGlassTweak/control first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/src/SiriGlassHost"
# Stop here if the framework fails to build: packaging would otherwise ship
# the previous framework (this happened once and could crash SpringBoard).
LOG=$(xcodebuild -scheme SiriGlassHost -destination 'generic/platform=iOS' -sdk iphoneos \
  -configuration Release -derivedDataPath /tmp/sghost ARCHS=arm64e ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build 2>&1) || true
echo "$LOG" | grep -E "error:" || true
echo "$LOG" | grep -q "BUILD SUCCEEDED" || { echo "SiriGlassHost build failed"; exit 1; }
FW=/tmp/sghost/Build/Products/Release-iphoneos/PackageFrameworks/SiriGlassHost.framework

# The Preferences bundle is a separate Theos bundle; stage it into the tweak's
# layout so the one deb carries both.
cd "$ROOT/src/SiriGlassTweak/SiriGlassPrefs"
make clean >/dev/null 2>&1 || true
PREFS_LOG=/tmp/sgprefs-build.log
make stage > "$PREFS_LOG" 2>&1 || { cat "$PREFS_LOG"; echo "SiriGlassPrefs bundle build failed"; exit 1; }
grep -E "error|Making stage" "$PREFS_LOG" || true
PREFS="$ROOT/src/SiriGlassTweak/SiriGlassPrefs/.theos/_/Library/PreferenceBundles/SiriGlassPrefs.bundle"
[ -d "$PREFS" ] || { echo "SiriGlassPrefs bundle build failed"; exit 1; }
mkdir -p "$ROOT/src/SiriGlassTweak/layout/Library/PreferenceBundles"
cp -R "$PREFS" "$ROOT/src/SiriGlassTweak/layout/Library/PreferenceBundles/"

cd "$ROOT/src/SiriGlassTweak"
rm -rf layout/Library/Frameworks/SiriGlassHost.framework
mkdir -p layout/Library/Frameworks
cp -R "$FW" layout/Library/Frameworks/
ldid -S layout/Library/Frameworks/SiriGlassHost.framework/SiriGlassHost
export THEOS="${THEOS:-$HOME/theos-roothide}"
make package | grep -E "error|building package"
ls -t packages/*.deb | head -1
