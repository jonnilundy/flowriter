#!/bin/zsh
# Cut a Flowriter release: scripts/release.sh X.Y.Z [--publish] [--notes-file FILE]
#
#   1. writes X.Y.Z to VERSION, builds Flowriter.app (bundle.sh; build number = git commit count,
#      which Sparkle compares) and signs it ad hoc (sign.sh), or with DEVELOPER_ID when set
#      (and notarizes + staples when NOTARY_PROFILE is set too)
#   2. zips it (ditto) as Flowriter-X.Y.Z.zip and signs the zip with the Sparkle EdDSA key
#   3. prepends an item for the zip to appcast.xml at the repo root (history kept)
#
# The default is a dry run: everything lands in build/release and the working tree (VERSION,
# appcast.xml), nothing is committed or published, and the git and gh commands are printed.
# --publish runs them: commit "Release X.Y.Z", tag vX.Y.Z, push the tag, create the GitHub release
# with the zip attached, then push main. The tag and release go first, so the appcast on main
# never points at a missing zip. Needs a clean tree on main, and gh.
#
# Installed apps read https://raw.githubusercontent.com/jonnilundy/flowriter/main/appcast.xml once
# a day (raw URLs cache for about five minutes) and install the update when they quit.
#
# The signing key lives in 1Password: item "Flowriter Sparkle EdDSA key", vault Iris Agi, field
# password, read with `op read` at release time and piped, never written to disk or printed.
# FLOWRITER_KEY_REF points at another item. Create it once, on the Mac that cuts releases:
#   seed=$(openssl genpkey -algorithm ed25519 | openssl pkey -outform DER | tail -c 32 | base64)
#   op item create --category=password --vault "Iris Agi" --title "Flowriter Sparkle EdDSA key" "password=$seed"
#   printf '%s' "$seed" | swift scripts/ed-public-key.swift > scripts/sparkle-public-key.txt
# Commit the .txt: it is the public half, SUPublicEDKey in the app. Back the item up. A lost key
# means no installed copy can update again until it is reinstalled by hand.
#
# Refuses to run while scripts/sparkle-public-key.txt is the placeholder, when the key cannot be
# read, or when it does not match that public key (an update signed with it would be refused).
#
# Env: NOTES_FILE (same as --notes-file; default release-notes/X.Y.Z.md, else a one line note),
#      GH_REPO (default jonnilundy/flowriter), JOBS (default 8), THROTTLE (default: slowbuild if
#      installed), DEVELOPER_ID, NOTARY_PROFILE, FLOWRITER_KEY_REF.
# Tests only (never with --publish): FLOWRITER_SPARKLE_KEY_FILE reads a throwaway key from a file,
# FLOWRITER_DOWNLOAD_BASE points the enclosure at a local server, FLOWRITER_PUBLIC_ED_KEY overrides
# the public key, APPCAST overrides the appcast path.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
fail() { echo "release: $*" >&2; exit 1; }

GH_REPO=${GH_REPO:-jonnilundy/flowriter}
KEY_REF=${FLOWRITER_KEY_REF:-op://Iris Agi/Flowriter Sparkle EdDSA key/password}
PLACEHOLDER=REPLACE-WITH-PUBLIC-KEY
SPARKLE_BIN="$ROOT/.build-release/artifacts/sparkle/Sparkle/bin"
APPCAST=${APPCAST:-$ROOT/appcast.xml}

VERSION= PUBLISH= NOTES_FILE=${NOTES_FILE:-}
while (( $# )); do
  case $1 in
    --publish) PUBLISH=1 ;;
    --notes-file) shift; NOTES_FILE=${1:?--notes-file needs a file} ;;
    -*) fail "unknown option $1" ;;
    *) [[ -z $VERSION ]] || fail "one version only"; VERSION=$1 ;;
  esac
  shift
