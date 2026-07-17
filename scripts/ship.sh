#!/usr/bin/env bash
# One-command release for vidrio: build + package + sign + appcast, then publish
# EVERYTHING. Mirrors vaho's app/scripts/ship.sh.
#
# Usage: scripts/ship.sh <short-version>      e.g. scripts/ship.sh 1.1
#
#   1. release.sh <version>  → bumps version, builds, signs, zips, deltas, appcast, dmg.
#   2. Source repo: commit the version bump, tag v<version>, push main + tag.
#   3. Release repo (jorgeMartinez293/vidrio-releases): create GitHub Release and
#      upload the new .zip, .dmg and .delta assets.
#   4. Publish dist/appcast.xml to the release repo's gh-pages (the SUFeedURL host)
#      AND main.
#   5. Verify the live appcast serves the new build before declaring success.
#
# Requirements: `gh` authenticated and the private EdDSA key in your Keychain
# (the same one vaho uses — one key signs the whole family).
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR="$(pwd)"

APP=vidrio
VERSION="${1:-}"
if [ -z "$VERSION" ]; then echo "Usage: $0 <short-version>  (e.g. 1.1)" >&2; exit 1; fi

RELEASE_REPO="jorgeMartinez293/$APP-releases"
DIST="$APP_DIR/dist"
PLIST="$APP_DIR/Info.plist"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
gh auth status >/dev/null 2>&1 || { echo "ERROR: run 'gh auth login' first." >&2; exit 1; }
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "ERROR: tag v$VERSION already exists locally. Bump to a new version." >&2; exit 1
fi

# ── 1. Build + package + appcast + dmg ─────────────────────────────────────────
say "Building & packaging $APP v$VERSION"
"$APP_DIR/scripts/release.sh" "$VERSION"

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
ZIP="$DIST/$APP-$VERSION.zip"
DMG="$DIST/$APP.dmg"
[ -f "$ZIP" ] || { echo "ERROR: $ZIP missing after build." >&2; exit 1; }
[ -f "$DMG" ] || { echo "ERROR: $DMG missing after build." >&2; exit 1; }
DELTAS=("$DIST/$APP$BUILD"-*.delta)
[ -e "${DELTAS[0]}" ] || DELTAS=()   # first release ever has no delta

# ── 2. Commit + tag + push source repo ─────────────────────────────────────────
say "Committing & tagging source repo"
git add -A
git commit -q -m "release: v$VERSION" || echo "(nothing new to commit)"
git tag "v$VERSION"
git push origin HEAD
git push origin "v$VERSION"

# ── 3. GitHub Release on the release repo ──────────────────────────────────────
say "Publishing GitHub Release v$VERSION on $RELEASE_REPO"
# macOS bash 3.2 + set -u: expanding an empty array errors; guard the deltas.
ASSETS=("$ZIP" "$DMG" ${DELTAS[@]+"${DELTAS[@]}"})
if gh release view "v$VERSION" -R "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "${ASSETS[@]}" -R "$RELEASE_REPO" --clobber
else
  gh release create "v$VERSION" "${ASSETS[@]}" -R "$RELEASE_REPO" \
    --title "v$VERSION" --notes "$APP $VERSION"
fi

# ── 4. Publish appcast to gh-pages (the SUFeedURL host) ─────────────────────────
say "Publishing appcast.xml to $RELEASE_REPO (gh-pages + main)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$RELEASE_REPO" "$WORK" -- -q
cd "$WORK"
git config user.email "$(cd "$APP_DIR" && git config user.email)"
git config user.name  "$(cd "$APP_DIR" && git config user.name)"
for BR in gh-pages main; do
  git checkout -q "$BR"
  cp "$DIST/appcast.xml" appcast.xml
  # `git diff --quiet` misses a brand-new (untracked) appcast.xml — stage first
  # and compare the index, so the very first publication also gets pushed.
  git add appcast.xml
  if ! git diff --cached --quiet; then
    git commit -q -m "Publish v$VERSION appcast (build $BUILD)"
    git push -q origin "$BR"
    echo "  pushed appcast → $BR"
  else
    echo "  $BR already up to date"
  fi
done
cd "$APP_DIR"

# ── 5. Verify the live appcast serves the new build ────────────────────────────
say "Verifying live appcast (GitHub Pages may take up to ~1 min to rebuild)"
FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST")
for i in $(seq 1 12); do
  LIVE=$(curl -s -H 'Cache-Control: no-cache' "$FEED?nocache=$RANDOM" || true)
  if printf '%s' "$LIVE" | grep -q "<sparkle:version>$BUILD</sparkle:version>"; then
    echo "  ✅ Live appcast advertises build $BUILD (v$VERSION)."
    for f in "$APP-$VERSION.zip" "$APP.dmg"; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -L \
        "https://github.com/$RELEASE_REPO/releases/latest/download/$f")
      echo "  $f → HTTP $code"
    done
    say "DONE — $APP v$VERSION is live."
    exit 0
  fi
  echo "  attempt $i/12: not live yet, waiting 10s…"; sleep 10
done
echo "WARNING: live appcast did not show build $BUILD within ~2 min." >&2
echo "Assets and git are pushed; Pages may just be slow. Re-check: $FEED" >&2
exit 1
