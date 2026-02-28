# ClawTower — 系统架构设计

> 定位：面向小白用户的本地 AI Agent 客户端
> 分发：macOS 官网分发（.dmg）+ iOS App Store
> 阶段：免费 + OAuth（用户自备 API），后期加订阅

---

## 1. 产品全景

```
┌──────────────────────────────────────────────────────┐
│                     用户视角                           │
│                                                        │
│   macOS App（官网下载 .dmg）    iOS App（App Store）   │
│   ┌───────────────────┐        ┌─────────────────┐    │
│   │ 原生 SwiftUI UI   │        │ 远程控制 & 对话  │    │
│   │ 内嵌 OpenClaw      │◄──────►│ CloudKit 中转   │    │
│   │ 零配置，开箱即用   │ iCloud │ 推送通知         │    │
│   │ 无沙盒限制         │        │ 订阅付费入口     │    │
│   └───────────────────┘        └─────────────────┘    │
└──────────────────────────────────────────────────────┘
```

**核心原则：** 用户永远不需要打开终端、不需要知道什么是 Node.js、不需要手动编辑配置文件。

---

## 2. 分发策略

| 平台 | 分发方式 | 签名 | 审核风险 | 付费 |
|------|---------|------|---------|------|
| macOS | 官网 .dmg 下载 | Developer ID + 公证（Notarization） | 无（不走 App Store） | Stripe / LemonSqueezy |
| iOS | App Store | App Store 签名 | 正常审核（无 Node.js） | StoreKit 2 订阅 |

**macOS 不上 App Store 的好处：**
- 无沙盒限制，Node.js 子进程、文件访问、shell 工具全部可用
- 无审核风险，内嵌 Node.js + 插件系统不受 2.5.2 条款约束
- Agent 能力不受限（可访问用户授权的任意目录、执行工具）
- 更新节奏自主（Sparkle 自动更新，不受审核周期影响）

**iOS 上 App Store 的好处：**
- 获客渠道（App Store 搜索曝光）
- StoreKit 订阅（苹果生态用户习惯的付费方式）
- iOS 端本身不跑 Node.js，无审核风险

---

## 3. macOS App 架构

### 3.1 App Bundle 结构

```
ClawTower.app/
├── Contents/
│   ├── MacOS/
│   │   └── ClawTower            # Swift 主进程
│   ├── Resources/
│   │   ├── node                  # 内嵌 Node.js binary (~45MB)
│   │   ├── openclaw/             # OpenClaw 源码（fork 版）
│   │   │   ├── package.json
│   │   │   ├── node_modules/     # 预装依赖
│   │   │   └── ...
│   │   └── default-config.yaml   # 默认配置模板
│   ├── Frameworks/
│   └── Info.plist
```

### 3.2 Runtime 架构

```
┌─────────────────────────────────────────────┐
│              macOS App 进程                   │
│                                               │
│  ┌─────────────┐    ┌──────────────────────┐ │
│  │ Swift 主进程  │    │ Node.js 子进程       │ │
│  │              │    │                      │ │
│  │ • SwiftUI UI │◄──►│ • OpenClaw Gateway   │ │
│  │ • 生命周期管理│HTTP│ • Agent Runtime      │ │
│  │ • OAuth 管理  │    │ • 工具 & 插件系统    │ │
│  │ • CloudKit   │    │ • Memory / Cron      │ │
│  │ • 系统集成    │    │ • Skill 系统         │ │
│  └─────────────┘    └──────────────────────┘ │
│         │                     │               │
│         ▼                     ▼               │
│  ~/Library/Application Support/ClawTower/     │
│  ├── config.yaml     # 运行时配置             │
│  ├── workspace/      # Agent 工作区           │
│  ├── agents/         # Agent 数据             │
│  └── sessions/       # 会话历史               │
└─────────────────────────────────────────────┘
```

### 3.3 关键技术决策

