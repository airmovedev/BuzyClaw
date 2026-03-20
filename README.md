<p align="center">
  <img src="SupportFiles/AppIcon.png" width="128" height="128" alt="BuzyClaw icon">
</p>

<h1 align="center">BuzyClaw / 虾忙</h1>

<p align="center">
  <strong>Native macOS & iOS client for <a href="https://github.com/openclaw/openclaw">OpenClaw</a> AI Agents</strong>
</p>

<p align="center">
  <a href="https://github.com/airmovedev/BuzyClaw/releases">
    <img src="https://img.shields.io/github/v/release/airmovedev/BuzyClaw?label=Download&style=flat-square" alt="Release">
  </a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20iOS%2018%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6-orange?style=flat-square" alt="Swift 6">
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="License">
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README_CN.md">中文</a>
</p>

---

## What is BuzyClaw?

BuzyClaw is a **native macOS & iOS app** that gives [OpenClaw](https://github.com/openclaw/openclaw) a proper GUI. Instead of managing your AI agents through terminal commands, BuzyClaw provides a visual interface to chat with agents, manage tasks, browse your second brain, and monitor everything from your menu bar.

> **Think of it as:** OpenClaw provides the AI agent runtime — BuzyClaw provides the native app experience on top of it.

## 📸 Screenshots

### Dashboard & Tasks
<p align="center">
  <img src="screenshots/Dashboard_tasks.png" width="800" alt="Dashboard with tasks overview">
</p>

### Agent Chat & Activity Feed
<p align="center">
  <img src="screenshots/Agents_chat&activity.png" width="800" alt="Agent chat interface with activity feed">
</p>

### Agent Detail
<p align="center">
  <img src="screenshots/AgentDetail.png" width="800" alt="Agent detail configuration">
</p>

### Second Brain
<p align="center">
  <img src="screenshots/SecondBrain.png" width="800" alt="Second brain knowledge base browser">
</p>

### Cron Jobs
<p align="center">
  <img src="screenshots/Cronjobs.png" width="800" alt="Cron jobs management">
</p>

### Settings
<p align="center">
  <img src="screenshots/Settings.png" width="800" alt="Settings panel">
</p>

### Usage Statistics
<p align="center">
  <img src="screenshots/UsageStatistic.png" width="800" alt="Model usage statistics">
</p>

## ✨ Features

### 🤖 Multi-Agent Management
- Create, configure, and switch between multiple AI agents
- Each agent has its own workspace, personality, and memory
- Visual agent cards with status indicators

### 💬 Native Chat Interface
- Real-time streaming chat with your agents
- Markdown rendering with syntax highlighting
- Distinguishes between user messages, agent replies, and inter-agent forwarded messages
- File attachments and image support

### 📋 Dashboard
- At-a-glance view of all agents, tasks, projects, and cron jobs
- Agent activity feed showing recent actions

### 🧠 Second Brain
- Browse and search your agent's knowledge base
- Markdown document viewer with full rendering

### ⏰ Cron & Automation
- View and manage scheduled tasks (daily reports, memory cleanup, etc.)
- See run history and next execution times

### 📊 Usage Statistics
- Track model usage across providers (Anthropic, OpenAI, etc.)
- Monitor rate limits and token consumption

### 📱 iOS Companion
- View agent status and chat from your iPhone
- CloudKit sync between macOS and iOS
- Dashboard, second brain, and cron management on the go

### 🖥️ macOS Comforts
- Menu bar resident — always accessible
- Sparkle auto-updates
- Native SwiftUI look and feel

## 🚀 Getting Started

### Download

Grab the latest DMG from the [Releases](https://github.com/airmovedev/BuzyClaw/releases) page.

1. Open the DMG
2. Drag **BuzyClaw** to your Applications folder
3. Launch BuzyClaw — it will set up the embedded OpenClaw runtime automatically

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

### Build from Source

```bash
# 1. Clone the repo
git clone https://github.com/airmovedev/BuzyClaw.git
cd BuzyClaw

# 2. Install xcodegen (if you don't have it)
brew install xcodegen

# 3. Generate Xcode project
xcodegen generate

# 4. Open and run
open ClawTower.xcodeproj
# Select the BuzyClaw_mac scheme → Run
```

#### iOS Target

The repo also includes an iOS target (`ClawTowerMobile`). It requires:
- A paired macOS instance running BuzyClaw
- CloudKit configuration (iCloud developer account)

## 🏗️ Architecture

```
Sources/
├── ClawTower/              # macOS app
│   ├── App/                # App entry, ContentView, menu bar
│   ├── Models/             # ChatMessage, Agent, Task, Project, etc.
│   ├── Services/
│   │   ├── Gateway/        # OpenClaw runtime management & API
│   │   └── CloudKit/       # macOS ↔ iOS sync
│   └── Views/
│       ├── Agent/          # Agent list, detail, creation
│       ├── Chat/           # Chat interface, message bubbles
│       ├── Dashboard/      # Main dashboard
│       ├── SecondBrain/    # Knowledge base browser
│       └── Settings/       # App settings, permissions
│
├── ClawTowerMobile/        # iOS companion app
│   ├── Models/             # Dashboard snapshots, sync models
│   ├── Services/           # CloudKit messaging client
│   └── Views/              # Mobile-optimized UI
│
Resources/
└── runtime/openclaw/       # Embedded OpenClaw runtime (MIT)
```

## 🔧 Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (Swift 6) |
| Platforms | macOS 14+, iOS 18+ |
| Project Gen | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| AI Runtime | [OpenClaw](https://github.com/openclaw/openclaw) (embedded) |
| Sync | CloudKit (macOS ↔ iOS) |
| Markdown | [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) |
| Auto-Update | [Sparkle](https://github.com/sparkle-project/Sparkle) |
| Signing | Developer ID + Apple Notarization |

## 🤝 Contributing

Contributions are welcome! Whether it's bug fixes, new features, or documentation improvements.

1. Fork the repo
2. Create your feature branch (`git checkout -b feature/awesome`)
3. Commit your changes (`git commit -m 'Add awesome feature'`)
4. Push to the branch (`git push origin feature/awesome`)
5. Open a Pull Request

### Development Notes

- The Xcode project name is still `ClawTower` internally — this is intentional to avoid breaking build configurations
- Run `xcodegen generate` after modifying `project.yml`
- The embedded OpenClaw runtime is bundled under `Resources/runtime/openclaw/`

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

The embedded OpenClaw runtime is also [MIT licensed](https://github.com/openclaw/openclaw/blob/main/LICENSE).

## 🙏 Acknowledgments

- [OpenClaw](https://github.com/openclaw/openclaw) — The AI agent runtime that powers everything
- [Sparkle](https://github.com/sparkle-project/Sparkle) — macOS update framework
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) — Beautiful Markdown rendering
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — Xcode project generation

---

<p align="center">
  <sub>Built with ❤️ by <a href="https://github.com/airmovedev">airmovedev</a></sub>
</p>
