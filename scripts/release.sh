#!/usr/bin/env bash
# Build, package and sign a distributable release of vidrio, then generate/refresh
# the Sparkle appcast. Mirrors vaho's app/scripts/release.sh.
#
# Usage: scripts/release.sh <short-version>   e.g. scripts/release.sh 1.1
#
# IMPORTANT: dist/ keeps the FULL history of past .zips — generate_appcast needs
# them to compute deltas between versions. Do not delete old zips.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=vidrio
VERSION="${1:-}"
if [ -z "$VERSION" ]; then echo "Usage: $0 <short-version>  (e.g. 1.1)" >&2; exit 1; fi

PLIST=Info.plist
DIST=dist
DOWNLOAD_URL_PREFIX="https://github.com/jorgeMartinez293/$APP-releases/releases/latest/download/"

# 1. Bump versions. CFBundleVersion must increase monotonically (Sparkle compares by it).
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CUR_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "Version: $VERSION (build $NEW_BUILD)"

# 2. Build + sign for distribution.
make bundle

# 3. Zip with ditto (keepParent → archive contains bruma.app at its root; plain zip
# breaks Sparkle's framework symlinks).
mkdir -p "$DIST"
ZIP="$DIST/$APP-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP.app" "$ZIP"
echo "Packaged $ZIP"

# 4. Appcast + deltas. Remove the previous dmg first: generate_appcast treats .dmg as
# an update archive too and would collide with that version's .zip.
rm -f "$DIST/$APP.dmg"
GEN_APPCAST=$(find .build -maxdepth 8 -name generate_appcast -type f -perm -u+x 2>/dev/null | head -1)
if [ -z "$GEN_APPCAST" ]; then echo "ERROR: generate_appcast not found under .build" >&2; exit 1; fi
"$GEN_APPCAST" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$DIST"

# 5. DMG for first-time downloads from the website (stable name).
make dmg
echo "Release ready: $ZIP + $DIST/$APP.dmg + appcast"