| 决策项 | 方案 | 理由 |
|--------|------|------|
| Node.js 嵌入 | App Bundle 内置 binary | 用户零安装 |
| 进程管理 | Swift `Process()` 启动子进程 | App 启动时拉起，退出时 kill |
| 数据目录 | `~/Library/Application Support/ClawTower/` | 标准 macOS 应用数据目录 |
| 内部通信 | HTTP localhost（动态端口） | Gateway 原生支持 |
| API 认证 | OAuth 2.0 + API Key 双轨 | OAuth 优先，API Key 兜底 |
| 配置管理 | Swift 侧生成 config.yaml | 用户通过 GUI 设置 |
| 自动更新 | Sparkle 框架 | 标准 macOS 非 App Store 更新方案 |
| 签名 | Developer ID + Apple 公证 | macOS Gatekeeper 放行 |

### 3.4 系统权限集成

macOS 非沙盒 App，权限更自由：

| 能力 | 框架 | 实现方式 |
|------|------|---------|
| 文件管理（任意目录） | FileManager | 首次引导用户授权「完全磁盘访问」或通过文件选择器按需授权 |
| 日历读写 | EventKit | 系统弹窗授权 |
| 提醒事项读写 | EventKit | 系统弹窗授权 |
| 通知 | UserNotifications | 系统弹窗授权 |
| 开机自启 | SMAppService / LaunchAgent | 设置页开关 |

**非沙盒优势：** Agent 可以直接通过 OpenClaw 原生工具访问文件系统、执行命令，不需要 Swift 侧中转 REST API。权限由 macOS 系统级控制（TCC）。

### 3.5 Menu Bar 常驻

```
┌──────────────────────────────────┐
│  🏗️ ▼                            │
│  ┌────────────────────────────┐  │
│  │ ● ClawTower 运行中          │  │
│  │ ─────────────────────────  │  │
│  │ 打开主窗口                  │  │
│  │ 暂停 Agent                  │  │
│  │ ─────────────────────────  │  │
│  │ 设置...                     │  │
│  │ 检查更新...                 │  │
│  │ ─────────────────────────  │  │
│  │ 退出 ClawTower              │  │
│  └────────────────────────────┘  │
└──────────────────────────────────┘
```

- 关闭窗口 ≠ 退出，Gateway 继续后台运行
- Menu Bar icon 显示运行状态
- 完全退出时 kill Gateway 子进程

---

## 4. iOS App 架构

### 4.1 通信方案：CloudKit Private Database

```
┌──────────┐     CloudKit      ┌──────────┐
│  iOS App  │◄────Private DB───►│ macOS App│
│           │                   │          │
│ 发消息    │──► Message Record │ 轮询拉取  │
│           │                   │ → Gateway │
│ 收回复    │◄── Response Record│ → 写回    │
│           │                   │          │
│ 推送通知  │◄── CK Subscription│          │
└──────────┘                   └──────────┘
```

**优势：**
- 同一 iCloud 账号自动连接，零配置
- 无需公网 IP、端口映射、VPN
- Apple 原生方案，审核零风险
- 数据在用户自己的 iCloud 账户中，开发者无法触及

**设计要点：**
- CloudKit Subscription → 实时推送通知（不依赖轮询）
- 消息端到端加密（密钥存 Keychain，CloudKit 只存密文）
- 离线消息队列（iOS 离线时缓存，上线后批量发送）
- 消息去重（幂等键 + 顺序号）

### 4.2 iOS App 功能范围

| 功能 | 优先级 | 说明 |
|------|--------|------|
| 对话（文字） | P0 | 与 Agent 对话 |
| Agent 状态 | P0 | 查看 Agent 在线/离线状态 |
| 推送通知 | P0 | Agent 回复实时推送 |
| 订阅管理 | P0 | StoreKit 2 订阅入口 |
| 任务看板 | P1 | 查看/管理任务列表 |
| 第二大脑浏览 | P1 | 只读浏览 memory 文件 |
| 图片收发 | P2 | CKAsset 传输 |
| 快捷指令 | P2 | Siri / Shortcuts 集成 |
| Apple Watch | P3 | 手腕快速回复 |

### 4.3 macOS 状态感知

iOS 端需要清晰展示 macOS 端状态：

