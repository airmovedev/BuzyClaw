#!/bin/bash
set -e

# ============================================================
# ClawTower — One-click DMG Builder
# ============================================================
#
# Environment variables for code signing & notarization:
#
#   APPLE_ID      — Apple ID email (required for notarization)
#   APP_PASSWORD  — App-specific password (required for notarization)
#   TEAM_ID       — Apple Developer Team ID (default: USYB32X4N8)
#
# If APPLE_ID or APP_PASSWORD are not set, notarization is skipped.
# If no "Developer ID Application" certificate is found in keychain,
# both signing and notarization are skipped.
# ============================================================

APP_NAME="ClawTower"
SCHEME="ClawTower"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SIGNED_ENTITLEMENTS_PLIST="${BUILD_DIR}/entitlements-signed-${TIMESTAMP}.plist"

# Status tracking
SIGN_STATUS="skipped"
NOTARIZE_STATUS="skipped"

# Default Team ID / signing identity
TEAM_ID="${TEAM_ID:-USYB32X4N8}"
DEVELOPER_ID="Developer ID Application: AIRGO LIMITED (USYB32X4N8)"

echo "============================================================"
echo "  ${APP_NAME} DMG Builder"
echo "  $(date)"
echo "============================================================"
echo ""

# --------------------------------------------------
# Step 0: Clean previous build artifacts
# --------------------------------------------------
echo "▸ Step 0: Cleaning previous build artifacts..."
rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}" "${DMG_PATH}"
mkdir -p "${BUILD_DIR}"

# --------------------------------------------------
# Step 1: xcodegen generate
# --------------------------------------------------
echo "▸ Step 1: Running xcodegen generate..."
cd "${PROJECT_DIR}"
xcodegen generate
echo "  ✓ Xcode project generated"

# --------------------------------------------------
# Step 2: xcodebuild archive
# --------------------------------------------------
echo "▸ Step 2: Archiving (scheme: ${SCHEME}, macOS)..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -destination 'generic/platform=macOS' \
    -archivePath "${ARCHIVE_PATH}" \
    -configuration Release

# Verify archive exists
if [ ! -d "${ARCHIVE_PATH}" ]; then
    echo "  ✗ Archive failed"
    exit 1
fi
echo "  ✓ Archive created: ${ARCHIVE_PATH}"

# --------------------------------------------------
# Step 3: Export .app from archive
# --------------------------------------------------
echo "▸ Step 3: Exporting .app..."

# Verify expected Developer ID certificate exists
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${DEVELOPER_ID}"; then
    echo "  Found signing identity: ${DEVELOPER_ID}"
else
    DEVELOPER_ID=""
fi

mkdir -p "${EXPORT_DIR}"

if [ -n "${DEVELOPER_ID}" ]; then
    # Use xcodebuild -exportArchive to get a properly provisioned Developer ID app.
    # Direct cp from archive carries the Development provisioning profile, which
    # causes AMFI rejection for CloudKit restricted entitlements on other machines.
    echo "  Exporting with Developer ID provisioning via xcodebuild -exportArchive..."

    DEVID_EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions-DeveloperID.plist"
    cat > "${DEVID_EXPORT_OPTIONS}" <<'EXPORTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>USYB32X4N8</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>iCloudContainerEnvironment</key>
    <string>Production</string>
</dict>
</plist>
EXPORTPLIST

    xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportOptionsPlist "${DEVID_EXPORT_OPTIONS}" \
        -exportPath "${EXPORT_DIR}" \
        -allowProvisioningUpdates
else
    # Unsigned: just copy .app from archive
    echo "  No Developer ID certificate found — exporting unsigned..."
    cp -R "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "${EXPORT_DIR}/" 2>/dev/null \
        || cp -R "${ARCHIVE_PATH}/Products/usr/local/bin/${APP_NAME}.app" "${EXPORT_DIR}/" 2>/dev/null \
        || { echo "  ✗ Could not locate .app in archive"; exit 1; }
fi

if [ ! -d "${APP_PATH}" ]; then
    echo "  ✗ Export failed — .app not found"
    exit 1
fi

APP_SIZE=$(du -sh "${APP_PATH}" | cut -f1)
echo "  ✓ Exported: ${APP_PATH} (${APP_SIZE})"

