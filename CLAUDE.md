# CLAUDE.md — ClawTower Project Guide

## What is ClawTower?
ClawTower is a macOS native app (SwiftUI) that embeds OpenClaw (Node.js AI Agent runtime) inside the app bundle, providing a GUI for non-technical users. See PRD.md, ARCHITECTURE.md, ONBOARDING.md for full specs.

## Key Architecture
- **macOS App** distributed via .dmg (NOT App Store) — no sandbox restrictions
- **Embeds Node.js binary + OpenClaw fork** inside app bundle Resources/
- **Swift main process** manages Gateway lifecycle (start/stop/restart via Process())
- **HTTP localhost (dynamic port)** for Swift ↔ Gateway communication
- **CloudKit Private DB** for macOS ↔ iOS communication
- **Data directory:** `~/Library/Application Support/ClawTower/`

## Tech Stack
- Swift 6, SwiftUI, macOS 14.0+
- xcodegen for project generation
- MarkdownUI for markdown rendering
- Sparkle for auto-updates
- EventKit for calendar/reminders
- CloudKit for iOS sync
- StoreKit 2 for subscriptions (future)

## Project Structure
```
ClawTower/
├── project.yml              # xcodegen spec
├── Sources/
│   ├── ClawTower/           # macOS app
│   │   ├── App/             # App entry, AppState, AppDelegate
│   │   ├── Models/          # Data models
│   │   ├── ViewModels/      # View models
│   │   ├── Views/           # SwiftUI views
│   │   │   ├── Onboarding/  # Setup wizard
│   │   │   ├── Chat/        # Conversation UI
│   │   │   ├── Sidebar/     # Navigation sidebar
│   │   │   ├── Dashboard/   # Overview dashboard
│   │   │   ├── SecondBrain/  # Memory browser
│   │   │   ├── Projects/    # Project board
│   │   │   ├── Tasks/       # Task management
│   │   │   ├── CronJobs/    # Scheduled tasks
│   │   │   ├── Skills/      # Skill management
│   │   │   ├── Settings/    # Settings pages
│   │   │   └── Components/  # Reusable components
│   │   ├── Services/        # Business logic
│   │   │   ├── Gateway/     # Gateway process management & API client
│   │   │   ├── CloudKit/    # iOS sync
│   │   │   └── System/      # EventKit, file access
│   │   ├── Utilities/       # Extensions, helpers
│   │   └── Resources/       # Assets, embedded runtime
│   └── ClawTowerMobile/     # iOS app (Phase 3)
├── SupportFiles/
│   ├── Info.plist
│   └── ClawTower.entitlements
├── PRD.md
├── ARCHITECTURE.md
├── ONBOARDING.md
└── PRODUCT.md
```

## Build & Run
```bash
xcodegen generate
open ClawTower.xcodeproj
# Or: xcodebuild -scheme ClawTower -configuration Debug build 2>&1 | tail -30
```

## Development Rules
1. Use Swift 6 strict concurrency
2. All network/async work via async/await
3. ViewModels are @Observable (not ObservableObject)
4. Prefer SwiftUI native components
5. No hardcoded Gateway port — use dynamic port assignment
6. All user-facing strings should be localizable (NSLocalizedString or String Catalogs)
7. Error messages: human-friendly, no technical jargon
8. Gateway status represented as enum state machine

## Phase 0 Goal (Current)
Build the app skeleton with:
1. xcodegen project.yml that builds
2. App entry point with menu bar support
3. GatewayManager service (start/stop/health check Node.js subprocess)
4. Basic sidebar navigation structure
5. Placeholder views for all major sections
6. Settings view with API key input (OAuth comes later)
7. Basic chat view that talks to Gateway via HTTP

## Important Notes
- This is NOT Watchtower. Completely separate codebase.
- macOS app is NOT sandboxed (distributed via .dmg)
- Target: non-technical users, all UI must be beginner-friendly
- Gateway communication: OpenClaw exposes OpenAI-compatible API at localhost
