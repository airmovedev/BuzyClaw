#!/bin/bash
# prepare-runtime.sh — Validates and optionally syncs the OpenClaw runtime bundled into ClawTower.
# Build decisions are based on the bundled runtime in Resources/runtime, not on the host's global OpenClaw version.
#
# Usage:
#   ./Scripts/prepare-runtime.sh [SOURCE_DIR]
#
# SOURCE_DIR defaults to /usr/local/lib/node_modules/openclaw and is treated as an optional sync source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/Resources/runtime"
DEST="$RUNTIME_DIR/openclaw"
PINNED_OPENCLAW_VERSION="2026.3.13"

# Accept explicit path, or auto-detect from npm global prefix
if [ -n "${1:-}" ]; then
    SOURCE="$1"
elif command -v npm &>/dev/null; then
    SOURCE="$(npm root -g)/openclaw"
else
    SOURCE="/usr/local/lib/node_modules/openclaw"
fi

read_package_version() {
    local dir="$1"

    if [ -f "$dir/package.json" ]; then
        # Use bundled node if available, otherwise python3 (always present in Xcode build env)
        if [ -x "$RUNTIME_DIR/node" ]; then
            "$RUNTIME_DIR/node" -e "console.log(require('$dir/package.json').version)" 2>/dev/null || echo "unknown"
        elif command -v python3 &>/dev/null; then
            python3 -c "import json; print(json.load(open('$dir/package.json'))['version'])" 2>/dev/null || echo "unknown"
        else
            echo "unknown"
        fi
    else
        echo "missing"
    fi
}

compare_status_label() {
    case "$1" in
        0) echo "meets-or-exceeds" ;;
        1) echo "below" ;;
        *) echo "uncomparable" ;;
    esac
}