# --------------------------------------------------
# Step 3.5: Recursive re-sign native binaries + app (inside-out)
# --------------------------------------------------
if [ -n "${DEVELOPER_ID}" ]; then
    echo "▸ Step 3.5: Re-signing native binaries recursively (inside-out)..."

    APP_SIGN_ARGS=(--force --sign "${DEVELOPER_ID}" --entitlements "${PROJECT_DIR}/SupportFiles/ClawTower.entitlements" --timestamp --options runtime)
    echo "  Release signing strategy: sign WITH entitlements (preserve CloudKit + iCloud container environment)"

    RESIGN_LIST="${BUILD_DIR}/resign-targets-${TIMESTAMP}.txt"
    : > "${RESIGN_LIST}"

    # Explicit native targets
    find "${APP_PATH}" -type f \( -name "*.node" -o -name "*.dylib" -o -name "*.so" -o -name "spawn-helper" \) -print >> "${RESIGN_LIST}" || true

    # Other Mach-O executables / binaries
    while IFS= read -r f; do
        if /usr/bin/file -b "${f}" | grep -q "Mach-O"; then
            echo "${f}" >> "${RESIGN_LIST}"
        fi
    done < <(find "${APP_PATH}" -type f -perm -111 -print)

    # Deduplicate and sign deepest paths first (inside-out)
    TARGETS_SORTED="${BUILD_DIR}/resign-targets-sorted-${TIMESTAMP}.txt"
    awk '!seen[$0]++' "${RESIGN_LIST}" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2- > "${TARGETS_SORTED}"

    TARGET_COUNT=$(wc -l < "${TARGETS_SORTED}" | tr -d ' ')
    if [ "${TARGET_COUNT}" -gt 0 ]; then
        echo "  Native binaries to re-sign: ${TARGET_COUNT}"
        while IFS= read -r target; do
            [ -z "${target}" ] && continue
            if [ "$(basename "${target}")" = "node" ]; then
                codesign --force --sign "${DEVELOPER_ID}" --entitlements Scripts/node.entitlements --timestamp --options runtime "${target}"
            else
                codesign --force --sign "${DEVELOPER_ID}" --timestamp --options runtime "${target}"
            fi
        done < "${TARGETS_SORTED}"
    else
        echo "  ⚠ No native binaries found for recursive re-sign"
    fi

    echo "  Signing main app bundle..."
    codesign "${APP_SIGN_ARGS[@]}" "${APP_PATH}"

    echo "  Verifying signature..."
    if codesign --verify --deep --strict "${APP_PATH}"; then
        echo "  ✓ Code signing verified"

        # Post-sign entitlement check: ensure CloudKit keys ARE present
        if codesign -d --entitlements :- "${APP_PATH}" > "${SIGNED_ENTITLEMENTS_PLIST}" 2>/dev/null && grep -q "<plist" "${SIGNED_ENTITLEMENTS_PLIST}"; then
            echo "  Signed entitlements extracted"
            REQUIRED_KEYS=(
                "com.apple.developer.icloud-container-identifiers"
                "com.apple.developer.icloud-services"
                "com.apple.developer.icloud-container-environment"
            )
            for key in "${REQUIRED_KEYS[@]}"; do
                if grep -q "<key>${key}</key>" "${SIGNED_ENTITLEMENTS_PLIST}"; then
                    echo "    ✓ Required entitlement present: ${key}"
                else
                    echo "    ✗ Required entitlement MISSING: ${key}"
                    SIGN_STATUS="failed"
                    exit 1
                fi
            done
            # Verify Production environment
            if grep -A1 "com.apple.developer.icloud-container-environment" "${SIGNED_ENTITLEMENTS_PLIST}" | grep -q "Production"; then
                echo "    ✓ iCloud container environment = Production"
            else
                echo "    ✗ iCloud container environment is NOT Production"
                SIGN_STATUS="failed"
                exit 1
            fi
            echo "  ✓ All required CloudKit entitlements verified"
        else
            echo "  ✗ Signed app has no entitlements payload — CloudKit will not work!"
            SIGN_STATUS="failed"
            exit 1
        fi

        # Verify provisioning profile is Developer ID (not Development)
        if [ -f "${APP_PATH}/Contents/embedded.provisionprofile" ]; then
            if security cms -D -i "${APP_PATH}/Contents/embedded.provisionprofile" 2>/dev/null | grep -q "ProvisionsAllDevices"; then
                echo "  ✓ Provisioning profile is Developer ID (provisions all devices)"
            elif security cms -D -i "${APP_PATH}/Contents/embedded.provisionprofile" 2>/dev/null | grep -q "ProvisionedDevices"; then
                echo "  ✗ ERROR: Provisioning profile is Development (device-specific), not Developer ID!"
                echo "    This will cause AMFI rejection on other machines."
                exit 1
            else
                echo "  ⚠ Could not determine provisioning profile type"
            fi
        else
            echo "  ⚠ No embedded.provisionprofile found in app bundle"
        fi

        SIGN_STATUS="signed"
    else
        echo "  ✗ Code signing verification failed"
        SIGN_STATUS="failed"
        exit 1
    fi
else
    echo "▸ Step 3.5: Skipping code signing (expected Developer ID certificate not found: Developer ID Application: AIRGO LIMITED (USYB32X4N8))"
fi

# --------------------------------------------------
# Step 4: Build DMG
# --------------------------------------------------
echo "▸ Step 4: Building DMG..."

# Remove stale DMG
rm -f "${DMG_PATH}"

