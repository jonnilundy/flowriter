#!/bin/zsh
# Build the plain editor (the Flowriter product) and assemble "build/plain/Flowriter.app".
# Same bundle id as scripts/bundle.sh, so it keeps the settings and replaces that app when installed:
#   SRC=build/plain/Flowriter.app scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
[[ -f "$ROOT/.local.env" ]] && source "$ROOT/.local.env"
SCRATCH=$ROOT/.build-release
APP_NAME="${APP_NAME:-Flowriter}"
BUNDLE_ID="${BUNDLE_ID:-app.flowriter.Flowriter}"
APP="${APP:-$ROOT/build/plain/$APP_NAME.app}"
ICON_SRC="$ROOT/Resources/AppIcon.icon"
ICON_FALLBACK="$ROOT/Resources/AppIcon.icns"

# The package still declares Sparkle for the old app: SwiftPM resolves it even for this product.
[[ -d "$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework" ]] || "$ROOT/scripts/seed-sparkle.sh" "$SCRATCH"
${=THROTTLE:-} swift build --disable-keychain -c release -j "${JOBS:-8}" --product Flowriter --scratch-path "$SCRATCH"
BIN_DIR=$(swift build --disable-keychain -c release --product Flowriter --scratch-path "$SCRATCH" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Flowriter" "$APP/Contents/MacOS/Flowriter"
EXE="$APP/Contents/MacOS/Flowriter"
# only the OS Swift runtime: XProtect flags dangling rpaths
for rp in ${(f)"$(otool -l "$EXE" | awk '/cmd LC_RPATH/{getline; getline; print $2}')"}; do
  [[ "$rp" == /usr/lib/swift ]] || install_name_tool -delete_rpath "$rp" "$EXE"
done

ICON_NAME_PLIST=""
ICON_OUT="$SCRATCH/appicon-plain"
rm -rf "$ICON_OUT"; mkdir -p "$ICON_OUT"
if xcrun actool "$ICON_SRC" --compile "$ICON_OUT" --app-icon AppIcon --platform macosx \
     --target-device mac --minimum-deployment-target 14.0 \
     --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null 2>&1 \
   && [[ -f "$ICON_OUT/Assets.car" && -f "$ICON_OUT/AppIcon.icns" ]]; then
  cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
  ICON_NAME_PLIST="<key>CFBundleIconName</key><string>AppIcon</string>"
else
  echo "warning: actool failed; using pre-masked $ICON_FALLBACK" >&2
  cp "$ICON_FALLBACK" "$APP/Contents/Resources/AppIcon.icns"
fi

SHORT_VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Flowriter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  ${ICON_NAME_PLIST}
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
      <key>UTTypeDescription</key><string>Markdown Document</string>
      <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>md</string><string>markdown</string><string>mdown</string><string>mkd</string><string>mdx</string></array>
        <key>public.mime-type</key><array><string>text/markdown</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>NSDocumentClass</key><string>FlowriterKit.Document</string>
      <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string><string>public.plain-text</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

"$ROOT/scripts/sign.sh" "$APP"
echo "built: $APP"
