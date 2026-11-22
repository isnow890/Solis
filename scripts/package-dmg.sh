#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="halo"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
bundle_version=""
if [[ -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
  bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")
fi
VERSION="${VERSION:-${bundle_version:-0.1.1}}"
ARCH="$(uname -m)"

if [[ "$VERSION" != "$bundle_version" ]]; then
  echo "==> Building the app bundle for version $VERSION..."
  VERSION="$VERSION" "$ROOT_DIR/scripts/build-app.sh"
fi

DMG_NAME="${APP_NAME}-v${VERSION}-${ARCH}.dmg"
ZIP_NAME="${APP_NAME}-v${VERSION}-${ARCH}.zip"
STAGE_DIR="$(mktemp -d "$BUILD_DIR/.dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

DMG_PATH="$STAGE_DIR/$DMG_NAME"
ZIP_PATH="$STAGE_DIR/$ZIP_NAME"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  : "${CODESIGN_IDENTITY:?Set a Developer ID Application identity}"
  xcrun stapler validate "$APP_BUNDLE"
  spctl --assess --type execute "$APP_BUNDLE"
fi
echo "==> Preparing DMG staging directory..."
mkdir "$STAGE_DIR/volume"
ditto "$APP_BUNDLE" "$STAGE_DIR/volume/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/volume/Applications"

echo "==> Creating $DMG_PATH..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR/volume" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  codesign --force --timestamp --identifier com.isnow890.halo.dmg --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --strict "$DMG_PATH"
  "$ROOT_DIR/scripts/notarize.sh" "$DMG_PATH" "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature "$DMG_PATH"
fi

echo "==> Creating $ZIP_PATH..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

(
  cd "$STAGE_DIR"
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" > SHA256SUMS.txt
  mv "$DMG_NAME" "$ZIP_NAME" SHA256SUMS.txt "$BUILD_DIR/"
)
cat "$BUILD_DIR/SHA256SUMS.txt"
echo "==> Release artifacts ready in $BUILD_DIR"
