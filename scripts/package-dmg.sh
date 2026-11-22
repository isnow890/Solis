#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Solis"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
VERSION="${VERSION:-0.1.0}"
ARCH="$(uname -m)"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "==> $APP_BUNDLE not found; running build-app.sh first..."
  "$ROOT_DIR/scripts/build-app.sh"
fi

DMG_NAME="${APP_NAME}-v${VERSION}-${ARCH}.dmg"
ZIP_NAME="${APP_NAME}-v${VERSION}-${ARCH}.zip"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
SHA_PATH="$BUILD_DIR/SHA256SUMS.txt"

STAGE_DIR="$(mktemp -d "$BUILD_DIR/.dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

echo "==> Preparing DMG staging directory..."
ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Creating $DMG_PATH..."
rm -f "$DMG_PATH" "$ZIP_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Creating $ZIP_PATH..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Writing checksums to $SHA_PATH..."
(
  cd "$BUILD_DIR"
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > "$SHA_PATH"
)

cat "$SHA_PATH"
echo "==> Release artifacts ready in $BUILD_DIR"
