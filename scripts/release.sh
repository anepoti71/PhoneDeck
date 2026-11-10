#!/usr/bin/env bash
# Builds PMD3Bar.app for distribution: Developer ID signature with hardened runtime, notarized by
# Apple and stapled, packed as build/PMD3Bar-<version>.zip. See RUNBOOK ("Release").
#
#   SIGN_IDENTITY   Developer ID Application identity (default: the first one in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile (default: PMD3Bar), created once with
#                   xcrun notarytool store-credentials PMD3Bar --apple-id <id> --team-id <team>
#   NOTARIZE=0      sign only (to test the hardened-runtime build without submitting it)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PMD3Bar.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-PMD3Bar}"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
if [[ -z "$IDENTITY" ]]; then
    echo "No 'Developer ID Application' identity in the keychain: create it on developer.apple.com" >&2
    echo "(Certificates › Developer ID Application) and install it with its private key." >&2
    exit 1
fi

if [[ "${NOTARIZE:-1}" != "0" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credentials named '$NOTARY_PROFILE'. Store them once (app-specific password):" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>" >&2
    exit 1
fi

SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/build-app.sh"

echo "==> Checking the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Authority=Developer ID Application|TeamIdentifier|Runtime Version)'

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/PMD3Bar-$VERSION.zip"
/bin/rm -f "$ZIP"

if [[ "${NOTARIZE:-1}" == "0" ]]; then
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Signed, not notarized: $ZIP"
    exit 0
fi

echo "==> Notarizing (this takes a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"
OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$OUT")"
ID="$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$OUT")"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization: $STATUS. Apple's log:" >&2
    xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
fi

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
/bin/rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Ready to distribute: $ZIP"
