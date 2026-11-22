#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="halo"
BUNDLE_ID="com.isnow890.halo"
VERSION="${VERSION:-0.1.0}"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid halo version: $VERSION" >&2
  exit 1
fi
BUILD_DIR="$ROOT_DIR/build"
OUTPUT="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

echo "==> Building $APP_NAME (release)..."
cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "Error: Built binary not found at $BIN_PATH" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
stage=$(mktemp -d "$BUILD_DIR/.halo-stage.XXXXXX")
install_stage=""
cleanup() {
  rm -rf "$stage"
  if [[ -n "$install_stage" ]]; then rm -rf "$install_stage"; fi
}
trap cleanup EXIT
APP_BUNDLE="$stage/$APP_NAME.app"
echo "==> Packaging $OUTPUT..."
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [[ ! -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  echo "==> Generating AppIcon.icns..."
  swift "$ROOT_DIR/scripts/generate-icon.swift" "$ROOT_DIR"
fi
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Preserve the existing signing identity on local rebuilds. An explicit override opts into a new identity.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && -d "$INSTALL_PATH" ]]; then
  SIGN_IDENTITY=$(codesign -dv --verbose=2 "$INSTALL_PATH" 2>&1 | awk '/^Authority=/ && !found {sub(/^Authority=/,"");print;found=1}')
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  candidates=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
  if [[ -z "$candidates" || "$candidates" == *$'\n'* ]]; then
    echo "Set CODESIGN_IDENTITY to a specific signing identity (or - for an explicit ad-hoc build)." >&2
    exit 1
  fi
  SIGN_IDENTITY="$candidates"
fi
if [[ -n "${NOTARY_PROFILE:-}" || "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP_BUNDLE" "$stage/submission.zip"
  "$ROOT_DIR/scripts/notarize.sh" "$stage/submission.zip" "$APP_BUNDLE"
  spctl --assess --type execute "$APP_BUNDLE"
fi
codesign --verify --strict "$APP_BUNDLE"

# Both paths are on the same volume. With an existing bundle, its old contents move into staging.
publish_bundle() {
  /usr/bin/swift - "$1" "$2" <<'SWIFT'
import Foundation
import Darwin
let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
let existing = FileManager.default.fileExists(atPath: destination)
let result = renamex_np(source, destination, existing ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL))
if result != 0 { perror("renamex_np"); exit(1) }
SWIFT
}
publish_bundle "$APP_BUNDLE" "$OUTPUT"
if [[ "${1:-}" == "--install" ]]; then
  install_stage=$(mktemp -d "/Applications/.halo-stage.XXXXXX")
  ditto "$OUTPUT" "$install_stage/$APP_NAME.app"
  codesign --verify --strict "$install_stage/$APP_NAME.app"
  publish_bundle "$install_stage/$APP_NAME.app" "$INSTALL_PATH"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_PATH"
  echo "==> Installed $INSTALL_PATH"
else
  echo "==> Built $OUTPUT"
fi
