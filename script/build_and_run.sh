#!/usr/bin/env bash
set -euo pipefail

# Builds the OpenUsage preview, stages a .app bundle, codesigns it with a stable
# Apple Development identity (so keychain/permission ACLs stick across rebuilds),
# installs it to /Applications as "OpenUsage Preview", and launches it.
#
# Usage: script/build_and_run.sh [run|build|logs|verify]
# Env:   CODESIGN_IDENTITY  override signing identity (exact name or hash)
#        CONFIG             "release" (default) or "debug"

MODE="${1:-run}"
CONFIG="${CONFIG:-release}"

TARGET_NAME="OpenUsage"                 # SwiftPM target / binary name
APP_DISPLAY="OpenUsage Preview"         # user-facing app name
BUNDLE_ID="com.robinebers.openusage.preview"
MIN_SYSTEM_VERSION="26.0"
APP_VERSION="0.7.0"
APP_BUILD="0.7.0"

# Sparkle feed keys, baked in so the Settings "Updates" section is visible in the preview build
# (it only renders when SUFeedURL is present — see UpdaterController). These match the release build's
# public key + feed URL, but automatic checks stay OFF below so a dev build never replaces itself with a
# real release in the background. The manual "Check for Updates…" button works against the live appcast.
SPARKLE_PUBLIC_KEY="mNodQoOL3cI2ym60dX20yL8NlwgoAKVeX3eMWAjvusE="
FEED_URL="https://robinebers.github.io/openusage/appcast.xml"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$TARGET_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCE_BUNDLE_NAME="${TARGET_NAME}_${TARGET_NAME}.bundle"
ENTITLEMENTS="$ROOT_DIR/script/OpenUsage.dev.entitlements.plist"
INSTALL_DIR="/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_DISPLAY.app"

pkill -x "$TARGET_NAME" >/dev/null 2>&1 || true

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"
BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$TARGET_NAME"
RESOURCE_BUNDLE="$BUILD_DIR/$RESOURCE_BUNDLE_NAME"

if [ ! -x "$BUILD_BINARY" ]; then
  echo "missing built binary: $BUILD_BINARY" >&2
  exit 1
fi

echo "==> staging $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Stage every SwiftPM resource bundle produced by the build (the app's own
# OpenUsage_OpenUsage.bundle, which carries the provider SVGs + model manifest).
# Bundle.module resolves to its bundle sitting next to the binary, so it must
# ship alongside the executable.
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_RESOURCES/$(basename "$bundle")"
done
shopt -u nullglob

# Compile the Icon Composer source (assets/AppIcon.icon) into Assets.car so
# Tahoe renders the real Liquid Glass icon. CFBundleIconName below must match
# the .icon file stem ("AppIcon"). No .icns fallback needed: the app is 26.0+.
echo "==> compiling app icon (actool)"
xcrun actool "$ROOT_DIR/assets/AppIcon.icon" --compile "$APP_RESOURCES" \
  --app-icon AppIcon \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --output-partial-info-plist /dev/null \
  --output-format human-readable-text --errors --warnings

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$TARGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <false/>
</dict>
</plist>
PLIST

# Pick a stable Apple Development identity so ad-hoc cdhash churn doesn't re-trigger
# permission prompts on every rebuild. Fall back to ad-hoc only if none is found.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$CODESIGN_IDENTITY" ]; then
  CODESIGN_IDENTITY=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null \
    | /usr/bin/awk -F\" '/Apple Development:/ { print $2; exit }')
fi

# Embed + sign Sparkle.framework before sealing the app. The executable links Sparkle, so without the
# embedded framework the preview build would fail to launch. The preview ships the same SUFeedURL as
# release (so the Updates UI is visible) but with automatic checks disabled (see Info.plist above).
"$ROOT_DIR/script/embed_sparkle.sh" "$APP_BUNDLE" "$APP_BINARY" "$CODESIGN_IDENTITY" "--options runtime"

if [ -n "$CODESIGN_IDENTITY" ]; then
  # Not --deep: the Sparkle framework is already signed above and must keep that signature.
  /usr/bin/codesign --force --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE" >/dev/null
  echo "==> signed with: $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  echo "WARNING: no Apple Development identity found; ad-hoc signed." >&2
fi

install_app() {
  echo "==> installing to $INSTALLED_APP"
  rm -rf "$INSTALLED_APP"
  cp -R "$APP_BUNDLE" "$INSTALLED_APP"
}

launch_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

case "$MODE" in
  run)
    install_app
    launch_app
    echo "==> launched $APP_DISPLAY"
    ;;
  build)
    : # build + stage + sign only
    ;;
  logs)
    install_app
    launch_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$TARGET_NAME\""
    ;;
  verify)
    install_app
    launch_app
    sleep 1
    pgrep -x "$TARGET_NAME" >/dev/null && echo "==> running"
    ;;
  *)
    echo "usage: $0 [run|build|logs|verify]" >&2
    exit 2
    ;;
esac