if command -v create-dmg &>/dev/null; then
    echo "  Using create-dmg for prettier output..."
    create-dmg \
        --volname "${APP_NAME}" \
        --volicon "${APP_PATH}/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${APP_NAME}.app" 150 190 \
        --app-drop-link 450 190 \
        --format UDZO \
        "${DMG_PATH}" \
        "${EXPORT_DIR}/" \
        || {
            echo "  create-dmg failed, falling back to hdiutil..."
            # Fall through to hdiutil
            rm -f "${DMG_PATH}"
        }
fi

if [ ! -f "${DMG_PATH}" ]; then
    echo "  Using hdiutil..."
    STAGING="${BUILD_DIR}/dmg-staging"
    rm -rf "${STAGING}"
    mkdir -p "${STAGING}"
    cp -R "${APP_PATH}" "${STAGING}/"
    ln -s /Applications "${STAGING}/Applications"

    hdiutil create \
        -volname "${APP_NAME}" \
        -srcfolder "${STAGING}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}"

    rm -rf "${STAGING}"
fi

if [ ! -f "${DMG_PATH}" ]; then
    echo "  ✗ DMG creation failed"
    exit 1
fi

DMG_SIZE=$(du -sh "${DMG_PATH}" | cut -f1)
echo "  ✓ DMG created: ${DMG_PATH} (${DMG_SIZE})"

# --------------------------------------------------
# Step 5: Notarization
# --------------------------------------------------
if [ -n "${DEVELOPER_ID}" ] && [ "${SIGN_STATUS}" = "signed" ]; then
    # Determine notarization auth method
    NOTARY_AUTH=""
    if xcrun notarytool history --keychain-profile "notarytool-profile" >/dev/null 2>&1; then
        NOTARY_AUTH="keychain"
    elif [ -n "${APPLE_ID}" ] && [ -n "${APP_PASSWORD}" ]; then
        NOTARY_AUTH="password"
    fi

    if [ -z "${NOTARY_AUTH}" ]; then
        echo "▸ Step 5: Skipping notarization (no keychain profile or env vars)"
        echo "  Run 'xcrun notarytool store-credentials notarytool-profile' to set up"
        echo "  Or set APPLE_ID + APP_PASSWORD environment variables"
        NOTARIZE_STATUS="skipped (no auth)"
    else
        echo "▸ Step 5: Submitting for notarization..."
        NOTARY_OUT="${BUILD_DIR}/notary-${TIMESTAMP}.log"
        set +e
        if [ "${NOTARY_AUTH}" = "keychain" ]; then
            echo "  Using keychain profile: notarytool-profile"
            xcrun notarytool submit "${DMG_PATH}" \
                --keychain-profile "notarytool-profile" \
                --wait 2>&1 | tee "${NOTARY_OUT}"
        else
            echo "  Apple ID: ${APPLE_ID}"
            echo "  Team ID:  ${TEAM_ID}"
            xcrun notarytool submit "${DMG_PATH}" \
                --apple-id "${APPLE_ID}" \
                --team-id "${TEAM_ID}" \
                --password "${APP_PASSWORD}" \
                --wait 2>&1 | tee "${NOTARY_OUT}"
        fi
        NOTARY_RC=${PIPESTATUS[0]}
        set -e

        SUBMISSION_ID=$(grep -E "id:|Submission ID:" "${NOTARY_OUT}" | tail -1 | sed -E 's/.*(id:|Submission ID:) *//')
        [ -n "${SUBMISSION_ID}" ] && echo "  Submission ID: ${SUBMISSION_ID}"

        if [ ${NOTARY_RC} -eq 0 ]; then
            echo "  ✓ Notarization succeeded"
            echo "  Stapling notarization ticket..."
            if xcrun stapler staple "${DMG_PATH}" && xcrun stapler validate "${DMG_PATH}"; then
                echo "  ✓ Stapled + validated"
                NOTARIZE_STATUS="notarized + stapled"
            else
                echo "  ⚠ Stapling failed (DMG is still notarized)"
                NOTARIZE_STATUS="notarized (staple failed)"
            fi
        else
            echo "  ✗ Notarization failed"
            if [ -n "${SUBMISSION_ID}" ]; then
                if [ "${NOTARY_AUTH}" = "keychain" ]; then
                    xcrun notarytool log "${SUBMISSION_ID}" --keychain-profile "notarytool-profile" || true
                else
                    xcrun notarytool log "${SUBMISSION_ID}" \
                        --apple-id "${APPLE_ID}" \
                        --team-id "${TEAM_ID}" \
                        --password "${APP_PASSWORD}" || true
                fi
            fi
            NOTARIZE_STATUS="failed"
        fi
    fi
else
    echo "▸ Step 5: Skipping notarization (app not signed)"
fi

# --------------------------------------------------
# Summary
# --------------------------------------------------
echo ""
echo "============================================================"
echo "  ✓ DMG ready!"
echo "  ${DMG_PATH}"
echo "  Size: ${DMG_SIZE}"
echo "  Signing:      ${SIGN_STATUS}"
echo "  Notarization: ${NOTARIZE_STATUS}"
echo "============================================================"
