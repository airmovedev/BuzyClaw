import Foundation
import AppKit

@MainActor
@Observable
final class SkillsService {
    private(set) var skills: [Skill] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var installingSkills: Set<String> = []
    /// User-visible status message during install (e.g. "正在安装 Homebrew…")
    private(set) var installStatusMessage: [String: String] = [:]
    /// Install progress per skill (0.0 to 1.0)
    private(set) var installProgress: [String: Double] = [:]
    private var configDirectoryOverride: URL?
    private var cachedUserPath: String?
    /// Tracks which package managers we've confirmed as available
    private var verifiedTools: Set<String> = []

    enum InstallResult {
        case success
        case failed(String)
        /// Tool is missing and requires Terminal interaction (e.g. sudo password)
        case needsTerminal(command: String, reason: String)
    }

    /// Describes how to actually install a binary, overriding upstream metadata when it's wrong.
    private struct InstallOverride {
        enum Method {
            /// Standard `brew install <formula>`
            case brewFormula(String)
            /// `brew install <tap>/<formula>` — will auto-tap first
            case brewTap(tap: String, formula: String)
            /// `brew install --cask <cask>`
            case brewCask(String)
            /// `npm install -g <package>`
            case npm(String)
            /// `go install <path>@latest`
            case goInstall(String)
            /// `pip3 install <package>`
            case pip(String)
            /// Tool is built into macOS — no install needed
            case builtIn
            /// Not available via any package manager; show guidance
            case manual(String)
        }

        let method: Method
        /// Optional: the binary this provides (if different from the key)
        let providesBins: [String]?

        init(_ method: Method, providesBins: [String]? = nil) {
            self.method = method
            self.providesBins = providesBins
        }
    }

    // MARK: - Install override map
    // Maps binary names (from OpenClaw skill metadata) to correct install commands.
    // Many upstream skills specify wrong Homebrew formula names (using the binary name
    // instead of the actual formula), or list a brew kind when it should be npm/pip/etc.

    private static let installOverrides: [String: InstallOverride] = [
        // --- macOS built-in tools (no install needed) ---
        "sips":       InstallOverride(.builtIn),
        "swift":      InstallOverride(.builtIn),
        "qlmanage":   InstallOverride(.builtIn),
        "osascript":  InstallOverride(.builtIn),

        // --- Homebrew formula name differs from binary name ---
        "gog":        InstallOverride(.brewFormula("gogcli")),
        "rec":        InstallOverride(.brewFormula("sox"), providesBins: ["sox", "rec", "play", "soxi"]),
        "whisper":    InstallOverride(.brewFormula("openai-whisper")),
        "op":         InstallOverride(.brewCask("1password-cli")),

        // --- Standard Homebrew formulas (correct name, listed for completeness) ---
        "gifski":     InstallOverride(.brewFormula("gifski")),
        "trash":      InstallOverride(.brewFormula("trash")),
        "ffmpeg":     InstallOverride(.brewFormula("ffmpeg")),
        "sox":        InstallOverride(.brewFormula("sox")),
        "jq":         InstallOverride(.brewFormula("jq")),
        "gum":        InstallOverride(.brewFormula("gum")),
        "duti":       InstallOverride(.brewFormula("duti")),
        "mas":        InstallOverride(.brewFormula("mas")),

        // --- Homebrew taps (formula not in core) ---
        "camsnap":    InstallOverride(.brewTap(tap: "steipete/tap", formula: "camsnap")),
        "gifgrep":    InstallOverride(.brewTap(tap: "steipete/tap", formula: "gifgrep")),
        "goplaces":   InstallOverride(.brewTap(tap: "steipete/tap", formula: "goplaces")),
        "sag":        InstallOverride(.brewTap(tap: "steipete/tap", formula: "sag")),
        "remindctl":  InstallOverride(.brewTap(tap: "steipete/tap", formula: "remindctl")),
        "peekaboo":   InstallOverride(.brewTap(tap: "steipete/tap", formula: "peekaboo")),
        "curl-impersonate": InstallOverride(.brewTap(tap: "shakacode/brew", formula: "curl-impersonate")),

        // --- npm packages (not brew) ---
        "nano-banana":     InstallOverride(.npm("@the-focus-ai/nano-banana")),
        "nano-banana-pro": InstallOverride(.npm("@the-focus-ai/nano-banana")),
        "mcp-discord":     InstallOverride(.npm("discord-mcp")),
        "mcp-youtube-transcript": InstallOverride(.npm("@kimtaeyoon83/mcp-server-youtube-transcript")),

        // --- pip packages (not brew) ---
        "mcp-server-fetch": InstallOverride(.pip("mcp-server-fetch")),
        "stt":              InstallOverride(.pip("sherpa-onnx"), providesBins: ["stt", "tts"]),
        "tts":              InstallOverride(.pip("sherpa-onnx"), providesBins: ["stt", "tts"]),

        // --- Cask installs ---
        "bluebubbles-cli": InstallOverride(.brewCask("bluebubbles")),

        // --- Not installable via package managers ---
        "discord-bot": InstallOverride(.manual("此功能由 OpenClaw 内置提供，请通过 openclaw channels add discord 配置")),
        "voicechat":   InstallOverride(.manual("此工具需要从源码编译，请参考技能文档")),
    ]

