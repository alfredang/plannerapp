#!/bin/bash
# Build the macOS desktop edition of Planner and package it as a drag-to-install DMG.
#
#   ./scripts/build-macos-dmg.sh
#
# Output: dist/Planner-<version>.dmg  (volume contains Planner.app + an /Applications alias)
#
# Signing & notarization:
#   * With a "Developer ID Application" identity in the keychain, the app is manually signed
#     with it (profile "PlannerAppMac Developer ID", entitlements PlannerAppMacDevID
#     .entitlements — iCloud Production, no push), the DMG is notarized via `notarytool`
#     using the org ASC API key, and the ticket is stapled. Result: installs cleanly on any
#     Mac, no Gatekeeper warning. Notarization is an automated scan — no App Store review.
#   * Without one, falls back to automatic development signing — fine for this Mac only.

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="PlannerAppMac"
APP_NAME="Planner"
BUILD_DIR="build/mac-dmg"
DIST_DIR="dist"
DEVID_PROFILE="PlannerAppMac Developer ID"

ASC_KEY="${HOME}/.appstoreconnect/private_keys/AuthKey_YQHNLVGDWK.p8"
ASC_KEY_ID="YQHNLVGDWK"
ASC_ISSUER_ID="f026f849-65f1-4ca4-9d49-1b6764131f40"

command -v xcodegen >/dev/null && xcodegen generate

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
DMG="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

# Prefer Developer ID signing for distribution when the identity exists.
NOTARIZE=0
SIGN_ARGS=()
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" \
             | head -1 | sed 's/.*"\(.*\)"/\1/')
  echo "==> Signing with: ${IDENTITY}"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual
             "CODE_SIGN_IDENTITY=${IDENTITY}"
             "PROVISIONING_PROFILE_SPECIFIER=${DEVID_PROFILE}"
             CODE_SIGN_ENTITLEMENTS=PlannerAppMac/PlannerAppMacDevID.entitlements
             "OTHER_CODE_SIGN_FLAGS=--timestamp")
  NOTARIZE=1
else
  echo "==> No Developer ID Application identity found — using automatic development signing."
  echo "    (The DMG will run on this Mac; other Macs will see a Gatekeeper warning.)"
fi

# The iCloud entitlement needs a provisioning profile; let xcodebuild create/refresh it,
# authenticating with the App Store Connect API key when present.
PROVISION_ARGS=(-allowProvisioningUpdates)
if [ -f "${ASC_KEY}" ]; then
  PROVISION_ARGS+=(-authenticationKeyPath "${ASC_KEY}"
                   -authenticationKeyID "${ASC_KEY_ID}"
                   -authenticationKeyIssuerID "${ASC_ISSUER_ID}")
fi

echo "==> Building ${SCHEME} (Release)…"
xcodebuild -project PlannerApp.xcodeproj \
           -scheme "${SCHEME}" \
           -configuration Release \
           -derivedDataPath "${BUILD_DIR}" \
           "${PROVISION_ARGS[@]}" \
           "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" \
           build | grep -E "error:|warning: .*deprecat|BUILD" || true

APP="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"
[ -d "${APP}" ] || { echo "ERROR: ${APP} not found — build failed."; exit 1; }

echo "==> Staging DMG contents…"
STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

echo "==> Creating ${DMG}…"
mkdir -p "${DIST_DIR}"
rm -f "${DMG}"
hdiutil create -volname "${APP_NAME}" \
               -srcfolder "${STAGING}" \
               -ov -format UDZO \
               "${DMG}" >/dev/null

if [ "${NOTARIZE}" = "1" ]; then
  [ -f "${ASC_KEY}" ] || { echo "ERROR: ASC API key missing — cannot notarize."; exit 1; }
  echo "==> Notarizing ${DMG} (this usually takes a few minutes)…"
  xcrun notarytool submit "${DMG}" \
        --key "${ASC_KEY}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" \
        --wait --timeout 30m
  echo "==> Stapling ticket…"
  xcrun stapler staple "${DMG}"
  echo "==> Gatekeeper check:"
  spctl -a -vv -t install "${DMG}" 2>&1 | sed 's/^/    /'
fi

echo "==> Done: ${DMG}"
du -h "${DMG}" | awk '{print "    size:", $1}'
echo "    Install: open the DMG and drag ${APP_NAME}.app onto Applications."
