#!/bin/zsh
# Build, sign and publish a release of Flowriter.
#
#   scripts/release.sh [X.Y.Z]      # version defaults to the VERSION file; given → written to VERSION
#
# Flowriter never updates itself (ForkIdentity.updatesEnabled is false), so a release is a signed
# app on GitHub. The Sparkle appcast and website steps run only when SITE_DIR is set.
#
# 1. builds "Flowriter.app" (bundle id app.flowriter.Flowriter, from bundle.sh), version from VERSION,
#    build number = git commit count; throttled with slowbuild when it is installed
# 2. signs it: ad-hoc, or with DEVELOPER_ID (hardened runtime) and, when
#    NOTARY_PROFILE is set too, notarizes + staples before zipping
# 3. zips it (ditto -c -k --keepParent) as Flowriter-X.Y.Z.zip
# 4. creates the GitHub release vX.Y.Z on $GH_REPO with the zip attached
# 5. only with SITE_DIR set: EdDSA-signs the zip (Sparkle sign_update, key account
#    $SPARKLE_ACCOUNT in the login keychain), prepends the release to the appcast (history kept)
#    at $SITE_DIR/public/flowriter/appcast.xml, and copies the release notes next to it
# 6. only with SITE_DIR and DEPLOY_CMD set: commits the site and runs DEPLOY_CMD there
#
# Env: DEVELOPER_ID="Developer ID Application: Name (TEAMID)", NOTARY_PROFILE=<notarytool keychain profile>,
#      NOTES_FILE=<markdown notes> (default: release-notes/X.Y.Z.md if present),
#      GH_REPO (default jonnilundy/flowriter), JOBS (default 4),
#      SITE_DIR (no default: unset skips the appcast and site steps), SPARKLE_ACCOUNT (default flowriter),
#      DEPLOY_CMD (shell command that publishes the site), THROTTLE (default: slowbuild if installed),
#      DRY_RUN=1 (build + sign + zip into build/release only; no GitHub, no site writes).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
GH_REPO=${GH_REPO:-jonnilundy/flowriter}
SITE_DIR=${SITE_DIR:-}   # no default: the fork has no update site
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-flowriter}
SPARKLE_BIN="$ROOT/.build-release/artifacts/sparkle/Sparkle/bin"

if [[ $# -ge 1 ]]; then
  [[ "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "version must be X.Y.Z" >&2; exit 64; }
  echo "$1" > "$ROOT/VERSION"
fi
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
TAG="v$VERSION"
OUT="$ROOT/build/release"
APP_NAME=Flowriter
APP="$OUT/$APP_NAME.app"
ZIP="$OUT/Flowriter-$VERSION.zip"
URL="https://github.com/$GH_REPO/releases/download/$TAG/${ZIP:t}"

if [[ -z "${DRY_RUN:-}" ]]; then
  gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1 && { echo "release $TAG already exists on $GH_REPO" >&2; exit 1; }
  [[ -z "$SITE_DIR" || -d "$SITE_DIR/public" ]] || { echo "website repo not found: $SITE_DIR" >&2; exit 1; }
fi
if [[ -z "$SITE_DIR" ]]; then
  echo "SITE_DIR is not set: skipping the Sparkle appcast and the website steps (Flowriter does not update itself)." >&2
fi
# throttle the build when slowbuild is installed; THROTTLE overrides (empty string: none)
THROTTLE=${THROTTLE-$(command -v slowbuild || true)}
[[ -n "$(git status --porcelain --untracked-files=no)" ]] && echo "warning: uncommitted changes are included in this build" >&2

# 1-2. build + sign (bundle.sh → sign.sh uses DEVELOPER_ID when set)
rm -rf "$OUT"; mkdir -p "$OUT"
APP_NAME="$APP_NAME" APP="$APP" INSTALL=0 THROTTLE="$THROTTLE" JOBS=${JOBS:-4} "$ROOT/scripts/bundle.sh"
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")

NOTARIZED=0
if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose "$APP"
  rm -f "$OUT/notarize.zip"
  NOTARIZED=1
elif [[ -n "${DEVELOPER_ID:-}" ]]; then
  echo "warning: DEVELOPER_ID without NOTARY_PROFILE: signed but not notarized" >&2
fi

# 3. zip
ditto -c -k --keepParent "$APP" "$ZIP"
LENGTH=$(stat -f%z "$ZIP")

# release notes
NOTES_MD="$OUT/notes.md"
if [[ -n "${NOTES_FILE:-}" ]]; then cp "$NOTES_FILE" "$NOTES_MD"
elif [[ -f "$ROOT/release-notes/$VERSION.md" ]]; then cp "$ROOT/release-notes/$VERSION.md" "$NOTES_MD"
else echo "Flowriter $VERSION." > "$NOTES_MD"; fi
GH_NOTES="$OUT/gh-notes.md"
cp "$NOTES_MD" "$GH_NOTES"
if [[ $NOTARIZED == 0 ]]; then
  printf '\n**Not notarized yet: on first launch right-click the app → Open.**\n' >> "$GH_NOTES"
fi
printf '\nDownload `%s`, unzip, and move **Flowriter.app** to /Applications. Flowriter does not update itself: download new versions from the releases page.\n' "${ZIP:t}" >> "$GH_NOTES"

# 5a. appcast, only with SITE_DIR (history kept: start from the published one)
APPCAST=""
if [[ -n "$SITE_DIR" ]]; then
  [[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle tools missing: $SPARKLE_BIN" >&2; exit 1; }
  SIG=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" -p "$ZIP")
  "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" --verify "$ZIP" "$SIG"
  APPCAST="$OUT/appcast.xml"
  SITE_APPCAST="$SITE_DIR/public/flowriter/appcast.xml"
  [[ -f "$SITE_APPCAST" ]] && cp "$SITE_APPCAST" "$APPCAST"
  python3 "$ROOT/scripts/appcast.py" "$APPCAST" --version "$VERSION" --build "$BUILD" --url "$URL" \
    --ed-signature "$SIG" --length "$LENGTH" --notes-file "$NOTES_MD"
  xmllint --noout "$APPCAST"
fi

if [[ -n "${DRY_RUN:-}" ]]; then
  echo "dry run: $ZIP ($LENGTH bytes, build $BUILD)${APPCAST:+, $APPCAST}"; exit 0
fi

# 4. GitHub release
gh release create "$TAG" "$ZIP" --repo "$GH_REPO" --title "Flowriter $VERSION" --notes-file "$GH_NOTES"
echo "released $TAG (build $BUILD): https://github.com/$GH_REPO/releases/tag/$TAG"
[[ -z "$SITE_DIR" ]] && exit 0

# 5b. website files
mkdir -p "$SITE_DIR/public/flowriter/release-notes"
cp "$APPCAST" "$SITE_APPCAST"
cp "$NOTES_MD" "$SITE_DIR/public/flowriter/release-notes/$VERSION.md"
[[ -z "${DEPLOY_CMD:-}" ]] && { echo "appcast written: $SITE_APPCAST (DEPLOY_CMD not set: deploy the website to publish it)"; exit 0; }

# 6. publish: commit the site, run DEPLOY_CMD there
(
  cd "$SITE_DIR"
  git add public/flowriter && git commit -qm "Flowriter $VERSION appcast" || true
  eval "$DEPLOY_CMD"
)