    private struct RuntimePaths {
        let nodeExecutable: URL
        let openclawScript: String
    }

    private nonisolated static func resolveRuntimePathsCandidates() -> [RuntimePaths] {
        var candidates: [RuntimePaths] = []
        let fm = FileManager.default

        // 1. Bundled runtime
        if let resourceURL = Bundle.main.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("Resources/runtime/node")
            let bundledOpenclaw = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs")
            if fm.fileExists(atPath: bundledNode.path)
                && fm.fileExists(atPath: bundledOpenclaw.path)
            {
                candidates.append(RuntimePaths(
                    nodeExecutable: bundledNode,
                    openclawScript: bundledOpenclaw.path
                ))
            }
        }

        // 2. System node + resolved openclaw.mjs
        let openclawBin = "/usr/local/bin/openclaw"
        let resolvedMjs: String? = {
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: openclawBin) {
                let resolved = dest.hasPrefix("/") ? dest : "/usr/local/bin/" + dest
                if fm.fileExists(atPath: resolved) { return resolved }
            }
            let commonPath = "/usr/local/lib/node_modules/openclaw/openclaw.mjs"
            if fm.fileExists(atPath: commonPath) { return commonPath }
            return nil
        }()

        let nodePaths = ["/usr/local/bin/node", "/opt/homebrew/bin/node"]
        let nodePath = nodePaths.first { fm.fileExists(atPath: $0) }

        if let nodePath, let resolvedMjs {
            candidates.append(RuntimePaths(
                nodeExecutable: URL(fileURLWithPath: nodePath),
                openclawScript: resolvedMjs
            ))
        }

        return candidates
    }

    /// Run an openclaw CLI command, trying each runtime candidate until one succeeds.
    private static func runOpenclawCLI(subcommand: [String]) async -> ProcessOutput {
        let candidates = resolveRuntimePathsCandidates()

        for (index, paths) in candidates.enumerated() {
            let output = await runProcessAsync(
                executableURL: paths.nodeExecutable,
                arguments: [paths.openclawScript] + subcommand
            )

            if output.exitCode == 0 {
                return output
            }

            // Check if this is a runtime startup error (not a real command error)
            let stderr = String(data: output.stderr, encoding: .utf8) ?? ""
            let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
            let combined = stderr + stdout
            let isStartupError = combined.contains("ERR_MODULE_NOT_FOUND")
                || combined.contains("Failed to start CLI")
                || combined.contains("Cannot find package")

            if isStartupError && index < candidates.count - 1 {
                NSLog("[SkillsService] Runtime startup error, trying next candidate")
                continue
            }

            return output
        }

        // No candidates at all
        return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "No openclaw runtime found".data(using: .utf8) ?? Data())
    }

    func configure(configDirectory: URL?) {
        configDirectoryOverride = configDirectory
    }

    func loadSkills() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let output = await Self.runOpenclawCLI(subcommand: ["skills", "list", "--json"])

        guard output.exitCode == 0 else {
            let stderr = String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stdout = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let combined = stderr.isEmpty ? stdout : stderr
            // Extract the most meaningful line for the user
            if combined.contains("ERR_MODULE_NOT_FOUND") || combined.contains("Cannot find package") {
                errorMessage = "运行环境缺少依赖包，请重新构建应用"
            } else {
                let lastLine = combined.split(separator: "\n").last.map(String.init) ?? ""
                errorMessage = "命令执行失败 (exit \(output.exitCode))" + (lastLine.isEmpty ? "" : "\n\(lastLine)")
            }
            return
        }

        guard let startIndex = output.stdout.firstIndex(of: UInt8(ascii: "{")) else {
            errorMessage = "无法解析 JSON 输出"
            return
        }

        do {
            let jsonData = Data(output.stdout[startIndex...])
            let response = try JSONDecoder().decode(SkillsListResponse.self, from: jsonData)
            var loaded = response.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Detect and repair "all disabled" corruption from onboarding.
            // If every skill is disabled, check the config: entries that only have
            // {"enabled": false} (no env, no other settings) were mass-written by
            // onboarding's persistAllSkillStates() and should be removed so the
            // CLI's defaults take effect.
            let allDisabled = !loaded.isEmpty && loaded.allSatisfy(\.disabled)
            if allDisabled {
                let repaired = await repairAllDisabledConfig()
                if repaired {
                    // Reload from CLI after config repair
                    let reloadOutput = await Self.runOpenclawCLI(subcommand: ["skills", "list", "--json"])
                    if reloadOutput.exitCode == 0,
                       let reloadStart = reloadOutput.stdout.firstIndex(of: UInt8(ascii: "{")) {
                        let reloadData = Data(reloadOutput.stdout[reloadStart...])
                        if let reloadResponse = try? JSONDecoder().decode(SkillsListResponse.self, from: reloadData) {
                            loaded = reloadResponse.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        }
                    }
                }
            }

            // Apply enabled/disabled state from openclaw.json directly.
            // The CLI may not always return the correct disabled state, so we
            // treat the config file as the source of truth.
            let configURL = resolvedConfigDirectory().appendingPathComponent("openclaw.json")
            let configJSON = await Self.readConfigAsync(url: configURL)
            if let skillsSection = configJSON["skills"] as? [String: Any],
               let entries = skillsSection["entries"] as? [String: Any] {
                for idx in loaded.indices {
                    if let entry = entries[loaded[idx].name] as? [String: Any],
                       let enabled = entry["enabled"] as? Bool {
                        loaded[idx].disabled = !enabled
                    }
                }
            }

            skills = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Remove skill entries from openclaw.json that only contain `{"enabled": false}`
    /// (mass-written by onboarding). Returns true if any entries were removed.
    private func repairAllDisabledConfig() async -> Bool {
        let configURL = resolvedConfigDirectory().appendingPathComponent("openclaw.json")
        var json = await Self.readConfigAsync(url: configURL)

        guard var skillsSection = json["skills"] as? [String: Any],
              var entries = skillsSection["entries"] as? [String: Any] else {
            return false
        }

        var removedCount = 0
        for (key, value) in entries {
            guard let entry = value as? [String: Any] else { continue }
            // Only remove entries that are bare {"enabled": false} — these were
            // mass-written by onboarding. Entries with env vars or other config
            // were intentionally configured by the user and should be preserved.
            if entry.count == 1, let enabled = entry["enabled"] as? Bool, !enabled {
                entries.removeValue(forKey: key)
                removedCount += 1
            }
        }

        guard removedCount > 0 else { return false }

        NSLog("[SkillsService] Repaired all-disabled config: removed \(removedCount) bare disabled entries")
        skillsSection["entries"] = entries
        json["skills"] = skillsSection
        try? await Self.writeConfigAsync(url: configURL, json: json)
        return true
    }

    /// Mark all skills as disabled (for onboarding, where users opt-in)
    func disableAllSkills() {
        for idx in skills.indices {
            skills[idx].disabled = true
        }
    }

    /// Persist only explicitly changed skill states to openclaw.json.
    /// Only writes entries for skills in `changedSkillNames` to avoid
    /// mass-disabling untouched skills (which caused the "all disabled" bug).
    func persistChangedSkillStates(_ changedSkillNames: Set<String>) {
        guard !changedSkillNames.isEmpty else { return }
        let configURL = resolvedConfigDirectory().appendingPathComponent("openclaw.json")
        let allSkills = skills
        Task.detached { [configURL] in
            var json = await Self.readConfigAsync(url: configURL)

            var skillsSection = json["skills"] as? [String: Any] ?? [:]
            var entries = skillsSection["entries"] as? [String: Any] ?? [:]
            for skill in allSkills where changedSkillNames.contains(skill.name) {
                var entry = entries[skill.name] as? [String: Any] ?? [:]
                entry["enabled"] = !skill.disabled
                entries[skill.name] = entry
            }
            skillsSection["entries"] = entries
            json["skills"] = skillsSection

            try? await Self.writeConfigAsync(url: configURL, json: json)
        }
    }

    /// Fetch install info for a single skill from `skills info --json`
    func fetchInstallInfo(for skillName: String) async -> [SkillInstallOption] {
        let output = await Self.runOpenclawCLI(subcommand: ["skills", "info", skillName, "--json"])

        guard output.exitCode == 0,
              let startIndex = output.stdout.firstIndex(of: UInt8(ascii: "{")) else {
            return []
        }

        do {
            let jsonData = Data(output.stdout[startIndex...])
            struct SkillInfo: Codable {
                var install: [SkillInstallOption]?
            }
            let info = try JSONDecoder().decode(SkillInfo.self, from: jsonData)
            let options = info.install ?? []

            if let idx = skills.firstIndex(where: { $0.name == skillName }) {
                skills[idx].install = options
            }

            return options
        } catch {
            return []
        }
    }

    /// Install binary dependencies for a skill
    func installSkillDependencies(name: String) async -> InstallResult {
        installingSkills.insert(name)
        installStatusMessage[name] = "正在检查安装环境…"
        installProgress[name] = 0.05
        defer {
            installingSkills.remove(name)
            installStatusMessage.removeValue(forKey: name)
            installProgress.removeValue(forKey: name)
        }

        // First, check if any of the missing bins have direct overrides
        let skill = skills.first(where: { $0.name == name })
        let missingBins = (skill?.missing.bins ?? []) + (skill?.missing.anyBins ?? [])

        // Collect all bins that have overrides and need to be installed individually
        var binsWithOverrides: [(String, InstallOverride)] = []
        var binsWithoutOverrides: [String] = []

        for bin in missingBins {
            if let override = Self.installOverrides[bin] {
                binsWithOverrides.append((bin, override))
            } else {
                binsWithoutOverrides.append(bin)
            }
        }

        // Calculate total steps for progress tracking
        let installableOverrides = binsWithOverrides.filter {
            if case .builtIn = $0.1.method { return false }
            return true
        }
        let totalSteps = max(installableOverrides.count + (binsWithoutOverrides.isEmpty ? 0 : 1), 1)
        var completedSteps = 0

        installProgress[name] = 0.1

        // Install overridden bins first
        for (bin, override) in binsWithOverrides {
            if case .builtIn = override.method {
                // Built-in tools need no install, skip
                continue
            }
            installStatusMessage[name] = "正在安装 \(bin)…"
            let result = await executeOverride(override, binName: bin)
            switch result {
            case .success:
                completedSteps += 1
                installProgress[name] = 0.1 + 0.75 * (Double(completedSteps) / Double(totalSteps))
                continue
            case .failed, .needsTerminal:
                return result
            }
        }

        // For bins without overrides, fall back to upstream install options
        if !binsWithoutOverrides.isEmpty {
            var installOptions = skill?.install ?? []
            if installOptions.isEmpty {
                installStatusMessage[name] = "正在获取安装信息…"
                installOptions = await fetchInstallInfo(for: name)
            }

            if let option = installOptions.first {
                // Filter to only bins that we haven't already handled via overrides
                let handledBins = Set(binsWithOverrides.map(\.0))
                let remainingBins = option.bins.filter { !handledBins.contains($0) }
                if !remainingBins.isEmpty {
                    let adjustedOption = SkillInstallOption(
                        id: option.id,
                        kind: option.kind,
                        label: option.label,
                        bins: remainingBins
                    )
                    installStatusMessage[name] = "正在安装 \(adjustedOption.label)…"
                    let result = await runInstallCommand(option: adjustedOption)
                    if case .success = result {
                        completedSteps += 1
                        installProgress[name] = 0.1 + 0.75 * (Double(completedSteps) / Double(totalSteps))
                    } else {
                        return result
                    }
                }
            } else if binsWithOverrides.isEmpty {
                // No overrides and no upstream install info
                return .failed("没有找到可用的安装方式")
            }
        }

        installStatusMessage[name] = "安装成功，刷新状态…"
        installProgress[name] = 0.9
        await reloadSkillsPreservingState(enabling: name)
        installProgress[name] = 1.0
        return .success
    }

    /// Save environment variables into openclaw.json for a skill
    func setSkillEnvVars(name: String, envVars: [String: String]) {
        let configURL = resolvedConfigDirectory().appendingPathComponent("openclaw.json")

        // Persist to disk in the background
        Task.detached { [configURL] in
            var json = await Self.readConfigAsync(url: configURL)

            var skillsSection = json["skills"] as? [String: Any] ?? [:]
            var entries = skillsSection["entries"] as? [String: Any] ?? [:]
            var entry = entries[name] as? [String: Any] ?? [:]
            var existingEnv = entry["env"] as? [String: String] ?? [:]
            for (key, value) in envVars {
                existingEnv[key] = value
            }
            entry["env"] = existingEnv
            entries[name] = entry
            skillsSection["entries"] = entries
            json["skills"] = skillsSection

            try? await Self.writeConfigAsync(url: configURL, json: json)
        }
    }

    private func reloadSkillsPreservingState(enabling name: String) async {
        // Instead of reloading the entire skills list (which causes a full list flash),
        // fetch only the updated info for the single skill that was just installed.
        let output = await Self.runOpenclawCLI(subcommand: ["skills", "info", name, "--json"])

        guard let idx = skills.firstIndex(where: { $0.name == name }) else { return }

        if output.exitCode == 0,
           let startIndex = output.stdout.firstIndex(of: UInt8(ascii: "{")) {
            do {
                let jsonData = Data(output.stdout[startIndex...])
                // skills info returns the same shape as a single Skill entry
                struct SkillRefresh: Codable {
                    var eligible: Bool?
                    var missing: SkillMissing?
                    var install: [SkillInstallOption]?
                }
                let refresh = try JSONDecoder().decode(SkillRefresh.self, from: jsonData)
                if let eligible = refresh.eligible {
                    skills[idx].eligible = eligible
                }
                if let missing = refresh.missing {
                    skills[idx].missing = missing
                }
                if let install = refresh.install {
                    skills[idx].install = install
                }
                skills[idx].disabled = false
            } catch {
                // Decode failed — optimistically mark as ready
                skills[idx].disabled = false
                skills[idx].missing.bins = []
                skills[idx].missing.anyBins = []
                skills[idx].eligible = true
            }
        } else {
            // Command failed — still enable the skill optimistically
            skills[idx].disabled = false
        }
    }

    /// Open Terminal.app with a command pre-filled for the user
    func openTerminalWithCommand(_ command: String) {
        let escapedCommand = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    // MARK: - Install infrastructure

    /// Look up an override for any of the given binary names
    private func findOverride(for bins: [String]) -> (String, InstallOverride)? {
        for bin in bins {
            if let override = Self.installOverrides[bin] {
                return (bin, override)
            }
        }
        return nil
    }

    private func runInstallCommand(option: SkillInstallOption) async -> InstallResult {
        // Check if any of the binaries have an override
        if let (binName, override) = findOverride(for: option.bins) {
            return await executeOverride(override, binName: binName)
        }

        // No override found — fall back to upstream metadata
        return await runUpstreamInstallCommand(option: option)
    }

    /// Execute an install using our verified override
    private func executeOverride(_ override: InstallOverride, binName: String) async -> InstallResult {
        switch override.method {
        case .builtIn:
            // Tool is built into macOS, nothing to install
            return .success

        case .brewFormula(let formula):
            let toolResult = await ensureToolAvailable("brew")
            guard case .success = toolResult else { return toolResult }
            cachedUserPath = nil
            return await runShellCommand("brew install \(formula)")

        case .brewTap(let tap, let formula):
            let toolResult = await ensureToolAvailable("brew")
            guard case .success = toolResult else { return toolResult }
            cachedUserPath = nil
            // Tap first, then install
            let tapResult = await runShellCommand("brew tap \(tap)")
            if case .failed(let msg) = tapResult {
                // Tap may already exist — only fail if it's a real error
                if !msg.contains("already tapped") {
                    return .failed("添加 \(tap) 源失败：\(msg)")
                }
            }
            return await runShellCommand("brew install \(tap)/\(formula)")

        case .brewCask(let cask):
            let toolResult = await ensureToolAvailable("brew")
            guard case .success = toolResult else { return toolResult }
            cachedUserPath = nil
            return await runShellCommand("brew install --cask \(cask)")

        case .npm(let package):
            let toolResult = await ensureToolAvailable("npm")
            guard case .success = toolResult else { return toolResult }
            cachedUserPath = nil
            return await runShellCommand("npm install -g \(package)")

        case .goInstall(let path):
            let toolResult = await ensureToolAvailable("go")
            guard case .success = toolResult else { return toolResult }
            cachedUserPath = nil
            let fullPath = path.contains("@") ? path : "\(path)@latest"
            return await runShellCommand("go install \(fullPath)")

        case .pip(let package):
            let toolResult = await ensureToolAvailable("pip3")
            guard case .success = toolResult else { return toolResult }
            cachedUserPath = nil
            return await runShellCommand("pip3 install \(package)")

        case .manual(let message):
            return .failed(message)
        }
    }

    /// Fallback: run install using the upstream metadata as-is (when no override exists)
    private func runUpstreamInstallCommand(option: SkillInstallOption) async -> InstallResult {
        let toolName: String
        let installCommand: String

        switch option.kind {
        case "brew":
            toolName = "brew"
            installCommand = "brew install \(option.bins.joined(separator: " "))"
        case "node":
            toolName = "npm"
            installCommand = "npm install -g \(option.bins.joined(separator: " "))"
        case "go":
            toolName = "go"
            let packages = option.bins.map { $0.contains("@") ? $0 : "\($0)@latest" }
            installCommand = "go install \(packages.joined(separator: " "))"
        case "uv":
            toolName = "uv"
            installCommand = "uv tool install \(option.bins.joined(separator: " "))"
        case "pip":
            toolName = "pip3"
            installCommand = "pip3 install \(option.bins.joined(separator: " "))"
        case "download":
            return .failed("此技能需要手动下载配置，请参考技能文档")
        default:
            return .failed("不支持的安装方式：\(option.kind)")
        }

        let toolResult = await ensureToolAvailable(toolName)
        switch toolResult {
        case .failed(let msg):
            return .failed(msg)
        case .needsTerminal(let cmd, let reason):
            return .needsTerminal(command: cmd, reason: reason)
        case .success:
            break
        }

        cachedUserPath = nil
        return await runShellCommand(installCommand)
    }

    /// Ensure a package manager tool is available, installing it if possible
    private func ensureToolAvailable(_ tool: String) async -> InstallResult {
        if verifiedTools.contains(tool) { return .success }

        // Check if tool exists in user's PATH
        let checkResult = await runShellCommand("command -v \(tool)")
        if case .success = checkResult {
            verifiedTools.insert(tool)
            return .success
        }

        // Tool not found — try to install it
        switch tool {
        case "brew":
            return await installHomebrew()
        case "npm":
            // npm comes with node; install via brew
            let brewResult = await ensureToolAvailable("brew")
            if case .success = brewResult {
                let nodeResult = await runShellCommand("brew install node")
                if case .success = nodeResult {
                    cachedUserPath = nil
                    verifiedTools.insert("npm")
                    verifiedTools.insert("node")
                    return .success
                }
                return nodeResult
            }
            return brewResult
        case "go":
            let brewResult = await ensureToolAvailable("brew")
            if case .success = brewResult {
                let goResult = await runShellCommand("brew install go")
                if case .success = goResult {
                    cachedUserPath = nil
                    verifiedTools.insert("go")
                    return .success
                }
                return goResult
            }
            return brewResult
        case "uv":
            // uv can be installed via brew or its own installer
            let brewResult = await ensureToolAvailable("brew")
            if case .success = brewResult {
                let uvResult = await runShellCommand("brew install uv")
                if case .success = uvResult {
                    cachedUserPath = nil
                    verifiedTools.insert("uv")
                    return .success
                }
                return uvResult
            }
            return brewResult
        case "pip3":
            // pip3 usually comes with python3 which is in Xcode CLT
            verifiedTools.insert("pip3")
            return .success
        default:
            return .failed("未知工具：\(tool)")
        }
    }

    /// Install Homebrew non-interactively
    private func installHomebrew() async -> InstallResult {
        // Homebrew's official install script with NONINTERACTIVE mode
        // This avoids the "Press RETURN" prompt but still needs sudo for /opt/homebrew ownership
        let brewInstallScript = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

        // Try NONINTERACTIVE first (works if user already has sudo cached or doesn't need it)
        let result = await runShellCommand("NONINTERACTIVE=1 \(brewInstallScript)")
        if case .success = result {
            cachedUserPath = nil
            verifiedTools.insert("brew")
            return .success
        }

        // NONINTERACTIVE failed — the user likely needs to enter their password.
        // Use the native macOS authorization dialog (much friendlier than Terminal for non-technical users).
        let authResult = await runShellCommandWithAdminPrivileges(
            "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        )
        if case .success = authResult {
            cachedUserPath = nil
            verifiedTools.insert("brew")
            return .success
        }

        // If the native dialog also failed (user cancelled or error), fall back to Terminal.
        // Use NONINTERACTIVE=1 to skip the "Press RETURN to continue" prompt — the user
        // only needs to enter their sudo password.
        return .needsTerminal(
            command: "NONINTERACTIVE=1 \(brewInstallScript)",
            reason: "Homebrew 安装需要管理员密码"
        )
    }

    /// Run a shell command with macOS native administrator privileges dialog.
    /// Uses AppleScript's `with administrator privileges` which shows the system auth prompt.
    private func runShellCommandWithAdminPrivileges(_ command: String) async -> InstallResult {
        let userPath = await getUserPath()
        let fullCommand = "export PATH=\"\(userPath):/opt/homebrew/bin:/usr/local/bin\"; \(command)"
        // Escape for AppleScript string embedding
        let escapedCommand = fullCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"

        // Use osascript process to avoid NSAppleScript main-thread concerns.
        // The admin dialog is system-level and works from any thread.
        let output = await Self.runProcessAsync(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script]
        )

        if output.exitCode == 0 {
            return .success
        }

        let errorOutput = String(data: output.stderr, encoding: .utf8) ?? ""
        // Error -128 = user cancelled the auth dialog
        if errorOutput.contains("-128") || errorOutput.contains("User canceled") {
            return .failed("用户取消了授权")
        }
        return .failed(errorOutput.split(separator: "\n").last.map(String.init) ?? "授权执行失败")
    }

    /// Run a command in the user's login shell and return the result
    private func runShellCommand(_ command: String) async -> InstallResult {
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let userPath = await getUserPath()
        let fullCommand = "export PATH=\"\(userPath):/opt/homebrew/bin:/usr/local/bin\"; \(command)"

        let output = await Self.runProcessAsync(
            executableURL: URL(fileURLWithPath: userShell),
            arguments: ["-l", "-c", fullCommand]
        )

        if output.exitCode == 0 {
            return .success
        } else {
            let errorOutput = String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lastLine = errorOutput.split(separator: "\n").last.map(String.init) ?? "执行失败"
            return .failed(lastLine)
        }
    }

    private func getUserPath() async -> String {
        if let cached = cachedUserPath { return cached }

        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let output = await Self.runProcessAsync(
            executableURL: URL(fileURLWithPath: userShell),
            arguments: ["-l", "-c", "echo $PATH"]
        )

        if output.exitCode == 0 {
            let result = String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !result.isEmpty {
                cachedUserPath = result
            }
            return result
        }
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    }

    func setSkillEnabled(name: String, enabled: Bool) {
        // Update in-memory model immediately so the UI reflects the change without delay
        if let idx = skills.firstIndex(where: { $0.name == name }) {
            skills[idx].disabled = !enabled
        }

        // Persist to disk in the background
        let configURL = resolvedConfigDirectory().appendingPathComponent("openclaw.json")
        Task.detached { [configURL] in
            var json = await Self.readConfigAsync(url: configURL)

            var skillsSection = json["skills"] as? [String: Any] ?? [:]
            var entries = skillsSection["entries"] as? [String: Any] ?? [:]
            var entry = entries[name] as? [String: Any] ?? [:]
            entry["enabled"] = enabled
            entries[name] = entry
            skillsSection["entries"] = entries
            json["skills"] = skillsSection

            try? await Self.writeConfigAsync(url: configURL, json: json)
        }
    }

    private func resolvedConfigDirectory() -> URL {
        if let configDirectoryOverride {
            return configDirectoryOverride
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openclaw")
    }

    // MARK: - Off-main-thread process execution

    /// Result from running a process off the main thread
    private struct ProcessOutput: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Run a Process completely off the main thread. This avoids blocking the UI
    /// since SkillsService is @MainActor.
    private nonisolated static func runProcessAsync(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async -> ProcessOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                if let environment {
                    process.environment = environment
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessOutput(
                        exitCode: -1,
                        stdout: Data(),
                        stderr: error.localizedDescription.data(using: .utf8) ?? Data()
                    ))
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: ProcessOutput(
                    exitCode: process.terminationStatus,
                    stdout: stdoutData,
                    stderr: stderrData
                ))
            }
        }
    }

    /// Write JSON config file off the main thread
    private nonisolated static func writeConfigAsync(url: URL, json: [String: Any]) async throws {
        let outputData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try outputData.write(to: url, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Read and parse JSON config file off the main thread
    private nonisolated static func readConfigAsync(url: URL) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: [:])
                    return
                }
                continuation.resume(returning: parsed)
            }
        }
    }
}