| macOS 状态 | iOS 显示 | 用户操作 |
|-----------|---------|---------|
| 在线运行中 | 🟢 在线 | 正常对话 |
| App 未启动 | 🔴 离线 · Mac 未启动 ClawTower | 提示用户打开 Mac 端 |
| Mac 睡眠 | 🟡 Mac 休眠中 | 提示唤醒 Mac 或等待 |
| 网络断开 | ⚪ Mac 网络不可用 | 消息排队，恢复后自动发送 |
| Token 过期 | 🟠 需要在 Mac 端重新登录 | 引导操作 |

---

## 5. API 认证方案

### 5.1 双轨认证

```
首次启动
    │
    ├─► "使用 Claude" ──► Anthropic OAuth（优先）
    │
    ├─► "使用 ChatGPT" ──► OpenAI OAuth（优先）
    │
    └─► "我有 API Key" ──► 手动输入（兜底，高级用户）
```

OAuth 和 API Key 双轨支持。OAuth 拿不到资质时 API Key 路径保底。

### 5.2 Token 管理

- OAuth token / API Key 存入 macOS Keychain
- Config.yaml 引用 Keychain 标识，不明文存储
- Token 刷新由 Swift 侧管理，透传给 Gateway
- 过期时 App 内弹窗引导重新授权

### 5.3 支持的 Provider

| Provider | 认证方式 | 阶段 |
|----------|----------|------|
| Anthropic (Claude) | OAuth + API Key | 首期 ✅ |
| OpenAI (ChatGPT) | OAuth + API Key | 首期 ✅ |
| Google (Gemini) | OAuth + API Key | 二期 |
| 本地模型 (Ollama) | 无需认证 | 二期 |

---

## 6. 订阅与商业化

### 6.1 付费架构

```
┌─────────────────────────────────────────────┐
│               订阅状态验证                     │
│                                               │
│  iOS 用户 ──► StoreKit 2 ──► Apple 抽成 15-30%│
│                    │                          │
│                    ▼                          │
│            iCloud 同步订阅状态                  │
│                    │                          │
│                    ▼                          │
│  macOS 端读取订阅状态 → 解锁付费功能            │
│                                               │
│  ─── 或 ───                                   │
│                                               │
│  macOS 用户 ──► Stripe/LemonSqueezy           │
│                    │          抽成 ~3%         │
│                    ▼                          │
│            License Key / 账号验证              │
│                    │                          │
│                    ▼                          │
│  macOS 端验证 → 解锁付费功能                   │
│  iOS 端同步状态 → 同步解锁                     │
└─────────────────────────────────────────────┘
```

### 6.2 免费 vs 付费功能（后期规划）

| 功能 | 免费 | 付费 |
|------|------|------|
| 基础对话 | ✅ | ✅ |
| 日历/提醒事项集成 | ✅ | ✅ |
| 文件管理 | 单文件夹 | 多文件夹 |
| 记忆系统 | 基础 | 完整第二大脑 |
| iOS 远程访问 | ✅ | ✅ |
| 多 Agent | ❌ | ✅ |
| 自动化任务（Cron） | ❌ | ✅ |
| 自定义 Skill/工具 | ❌ | ✅ |
| 优先支持 | ❌ | ✅ |

*注：初期全部免费，根据用户增长再开启付费。*

---

## 7. OpenClaw Fork 改造点

### 7.1 必须改

| 改造项 | 说明 |
|--------|------|
| 可配置数据目录 | 支持 `--data-dir` 参数，不硬编码 `~/.openclaw/` |
| 可配置端口 | 支持 `--port 0`（系统分配）并输出实际端口 |
| 去掉全局依赖 | 不依赖全局 npm、不写 `/usr/local/` |
| 配置文件路径 | 支持 `--config` 指定外部 config.yaml 路径 |
| 日志输出 | 结构化日志（JSON），Swift 侧可解析状态 |

### 7.2 可选改

| 改造项 | 说明 |
|--------|------|
| 健康检查端点 | `/health` API，Swift 侧轮询监控存活 |
| 优雅关闭 | 收到 SIGTERM 时完成当前请求再退出 |
| 资源限制 | 内存/CPU 使用上限，避免拖垮用户电脑 |

