#!/bin/zsh
# Codesign an app bundle.
# Ad-hoc by default; with DEVELOPER_ID="Developer ID Application: … (TEAMID)"
# it signs with that identity + hardened runtime + secure timestamp (notarizable).
set -euo pipefail
APP="$1"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  SIGN=(codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp)
else
  SIGN=(codesign --force --sign -)
fi
# codesign rejects xattrs (Finder info, iCloud/File Provider tags)
xattr -cr "$APP"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
