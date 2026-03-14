# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is BuzyClaw?

BuzyClaw (虾忙) is a macOS native app (SwiftUI) that embeds OpenClaw (Node.js AI Agent runtime) inside the app bundle, providing a GUI for non-technical users. A companion iOS app communicates with the macOS app via CloudKit. Distributed via .dmg (NOT App Store) — no sandbox restrictions.

## Build & Run

```bash
# Generate Xcode project from project.yml and build
xcodegen generate && xcodebuild -scheme ClawTower -configuration Debug build 2>&1 | tail -30

# iOS target
xcodebuild -scheme ClawTowerMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -30

# Distribution DMG
Scripts/build-dmg.sh
```

A pre-build script (`Scripts/prepare-runtime.sh`) validates the bundled OpenClaw runtime version and syncs from system source if needed. It will fail the build if `Resources/runtime/node` or `Resources/runtime/openclaw/` are missing or outdated.

No test targets exist in this project.

## Architecture

### Two Targets, Selective Code Sharing

The project has two xcodegen targets — `ClawTower` (macOS) and `ClawTowerMobile` (iOS). They do NOT share a framework; instead, `project.yml` explicitly cross-references individual files:
- macOS includes `Sources/ClawTowerMobile/Models/DashboardSnapshot.swift`
- iOS includes `Sources/ClawTower/Services/CloudKit/MessageRecord.swift` and `Sources/ClawTower/Models/CronJob.swift`

Both targets share `SupportFiles/Localization/`.

### AppState: Central Coordinator (macOS)

`AppState` (`@MainActor @Observable`) is the single source of truth for macOS. It holds all services (`GatewayManager`, `GatewayClient`, `CloudKitRelayService`, `DashboardSyncService`) and application state (agents, sessions, navigation). Views receive `appState` directly — there is no separate ViewModel layer on macOS. iOS uses its own `@Observable` ViewModels in `Sources/ClawTowerMobile/ViewModels/`.

### Gateway Lifecycle

The macOS app manages a Node.js subprocess running OpenClaw:

1. **Port allocation**: Dynamic port via raw socket bind (never hardcoded)
2. **Two modes**: `freshInstall` (bundled runtime in `Resources/runtime/`) or `existingInstall` (system `~/.openclaw/` on port 18789)
3. **Process launch**: `node openclaw.mjs gateway --port {port} --allow-unconfigured --bind loopback`
4. **Health monitoring**: 1-second polling of `/health` endpoint with Bearer token auth
5. **State machine**: `stopped → starting → running → reconnecting → disconnected → error`
6. **Auto-restart**: Max 1 restart attempt with exponential backoff (2s–10s)

`GatewayClient` wraps all HTTP calls to the local Gateway (OpenAI-compatible API) with token auth.

### CloudKit Bridge (macOS ↔ iOS)

No direct API between platforms. All communication flows through CloudKit Private DB:
- **macOS** (`CloudKitRelayService`): Uses `CKSyncEngine` to relay messages between iOS and local Gateway
- **iOS** (`CloudKitMessageClient`): Polls for changes (5s foreground, 30s background)
- **Dashboard** (`DashboardSyncService`): macOS pushes `DashboardSnapshot` every 30s for iOS dashboard view
- **Shared record**: `MessageRecord` with direction (`toGateway`/`fromGateway`) and status tracking

### Service Injection Pattern

- **macOS**: AppState instantiates services, passes them down through view initializers
- **iOS**: Uses SwiftUI `.environment()` for `@Observable` singletons (`CloudKitMessageClient`, `DashboardSnapshotStore`, `NavigationState`)

### Data Storage

- **UserDefaults**: Gateway port, auth token, onboarding completion flag, read timestamps
- **File cache**: `ChatMessageStore` uses MD5-hashed session keys in `~/Library/Application Support/ClawTower/chat-cache/`
- **CloudKit**: `MessageRecord` and `DashboardSnapshot` in iCloud Private DB
- **Data directory**: `~/Library/Application Support/ClawTower/` (fresh install) or `~/.openclaw/` (existing install)

## Development Rules

1. Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete` — all async/await, no completion handlers
2. ViewModels use `@Observable` (NOT `ObservableObject`)
3. No hardcoded Gateway port — always use dynamic port assignment
4. Gateway status is an enum state machine (see `GatewayManager.State`)
5. All user-facing strings must be localizable
6. Target audience is non-technical users — error messages must be human-friendly, no jargon
7. macOS app is NOT sandboxed

## Key Dependencies

- **Sparkle** (≥2.6.0): Auto-updates for macOS
- **MarkdownUI** (≥2.0.0): Markdown rendering (both targets)
