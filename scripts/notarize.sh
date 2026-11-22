#!/usr/bin/env bash
set -euo pipefail

# ZIP submissions carry the app. Apple staples the ticket to the app or DMG.
submission=${1:?Expected ZIP or DMG to submit}
target=${2:?Expected app or DMG to staple}
auth=(--keychain-profile "${NOTARY_PROFILE:?Set NOTARY_PROFILE}")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
  auth+=(--keychain "$NOTARY_KEYCHAIN")
fi
result=$(mktemp)
trap 'rm -f "$result"' EXIT
if ! xcrun notarytool submit "$submission" "${auth[@]}" --wait --output-format plist > "$result"; then
  echo "Apple notarization submission failed" >&2
fi
status=$(plutil -extract status raw -o - "$result") || exit 1
if [[ "$status" != "Accepted" ]]; then
  id=$(plutil -extract id raw -o - "$result")
  echo "Notarization $id: $status" >&2
  xcrun notarytool log "$id" "${auth[@]}" >&2
  exit 1
fi
xcrun stapler staple "$target"
xcrun stapler validate "$target"
