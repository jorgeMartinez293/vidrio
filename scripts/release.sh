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

# 0. Preflight. Every credential is checked UP FRONT, because the expensive steps (universal
# build, then a notarization round-trip that can sit in Apple's queue for over an hour) all
# happen before the appcast is signed at the very end. Failing there wastes the whole run.
#
# The EdDSA check matters most. Reading that key needs Keychain authorization, which needs a
# GUI prompt — so on a Mac in dark wake (display asleep, unattended, SSH) it fails with
# -25320 "In dark wake, no UI possible". Sparkle misreports that as "Private key for account
# ed25519 not found in the Keychain. Please run the generate_keys tool", which is dangerously
# wrong: new keys orphan every installed user, whose app only trusts the OLD public key.
# Never do that — wake the Mac and rerun. Output goes to /dev/null so the private key never
# lands in a log. NOTE: the whole vaho family shares ONE EdDSA key, so regenerating here
# would break bruma, vidrio, sereno AND vaho at once.
if ! security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w >/dev/null 2>&1; then
  echo "ERROR: cannot read the Sparkle EdDSA private key from the Keychain." >&2
  echo "       The key is almost certainly still there — wake the Mac (real GUI session," >&2
  echo "       display on), approve the Keychain prompt, and rerun." >&2
  echo "       Do NOT run generate_keys: new keys break every install, across all 4 apps." >&2
  exit 1
fi

if [ "${NOTARIZE:-1}" = "1" ]; then
  security find-identity -v -p codesigning 2>/dev/null | grep -v CSSMERR_TP_CERT_REVOKED \
    | grep -q "Developer ID Application" || {
      echo "ERROR: no valid Developer ID Application identity — cannot notarize." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-vaho-notary}" >/dev/null 2>&1 || {
    echo "ERROR: notarytool profile '${NOTARY_PROFILE:-vaho-notary}' missing or invalid." >&2
    echo "       Create it with: xcrun notarytool store-credentials" >&2; exit 1; }
fi

# 1. Bump versions. CFBundleVersion must increase monotonically (Sparkle compares by it).
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
NEW_BUILD=$((CUR_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "Version: $VERSION (build $NEW_BUILD)"

# 2. Build + sign for distribution.
make bundle

# 2b. Notarize + staple the .app. Must happen BEFORE the zip and the dmg below, so both carry
# a bundle with the ticket already attached and first launch works offline.
# NOTARIZE=0 skips it — local test builds only; never publish an unnotarized build.
if [ "${NOTARIZE:-1}" = "1" ]; then
  make notarize-app
else
  echo "WARNING: skipping notarization (NOTARIZE=0) — do NOT publish this build."
fi

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
# The dmg is downloaded as its own file, so Gatekeeper checks it separately from the app
# inside — it needs its own stapled ticket.
if [ "${NOTARIZE:-1}" = "1" ]; then make notarize-dmg; fi
echo "Release ready: $ZIP + $DIST/$APP.dmg + appcast"
