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
    # Export without re-signing (archive already has Team info; signing happens in Step 3.5)
    echo "  Exporting app from archive..."
    cp -R "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "${EXPORT_DIR}/" 2>/dev/null \
        || cp -R "${ARCHIVE_PATH}/Products/usr/local/bin/${APP_NAME}.app" "${EXPORT_DIR}/" 2>/dev/null \
        || { echo "  ✗ Could not locate .app in archive"; exit 1; }
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

    APP_SIGN_ARGS=(--force --sign "${DEVELOPER_ID}" --timestamp --options runtime)
    echo "  Release signing strategy: do NOT carry over archive entitlements (avoid restricted CloudKit entitlements)"

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

        # Post-sign entitlement check: ensure restricted CloudKit keys are absent for launch safety
        if codesign -d --entitlements :- "${APP_PATH}" > "${SIGNED_ENTITLEMENTS_PLIST}" 2>/dev/null && grep -q "<plist" "${SIGNED_ENTITLEMENTS_PLIST}"; then
            echo "  Signed entitlements extracted"
            BLOCKED_KEYS=(
                "com.apple.developer.icloud-container-identifiers"
                "com.apple.developer.icloud-services"
                "com.apple.developer.team-identifier"
            )
            for key in "${BLOCKED_KEYS[@]}"; do
                if grep -q "<key>${key}</key>" "${SIGNED_ENTITLEMENTS_PLIST}"; then
                    echo "    ✗ Restricted entitlement still present: ${key}"
                    SIGN_STATUS="failed"
                    exit 1
                fi
            done
            echo "  ✓ Restricted CloudKit entitlements are absent"
        else
            echo "  ✓ Signed app has no entitlements payload"
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
    if [ -z "${APPLE_ID}" ] || [ -z "${APP_PASSWORD}" ]; then
        echo "▸ Step 5: Skipping notarization (missing environment variables)"
        echo "  Set APPLE_ID, APP_PASSWORD (and optionally TEAM_ID) to enable notarization"
        NOTARIZE_STATUS="skipped (env vars missing)"
    else
        echo "▸ Step 5: Submitting for notarization..."
        echo "  Apple ID: ${APPLE_ID}"
        echo "  Team ID:  ${TEAM_ID}"
        NOTARY_OUT="${BUILD_DIR}/notary-${TIMESTAMP}.log"
        set +e
        xcrun notarytool submit "${DMG_PATH}" \
            --apple-id "${APPLE_ID}" \
            --team-id "${TEAM_ID}" \
            --password "${APP_PASSWORD}" \
            --wait 2>&1 | tee "${NOTARY_OUT}"
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
            [ -n "${SUBMISSION_ID}" ] && xcrun notarytool log "${SUBMISSION_ID}" \
                --apple-id "${APPLE_ID}" \
                --team-id "${TEAM_ID}" \
                --password "${APP_PASSWORD}" || true
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