---

## 8. 数据流全景

```
用户操作 (macOS)                用户操作 (iOS)
     │                              │
     ▼                              ▼
SwiftUI View                  SwiftUI View
     │                              │
     ▼                              │
HTTP Request                        │
localhost:{port}                    │
     │                              ▼
     ▼                        CloudKit Record
OpenClaw Gateway ◄──────────── macOS App 轮询
     │                              │
     ├── Agent Runtime              │
     ├── Memory System              │
     ├── Cron Scheduler             │
     └── Tool & Skill 系统          │
           │                        │
           ▼                        ▼
     外部 API                  CloudKit Response
  (Claude/OpenAI)              → iOS 收到回复
```

---

## 9. 安全设计

| 层面 | 措施 |
|------|------|
| API Token | Keychain 存储，不落盘明文，不入日志 |
| CloudKit 通信 | 端到端加密（AES-256-GCM，每设备密钥存 Keychain） |
| 本地数据（macOS） | 依赖 FileVault 全盘加密 + Keychain 保护敏感字段 |
| 本地数据（iOS） | NSFileProtectionComplete（锁屏后加密） |
| 网络 | Gateway 仅监听 localhost，不暴露公网 |
| 进程通信 | localhost HTTP + 随机 session token 鉴权 |
| 日志安全 | token/prompt/文件路径脱敏，debug/release 分级 |
| 隐私声明 | "除用户主动请求 AI 模型时发送必要内容外，不向开发者或第三方上传任何数据" |

---

## 10. 技术风险 & 对策

| 风险 | 影响 | 对策 |
|------|------|------|
| Node.js binary 体积大 | .dmg 下载体积增加 ~45MB | 可接受；后续考虑 Bun 替代 |
| OAuth Provider 资质限制 | 用户无法 OAuth 登录 | API Key 双轨兜底 |
| CloudKit 延迟 | iOS 端响应慢 | Subscription 推送 + 本地缓存 + 乐观 UI |
| OpenClaw 上游大版本更新 | Fork 合并冲突 | 最小化改动，upstream-friendly 的改法 |
| macOS 睡眠 | iOS 端无法通信 | 状态机 + 消息排队 + 唤醒提示 |
| Gateway 崩溃 | Agent 不可用 | 指数退避重启 + 最大重启次数 + 用户提示 |
| Apple 公证失败 | macOS App 无法安装 | CI 流水线集成公证，发版前验证 |

---

## 11. 里程碑规划

### Phase 0 — 验证（1-2 周）
- [ ] Fork OpenClaw，验证 `--data-dir` + `--port` 改造
- [ ] macOS App 内成功启动 Gateway 子进程
- [ ] 通过 localhost 与 Gateway 通信
- [ ] OAuth / API Key 登录跑通
- [ ] Developer ID 签名 + 公证流程跑通

### Phase 1 — macOS MVP（3-4 周）
- [ ] Onboarding 引导流程
- [ ] 对话界面（单 Agent）
- [ ] Agent 状态展示
- [ ] 系统集成（日历、提醒事项、文件）
- [ ] Menu Bar 常驻
- [ ] Sparkle 自动更新
- [ ] 官网 + .dmg 下载页

### Phase 2 — iOS + 远程（2-3 周）
- [ ] iOS App（对话 + Agent 状态）
- [ ] CloudKit 中转通信
- [ ] 推送通知
- [ ] macOS ↔ iOS 自动配对（同一 iCloud）
- [ ] macOS 状态感知（在线/离线/睡眠）

### Phase 3 — 上架 & 完善（2-3 周）
- [ ] iOS App Store 提交
- [ ] 任务看板
- [ ] 第二大脑浏览器
- [ ] 官网落地页 & 文档
- [ ] 隐私政策 & 使用条款

### Phase 4 — 商业化（视增长决定）
- [ ] StoreKit 2 订阅（iOS）
- [ ] Stripe / LemonSqueezy 订阅（macOS）
- [ ] 订阅状态跨平台同步
- [ ] 付费功能 gate
