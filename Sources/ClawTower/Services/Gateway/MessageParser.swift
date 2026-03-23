import Foundation

/// 集中解析 OpenClaw Gateway 返回的消息，兼容多版本格式
struct MessageParser {
    
    /// 判断一条消息是否为系统注入（非用户主动发送）
    static func isSystemInjected(role: String, content: Any?) -> Bool {
        // 1. 结构化检测：content 数组中包含 toolCall block
        if role == "user", let parts = content as? [[String: Any]] {
            let hasToolCall = parts.contains { ($0["type"] as? String) == "toolCall" }
            if hasToolCall { return true }
        }
        
        let text = extractText(from: content)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 2. 文本模式检测（兼容旧版）
        if role == "user" {
            // Heartbeat
            if trimmed.hasPrefix("Read HEARTBEAT.md") { return true }
            // Sub-agent announce
            if trimmed.hasPrefix("A background task") { return true }
            if trimmed.hasPrefix("[Queued announce") { return true }
            // System prefix
            if trimmed.hasPrefix("System:") { return true }
            // Summarize instruction (announce delivery)
            if trimmed.contains("Summarize this naturally for the user") { return true }
            // Cron/Gateway events with timestamp prefix
            if trimmed.hasPrefix("[") && trimmed.contains("GMT") {
                if trimmed.contains("Exec completed") || trimmed.contains("Exec failed") ||
                   trimmed.contains("GatewayRestart") || trimmed.contains("Cron:") ||
                   trimmed.contains("background task") { return true }
            }
            if trimmed.hasPrefix("[") && trimmed.contains("] A background task") { return true }
            // Config apply events
            if trimmed.contains("\"kind\":\"config-apply\"") || trimmed.contains("\"kind\": \"config-apply\"") { return true }
            // 3.1+ subagent completion event (new format)
            if trimmed.hasPrefix("[Internal task completion event]") { return true }
            if trimmed.contains("OpenClaw runtime context (internal)") { return true }
            if trimmed.contains("subagent task is ready for user delivery") { return true }
            // sessions_send results injected from other agents
            if trimmed.hasPrefix("[sessions_send") || trimmed.hasPrefix("[Tool: sessions_send") { return true }
        }
        
        // 3. 新版结构化事件检测（兼容 3.1+）
        if role == "user", let parts = content as? [[String: Any]] {
            for part in parts {
                if (part["type"] as? String) == "task_completion" { return true }
                if (part["type"] as? String) == "internalEvent" { return true }
            }
        }
        
        return false
    }
    
