#!/bin/bash
# prepare-runtime.sh — Syncs the complete OpenClaw runtime into the app bundle.
# ClawTower ships a full, unmodified copy of OpenClaw. No trimming.
#
# Usage:
#   ./Scripts/prepare-runtime.sh [SOURCE_DIR]
#
# SOURCE_DIR defaults to /usr/local/lib/node_modules/openclaw

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/Resources/runtime"
PINNED_OPENCLAW_VERSION="2026.3.2"

SOURCE="${1:-/usr/local/lib/node_modules/openclaw}"

if [ ! -d "$SOURCE" ]; then
    echo "❌ OpenClaw not found at $SOURCE"
    echo "   Install it first: npm install -g openclaw"
    exit 1
fi

SOURCE_VERSION=$(node -e "console.log(require('$SOURCE/package.json').version)" 2>/dev/null || echo "unknown")
if [ "$SOURCE_VERSION" != "$PINNED_OPENCLAW_VERSION" ]; then
    echo "❌ OpenClaw version mismatch"
    echo "   Pinned version: $PINNED_OPENCLAW_VERSION"
    echo "   Source version: $SOURCE_VERSION"
    echo "   Source path: $SOURCE"
    echo "   Install/switch the source runtime to the pinned version before building."
    exit 1
fi

echo "📦 Syncing complete OpenClaw runtime from $SOURCE (v${SOURCE_VERSION})"

# --- Full sync of OpenClaw (no trimming!) ---
DEST="$RUNTIME_DIR/openclaw"
mkdir -p "$DEST"
rsync -a --delete "$SOURCE/" "$DEST/"
echo "$PINNED_OPENCLAW_VERSION" > "$RUNTIME_DIR/openclaw.version"

echo "   Size: $(du -sh "$DEST" | cut -f1)"

# --- Node.js binary ---
NODE_BIN="$RUNTIME_DIR/node"
if [ ! -f "$NODE_BIN" ]; then
    echo ""
    echo "  ⚠️  Node.js binary not found at $NODE_BIN"
    echo "     Place a standalone Node.js binary there for the app to work."
fi

echo ""
echo "✅ Runtime ready (v${SOURCE_VERSION})"