done
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "usage: scripts/release.sh X.Y.Z [--publish] [--notes-file FILE]"
TAG="v$VERSION"
if [[ -n $PUBLISH ]]; then
  [[ -z ${FLOWRITER_SPARKLE_KEY_FILE:-}${FLOWRITER_DOWNLOAD_BASE:-}${FLOWRITER_PUBLIC_ED_KEY:-} ]] || fail "test overrides are set: never publish with them"
  command -v gh >/dev/null || fail "gh is not installed"
  [[ $(git rev-parse --abbrev-ref HEAD) == main ]] || fail "publish from main"
  [[ -z $(git status --porcelain --untracked-files=no) ]] || fail "the working tree has uncommitted changes"
  git fetch -q origin main && [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main is not at origin/main: pull or push first"
  gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1 && fail "release $TAG already exists on $GH_REPO"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists here (the v0.1.x tags are upstream Flo State's: start at 0.2.0)"

PUBLIC_KEY=${FLOWRITER_PUBLIC_ED_KEY:-$(tr -d ' \n' < scripts/sparkle-public-key.txt)}
[[ $PUBLIC_KEY != $PLACEHOLDER ]] || fail "scripts/sparkle-public-key.txt is still the placeholder. Create the key first (the header of this script says how), commit the public key, then run again."

# the private key, kept in a variable: it goes over a pipe, never to disk or the screen
if [[ -n ${FLOWRITER_SPARKLE_KEY_FILE:-} ]]; then
  PRIVATE_KEY=$(<"$FLOWRITER_SPARKLE_KEY_FILE")
else
  command -v op >/dev/null || fail "the 1Password CLI (op) is not installed"
  ERR=$(mktemp); trap 'rm -f "$ERR"' EXIT
  PRIVATE_KEY=$(op read "$KEY_REF" 2>"$ERR") || { echo "release: could not read the signing key at $KEY_REF" >&2; echo "release: op said: $(tr '\n' ' ' < "$ERR")" >&2; exit 1; }
fi
DERIVED=$(printf '%s' "$PRIVATE_KEY" | swift scripts/ed-public-key.swift) || fail "the signing key is not base64 of a 32 byte Ed25519 seed"
[[ $DERIVED == $PUBLIC_KEY ]] || fail "the signing key does not match scripts/sparkle-public-key.txt (its public key is $DERIVED). Updates signed with it would be refused."

# 1. build + sign (bundle.sh runs sign.sh: ad hoc, or DEVELOPER_ID)
OUT="$ROOT/build/release"; APP="$OUT/Flowriter.app"; ZIP="$OUT/Flowriter-$VERSION.zip"
echo "$VERSION" > "$ROOT/VERSION"
THROTTLE=${THROTTLE-$(command -v slowbuild || true)}
rm -rf "$OUT"; mkdir -p "$OUT"
APP_NAME=Flowriter APP="$APP" INSTALL=0 THROTTLE="$THROTTLE" JOBS=${JOBS:-8} FLOWRITER_PUBLIC_ED_KEY="$PUBLIC_KEY" "$ROOT/scripts/bundle.sh"
PLIST="$APP/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST") == $PUBLIC_KEY ]] || fail "the built app carries a different SUPublicEDKey"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") == $VERSION ]] || fail "the built app is not version $VERSION"
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
if [[ -z ${FLOWRITER_SPARKLE_KEY_FILE:-} && -z ${FLOWRITER_DOWNLOAD_BASE:-} ]]; then
  PREV=$(grep -o '<sparkle:version>[0-9]*' "$APPCAST" 2>/dev/null | grep -o '[0-9]*$' | sort -n | tail -1 || true)
  [[ -z $PREV ]] || (( BUILD > PREV )) || fail "build $BUILD is not newer than build $PREV in the appcast: Sparkle would not offer it"
fi

NOTARIZED=0
if [[ -n ${DEVELOPER_ID:-} && -n ${NOTARY_PROFILE:-} ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP" && xcrun stapler validate "$APP" && spctl --assess --type execute --verbose "$APP"
  rm -f "$OUT/notarize.zip"; NOTARIZED=1
fi

# 2. zip + EdDSA signature
[[ -x $SPARKLE_BIN/sign_update ]] || fail "no sign_update in $SPARKLE_BIN: the release build has not run"
ditto -c -k --keepParent "$APP" "$ZIP"
LENGTH=$(stat -f%z "$ZIP")
SIG=$(printf '%s' "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$ZIP")
printf '%s' "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --verify --ed-key-file - "$ZIP" "$SIG" >/dev/null || fail "sign_update could not verify its own signature"
unset PRIVATE_KEY

# 3. notes + appcast
NOTES="$OUT/notes.md"
if [[ -n $NOTES_FILE ]]; then cp "$NOTES_FILE" "$NOTES"
elif [[ -f $ROOT/release-notes/$VERSION.md ]]; then cp "$ROOT/release-notes/$VERSION.md" "$NOTES"
else echo "Flowriter $VERSION." > "$NOTES"; fi
URL="${FLOWRITER_DOWNLOAD_BASE:-https://github.com/$GH_REPO/releases/download/$TAG}/${ZIP:t}"
python3 "$ROOT/scripts/appcast.py" "$APPCAST" --version "$VERSION" --build "$BUILD" --url "$URL" --ed-signature "$SIG" --length "$LENGTH" --notes-file "$NOTES"
xmllint --noout "$APPCAST"

GH_NOTES="$OUT/gh-notes.md"; cp "$NOTES" "$GH_NOTES"
(( NOTARIZED )) || printf '\n**Not notarized: on the first launch right-click the app, then Open.** Later versions install themselves.\n' >> "$GH_NOTES"
printf '\nDownload `%s`, unzip, and move **Flowriter.app** to /Applications.\n' "${ZIP:t}" >> "$GH_NOTES"

NOTES_PATH=release-notes/$VERSION.md
[[ -f $NOTES_PATH ]] || cp "$NOTES" "$NOTES_PATH"
FILES=(VERSION appcast.xml $NOTES_PATH)
if [[ -z $PUBLISH ]]; then
  echo "dry run: $ZIP ($LENGTH bytes, build $BUILD). Nothing was committed or published. To publish:"
  echo "  git add ${FILES[*]} && git commit -m 'Release $VERSION' && git tag $TAG"
  echo "  git push origin $TAG && gh release create $TAG '$ZIP' --repo $GH_REPO --title 'Flowriter $VERSION' --notes-file '$GH_NOTES'"
  echo "  git push origin main"
  echo "or run it again with --publish."
  exit 0
fi

# 4. publish
git add "${FILES[@]}" && git commit -qm "Release $VERSION"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$GH_REPO" --title "Flowriter $VERSION" --notes-file "$GH_NOTES"
git push origin main
echo "released $TAG (build $BUILD): https://github.com/$GH_REPO/releases/tag/$TAG"