compare_versions() {
    local left="$1"
    local right="$2"

    if [ -z "$left" ] || [ -z "$right" ] || [ "$left" = "unknown" ] || [ "$right" = "unknown" ] || [ "$left" = "missing" ] || [ "$right" = "missing" ]; then
        return 2
    fi

    if ! [[ "$left" =~ ^[0-9]+(\.[0-9]+)*$ ]] || ! [[ "$right" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        return 2
    fi

    local left_parts right_parts max_parts i left_part right_part
    IFS='.' read -r -a left_parts <<< "$left"
    IFS='.' read -r -a right_parts <<< "$right"

    if [ "${#left_parts[@]}" -gt "${#right_parts[@]}" ]; then
        max_parts="${#left_parts[@]}"
    else
        max_parts="${#right_parts[@]}"
    fi

    for ((i = 0; i < max_parts; i++)); do
        left_part="${left_parts[i]:-0}"
        right_part="${right_parts[i]:-0}"

        left_part=$((10#$left_part))
        right_part=$((10#$right_part))

        if [ "$left_part" -lt "$right_part" ]; then
            return 1
        fi
        if [ "$left_part" -gt "$right_part" ]; then
            return 0
        fi
    done

    return 0
}

SOURCE_VERSION="missing"
if [ -d "$SOURCE" ]; then
    SOURCE_VERSION="$(read_package_version "$SOURCE")"
fi

BUNDLED_VERSION="$(read_package_version "$DEST")"
MARKER_VERSION="$(cat "$RUNTIME_DIR/openclaw.version" 2>/dev/null || echo "missing")"

if compare_versions "$SOURCE_VERSION" "$PINNED_OPENCLAW_VERSION"; then
    source_compare_status=0
else
    source_compare_status=$?
fi

if compare_versions "$BUNDLED_VERSION" "$PINNED_OPENCLAW_VERSION"; then
    bundled_compare_status=0
else
    bundled_compare_status=$?
fi

print_status() {
    echo "🔎 Checking OpenClaw runtime"
    echo "   Pinned version:   $PINNED_OPENCLAW_VERSION"
    echo "   Bundled version:  $BUNDLED_VERSION ($(compare_status_label "$bundled_compare_status"))"
    echo "   Marker version:   $MARKER_VERSION"
    echo "   Source version:   $SOURCE_VERSION ($(compare_status_label "$source_compare_status"))"
    echo "   Source path:      $SOURCE"
}

print_status

if [ "$bundled_compare_status" -eq 0 ]; then
    # Even when the version matches, the source may have additional packages
    # (e.g. new transitive dependencies added after the initial sync).
    # Do an additive sync (no --delete) so missing packages get filled in.
    if [ -d "$SOURCE" ] && [ "$source_compare_status" -eq 0 ]; then
        BUNDLED_PKG_COUNT="$(ls "$DEST/node_modules/" 2>/dev/null | wc -l | tr -d ' ')"
        SOURCE_PKG_COUNT="$(ls "$SOURCE/node_modules/" 2>/dev/null | wc -l | tr -d ' ')"
        if [ "$SOURCE_PKG_COUNT" -gt "$BUNDLED_PKG_COUNT" ]; then
            echo "🔄 Syncing missing packages from source (bundled: $BUNDLED_PKG_COUNT, source: $SOURCE_PKG_COUNT)"
            rsync -a "$SOURCE/node_modules/" "$DEST/node_modules/"
            echo "   ✅ Packages synced"
        else
            echo "✅ Using bundled runtime as-is"
            echo "   Reason: bundled runtime already satisfies the pinned version; source/runtime installed on host is informational only."
        fi
    else
        echo "✅ Using bundled runtime as-is"
        echo "   Reason: bundled runtime already satisfies the pinned version; source/runtime installed on host is informational only."
    fi
else
    if [ -d "$SOURCE" ]; then
        echo "📦 Syncing bundled runtime from source"
        echo "   Reason: bundled runtime is missing or below pinned, so prepare-runtime refreshes the app bundle from the optional source first."
        echo "   Source remains informational; only the final bundled runtime is validated as a build gate."

        mkdir -p "$DEST"
        rsync -a --delete "$SOURCE/" "$DEST/"

        BUNDLED_VERSION="$(read_package_version "$DEST")"
        MARKER_VERSION="$BUNDLED_VERSION"
        echo "$BUNDLED_VERSION" > "$RUNTIME_DIR/openclaw.version"

        echo "   Synced bundled version: $BUNDLED_VERSION"
        echo "   Size: $(du -sh "$DEST" | cut -f1)"
        echo "   Validating synced bundled runtime against pinned version..."

        if compare_versions "$BUNDLED_VERSION" "$PINNED_OPENCLAW_VERSION"; then
            bundled_compare_status=0
        else
            bundled_compare_status=$?
        fi
    else
        echo "ℹ️  No source runtime available for sync"
        echo "   Reason: source path is absent; continuing with bundled runtime validation only."
    fi
fi

if [ "$bundled_compare_status" -ne 0 ]; then
    echo "❌ Bundled OpenClaw runtime does not satisfy project requirements"
    echo "   Pinned version:   $PINNED_OPENCLAW_VERSION"
    echo "   Final bundled:    $BUNDLED_VERSION ($(compare_status_label "$bundled_compare_status"))"
    echo "   Source version:   $SOURCE_VERSION ($(compare_status_label "$source_compare_status"))"
    echo "   Reason: only the bundled runtime that ships in the app may block, and its final version is below pinned or uncomparable."
    echo "   Continuing source/host version differences are informational only."
    exit 1
fi

if [ "$MARKER_VERSION" != "$BUNDLED_VERSION" ]; then
    echo "$BUNDLED_VERSION" > "$RUNTIME_DIR/openclaw.version"
    MARKER_VERSION="$BUNDLED_VERSION"
fi

# --- Node.js binary ---
NODE_BIN="$RUNTIME_DIR/node"
if [ ! -f "$NODE_BIN" ]; then
    echo ""
    echo "  ⚠️  Node.js binary not found at $NODE_BIN"
    echo "     Place a standalone Node.js binary there for the app to work."
fi

echo ""
echo "✅ Runtime ready"
echo "   Pinned version:   $PINNED_OPENCLAW_VERSION"
echo "   Bundled version:  $BUNDLED_VERSION"
echo "   Source version:   $SOURCE_VERSION"
echo "   Reason: build is allowed because the bundled runtime that will ship in the app is at or above the pinned version."