    /// 从 content（可能是 String 或 [[String: Any]]）提取纯文本
    static func extractText(from content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { block -> String? in
                let type = block["type"] as? String ?? "text"
                switch type {
                case "text":
                    return block["text"] as? String
                case "toolCall":
                    let name = block["name"] as? String ?? "unknown"
                    return "[调用工具: \(name)]"
                case "task_completion":
                    let label = block["label"] as? String ?? "子任务"
                    let status = block["status"] as? String ?? "completed"
                    return "[任务完成: \(label) (\(status))]"
                default:
                    return block["text"] as? String
                }
            }.joined(separator: "\n")
        }
        return ""
    }
    
    /// 从 content 中仅提取纯文本部分，跳过 toolCall 等非文本 block
    static func extractTextOnly(from content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { block -> String? in
                let type = block["type"] as? String ?? "text"
                switch type {
                case "text":
                    return block["text"] as? String
                case "task_completion":
                    let label = block["label"] as? String ?? "子任务"
                    let status = block["status"] as? String ?? "completed"
                    return "[任务完成: \(label) (\(status))]"
                default:
                    return nil
                }
            }.joined(separator: "\n")
        }
        return ""
    }

    /// 提取 toolCall blocks 的详情（兼容 arguments 和 input 两种字段名）
    static func extractToolCalls(from content: Any?) -> [(name: String, arguments: [String: Any])] {
        guard let arr = content as? [[String: Any]] else { return [] }
        return arr.compactMap { block in
            guard (block["type"] as? String) == "toolCall" else { return nil }
            let name = block["name"] as? String ?? "unknown"
            let args = block["arguments"] as? [String: Any] ?? block["input"] as? [String: Any] ?? [:]
            return (name: name, arguments: args)
        }
    }
    
    /// 判断是否为 HEARTBEAT_OK
    static func isHeartbeatOK(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "HEARTBEAT_OK"
    }
    
    /// 判断是否为 sub-agent 完成通知（兼容文本和结构化两种格式）
    /// 必须是系统注入的消息才可能是子任务完成通知
    static func isSubagentCompletion(role: String, content: Any?, isSystemInjected: Bool) -> Bool {
        if !isSystemInjected { return false }

        // 新版：content 包含 task_completion block
        if let arr = content as? [[String: Any]] {
            if arr.contains(where: { ($0["type"] as? String) == "task_completion" }) { return true }
        }

        let text = extractText(from: content)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 3.1+ 新格式
        if trimmed.hasPrefix("[Internal task completion event]") && trimmed.contains("source: subagent") { return true }
        if trimmed.contains("OpenClaw runtime context (internal)") && trimmed.contains("subagent") { return true }
        if trimmed.contains("subagent task is ready for user delivery") { return true }

        // 旧版：必须以 "A background task" 开头
        if trimmed.hasPrefix("A background task") && trimmed.contains("completed") { return true }

        // 带时间戳前缀的格式：[...] A background task
        if trimmed.hasPrefix("[") && trimmed.contains("] A background task") && trimmed.contains("completed") { return true }

        // Queued announce 格式：包含 "Queued announce" 且内含子任务完成通知
        if trimmed.contains("Queued announce") && trimmed.contains("A background task") && trimmed.contains("completed") { return true }

        return false
    }
    
    /// 提取 sub-agent 完成通知的任务名（兼容新旧格式）
    static func extractSubagentTaskName(from content: Any?) -> String {
        // 1. 新版：task_completion block
        if let arr = content as? [[String: Any]] {
            for block in arr {
                if (block["type"] as? String) == "task_completion" {
                    let label = block["label"] as? String ?? ""
                    if !label.isEmpty { return stripRolePrefix(label) }
                }
            }
        }
        
        // 1.5. 3.1+ 纯文本事件格式
        let rawText = extractText(from: content)
        if rawText.contains("[Internal task completion event]") || rawText.contains("OpenClaw runtime context (internal)") {
            let lines = rawText.components(separatedBy: .newlines)
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("task:") {
                    let name = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return stripRolePrefix(String(name.prefix(60))) }
                }
            }
        }

        let text = extractText(from: content)
        
        // 2. Queued announce 格式：定位到 "A background task" 那一行再提取
        let effectiveText: String
        if text.contains("Queued announce") && text.contains("A background task") {
            let lines = text.components(separatedBy: .newlines)
            effectiveText = lines.first(where: { $0.contains("A background task") }) ?? text
        } else {
            effectiveText = text
        }

        // 3. 尝试提取引号内容 — 支持多种引号格式
        // 普通双引号
        if let start = effectiveText.range(of: "background task \""),
           let end = effectiveText.range(of: "\" just") {
            let nameStart = start.upperBound
            if nameStart < end.lowerBound {
                let name = String(effectiveText[nameStart..<end.lowerBound]).prefix(60)
                return stripRolePrefix(String(name))
            }
        }
        // 中文引号
        if let start = effectiveText.range(of: "background task「"),
           let end = effectiveText.range(of: "」") {
            let nameStart = start.upperBound
            if nameStart < end.lowerBound {
                let name = String(effectiveText[nameStart..<end.lowerBound]).prefix(60)
                return stripRolePrefix(String(name))
            }
        }
        // 通用正则 fallback
        let quotePatterns = [
            #""([^"]+)""#,
            #"「([^」]+)」"#,
            #"\"([^\"]+)\""#,
        ]
        for pattern in quotePatterns {
            if let match = effectiveText.range(of: pattern, options: .regularExpression) {
                let title = String(effectiveText[match].dropFirst(1).dropLast(1).prefix(60))
                if title != "A background task" && !title.isEmpty {
                    return stripRolePrefix(title)
                }
            }
        }
        
        // 3. 最终 fallback
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let first = lines.first {
            let trimmed = String(first.prefix(60))
            if trimmed.contains("Stats:") { return "子任务" }
            if trimmed.hasPrefix("A background task") { return "子任务" }
            return stripRolePrefix(trimmed)
        }
        return "子任务"
    }
    
    /// 去掉角色前缀
    private static func stripRolePrefix(_ title: String) -> String {
        let prefixes = ["工程师: ", "工程师：", "设计师: ", "设计师：", "产品经理: ", "产品经理："]
        for prefix in prefixes {
            if title.hasPrefix(prefix) { return String(title.dropFirst(prefix.count)) }
        }
        return title
    }
    
    /// 提取工具调用的详情参数
    static func toolDetail(name: String, arguments: [String: Any]) -> String {
        switch name.lowercased() {
        case "exec":
            if let cmd = arguments["command"] as? String { return String(cmd.prefix(120)) }
        case "read":
            if let fp = arguments["file_path"] as? String ?? arguments["path"] as? String { return fp }
        case "write":
            if let fp = arguments["file_path"] as? String ?? arguments["path"] as? String { return fp }
        case "edit":
            if let fp = arguments["file_path"] as? String ?? arguments["path"] as? String { return fp }
        case "web_search":
            if let q = arguments["query"] as? String { return String(q.prefix(80)) }
        case "web_fetch":
            if let u = arguments["url"] as? String { return String(u.prefix(80)) }
        case "message":
            if let t = arguments["target"] as? String { return "→ \(t)" }
        case "browser":
            if let a = arguments["action"] as? String { return a }
        case "sessions_spawn":
            if let label = arguments["label"] as? String { return label }
            if let task = arguments["task"] as? String { return String(task.prefix(60)) }
        case "cron":
            if let a = arguments["action"] as? String { return a }
        case "memory_search":
            if let q = arguments["query"] as? String { return String(q.prefix(60)) }
        default:
            break
        }
        return ""
    }
    
    /// 工具的中文摘要名
    static func toolSummary(_ name: String) -> String {
        switch name.lowercased() {
        case "exec": return "执行命令"
        case "read": return "读取文件"
        case "write": return "写入文件"
        case "edit": return "编辑文件"
        case "web_search": return "搜索网页"
        case "web_fetch": return "获取网页"
        case "browser": return "浏览器操作"
        case "message": return "发送消息"
        case "tts": return "语音合成"
        case "image": return "分析图片"
        case "nodes": return "节点操作"
        case "canvas": return "画布操作"
        case "process": return "进程管理"
        case "sessions_spawn": return "分派任务"
        case "sessions_send": return "发送会话消息"
        case "sessions_list": return "列出会话"
        case "cron": return "定时任务"
        case "memory_search": return "搜索记忆"
        case "memory_get": return "读取记忆"
        case "session_status": return "会话状态"
        default: return name
        }
    }
    
    /// 工具的 SF Symbol 图标
    static func toolIcon(_ name: String) -> String {
        switch name.lowercased() {
        case "exec", "process": return "terminal"
        case "read": return "doc.text"
        case "write": return "doc.badge.plus"
        case "edit": return "pencil"
        case "web_search": return "magnifyingglass"
        case "web_fetch": return "globe"
        case "browser": return "safari"
        case "message": return "paperplane"
        case "tts": return "speaker.wave.2"
        case "image": return "photo"
        case "nodes": return "server.rack"
        case "canvas": return "paintbrush"
        case "sessions_spawn": return "arrow.triangle.branch"
        case "sessions_send": return "paperplane"
        case "sessions_list": return "list.bullet"
        case "cron": return "clock"
        case "memory_search", "memory_get": return "brain"
        case "session_status": return "chart.bar"
        default: return "wrench"
        }
    }
}
