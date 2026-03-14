# BuzyClaw / 虾忙

BuzyClaw（中文名：虾忙）是一个基于 OpenClaw 构建的本地 AI Agent 客户端，用原生 macOS / iOS 界面把「住在你自己设备上的 AI 助手」做得更容易上手。

> 当前仓库仍保留部分内部工程命名（如 `ClawTower` 的工程名、目录名、Bundle 标识等），本次优先统一开源展示层文案与 README。

## What it does

BuzyClaw 不是又一个纯聊天壳子。它的目标是把 OpenClaw 的本地 Agent 能力，用更适合普通用户的产品形态交付出来。

基于当前仓库中的真实实现，项目已经包含这些方向的能力：

- **macOS 原生客户端**：SwiftUI 桌面应用，负责启动和管理本地 OpenClaw runtime
- **多 Agent 对话入口**：支持加载 Agent、查看会话，并在桌面端进入聊天界面
- **第二大脑浏览**：可浏览本地 `second-brain` 文档内容
- **任务 / 项目 / 定时任务 / Skills 管理界面**：仓库中已包含对应数据模型、服务层和界面结构
- **Menu Bar 常驻形态**：关闭主窗口后可隐藏到后台，通过菜单栏重新唤起
- **iOS 配套客户端**：仓库内包含 iOS target，用于远程查看 Agent、聊天、看板、第二大脑与定时任务
- **CloudKit 通信基础**：用于 macOS 与 iOS 间的数据同步 / 消息中转

## Why OpenClaw

BuzyClaw 基于 OpenClaw 构建。

- **OpenClaw** 提供底层 Agent runtime、Gateway、skills/tooling 能力
- **BuzyClaw / 虾忙** 负责把这些能力封装成更适合终端用户的原生应用体验

如果你熟悉 OpenClaw，可以把 BuzyClaw 理解为：**面向日常用户的 GUI 产品层**。

## Tech stack

当前仓库可见的主要技术栈：

- **Swift 6 + SwiftUI**
- **macOS 14+ / iOS 18+ targets**（以 `project.yml` 当前配置为准）
- **XcodeGen**：项目生成
- **CloudKit**：macOS / iOS 通信
- **MarkdownUI**：Markdown 渲染
- **Sparkle**：macOS 更新能力接入
- **Embedded OpenClaw runtime**：随 app 资源一同打包

## Repository structure

```text
.
├── README.md
├── PRODUCT.md
├── PRD.md
├── ARCHITECTURE.md
├── ONBOARDING.md
├── project.yml
├── Sources/
│   ├── ClawTower/         # macOS app source
│   └── ClawTowerMobile/   # iOS app source
├── SupportFiles/
└── Resources/runtime/openclaw/
```

## Install / run

### macOS

当前仓库里主要提供的是**源码工程**，适合本地构建运行：

1. 准备 Xcode（建议使用可支持 Swift 6 的版本）
2. 安装 `xcodegen`
3. 在仓库根目录执行：

```bash
xcodegen generate
open ClawTower.xcodeproj
```

然后在 Xcode 中选择 `ClawTower` scheme 运行。

### iOS

仓库中同时包含 iOS target：

- scheme：`ClawTowerMobile`
- 依赖 macOS 端 / CloudKit 配置配合使用
- 更适合作为开发态体验与联调入口，而不是当前仓库阶段下的开箱即用发行包说明

## Open source notes

当前仓库里可以确认的开源依赖信息：

- 内嵌的 `Resources/runtime/openclaw` 来自 **OpenClaw**
- 该目录下已包含上游 `LICENSE`
- `Resources/runtime/openclaw/package.json` 显示其 license 为 **MIT**

需要注意：

- **仓库根目录目前没有看到项目自己的 LICENSE 文件**
- 因此在正式公开到 GitHub 前，建议先明确 BuzyClaw 仓库本身采用什么许可证
- 在许可证未最终确定前，README 不对 BuzyClaw 自身许可证做杜撰声明

## Thanks

- [OpenClaw](https://github.com/openclaw/openclaw) — 提供底层 runtime 与生态基础
- [Sparkle](https://github.com/sparkle-project/Sparkle) — macOS 更新框架
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) — Markdown 渲染

## Current naming status

本次整理已优先统一**开源展示层**名称为：

- English: **BuzyClaw**
- 中文：**虾忙**

但以下内容仍可能暂时保留 `ClawTower`：

- Xcode 工程名 / target 名
- 部分源码内窗口标题、菜单标题
- Bundle identifier / iCloud container / 本地数据目录等内部实现命名

这些属于工程层重命名工作，和本次 README / 展示文案整理不是一回事。先别乱动，免得把工程搞炸。