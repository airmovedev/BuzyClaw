import SwiftUI
import AppKit

enum SkillFilter: String, CaseIterable {
    case all = "全部"
    case enabled = "已启用"
    case needsConfig = "需配置"
}

struct SkillsView: View {
    @State private var service = SkillsService()
    @State private var searchText = ""
    @State private var filter: SkillFilter = .all
    @State private var expandedSkills: Set<String> = []
    @State private var skillInstallErrors: [String: String] = [:]
    @State private var skillEnvInputs: [String: [String: String]] = [:]
    @State private var skillTerminalCommands: [String: String] = [:]

    private var filteredSkills: [Skill] {
        var result = service.skills

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                ($0.description?.lowercased().contains(query) ?? false)
            }
        }

        switch filter {
        case .all: break
        case .enabled:
            result = result.filter { $0.status == .ready }
        case .needsConfig:
            result = result.filter { $0.status == .missingDeps }
        }

        return result
    }

    var body: some View {
        let skills = filteredSkills
        VStack(spacing: 0) {
            // Toolbar area
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索技能…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 240)

                Picker("筛选", selection: $filter) {
                    ForEach(SkillFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)

                Spacer()

                Button {
                    NSWorkspace.shared.open(URL(string: "https://clawhub.ai")!)
                } label: {
                    Label("技能市场", systemImage: "bag")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("\(skills.count) 个技能")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Content
            if service.isLoading {
                Spacer()
                VStack(spacing: 18) {
                    ProgressView()
                        .controlSize(.regular)
                        .scaleEffect(1.05)
                    Text("正在加载技能列表…")
                        .font(.system(size: 15, weight: .semibold))
                    Text("先把技能清单拉回来，加载完再告诉你有哪些能开。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in
                            SkillPlaceholderRow()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                Spacer()
            } else if let error = service.errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("重试") {
                        Task { await service.loadSkills() }
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            } else if skills.isEmpty {
                Spacer()
                Text("没有匹配的技能")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                SkillScrollContent(
                    skills: skills,
                    expandedSkills: expandedSkills,
                    skillInstallErrors: skillInstallErrors,
                    skillTerminalCommands: skillTerminalCommands,
                    skillEnvInputs: skillEnvInputs,
                    onToggle: { skill, enabled in
                        handleSkillToggle(skill: skill, enabled: enabled)
                    },
                    onInstall: { name in
                        triggerSkillInstall(name)
                    },
                    onOpenTerminal: { name, command in
                        service.openTerminalWithCommand(command)
                        _ = withAnimation(.easeInOut(duration: 0.2)) {
                            skillTerminalCommands.removeValue(forKey: name)
                        }
                    },
                    onSkipTerminal: { name in
                        _ = withAnimation(.easeInOut(duration: 0.2)) {
                            skillTerminalCommands.removeValue(forKey: name)
                        }
                        service.setSkillEnabled(name: name, enabled: false)
                        _ = withAnimation(.easeInOut(duration: 0.2)) {
                            expandedSkills.remove(name)
                        }
                    },
                    onEnvInputChange: { name, key, value in
                        skillEnvInputs[name, default: [:]][key] = value
                    },
                    onEnvSave: { skill, inputs in
                        let trimmed = inputs.mapValues { $0.trimmingCharacters(in: .whitespaces) }
                        service.setSkillEnvVars(name: skill.name, envVars: trimmed)

                        if skill.needsBinInstall {
                            triggerSkillInstall(skill.name)
                        } else {
                            _ = withAnimation(.easeInOut(duration: 0.2)) {
                                expandedSkills.remove(skill.name)
                            }
                        }
                    }
                )
            }
        }
        .navigationTitle("技能库")
        .task {
            await service.loadSkills()
        }
    }

    // MARK: - Toggle Handling

    private func handleSkillToggle(skill: Skill, enabled: Bool) {
        skillInstallErrors.removeValue(forKey: skill.name)
        skillTerminalCommands.removeValue(forKey: skill.name)

        if enabled {
            service.setSkillEnabled(name: skill.name, enabled: true)

            let needsSetup = !skill.eligible && (skill.needsBinInstall || skill.needsEnvConfig || skill.needsAppConfig)
            if needsSetup {
                if skill.needsEnvConfig {
                    var inputs: [String: String] = [:]
                    for key in skill.missing.env {
                        inputs[key] = skillEnvInputs[skill.name]?[key] ?? ""
                    }
                    skillEnvInputs[skill.name] = inputs
                }
                _ = withAnimation(.easeInOut(duration: 0.2)) {
                    expandedSkills.insert(skill.name)
                }

                if skill.needsBinInstall && !skill.needsEnvConfig && !skill.needsAppConfig {
                    triggerSkillInstall(skill.name)
                }
            }
        } else {
            service.setSkillEnabled(name: skill.name, enabled: false)
            _ = withAnimation(.easeInOut(duration: 0.2)) {
                expandedSkills.remove(skill.name)
            }
        }
    }

    private func triggerSkillInstall(_ name: String) {
        skillInstallErrors.removeValue(forKey: name)
        skillTerminalCommands.removeValue(forKey: name)
        Task {
            let result = await service.installSkillDependencies(name: name)
            switch result {
            case .success:
                _ = withAnimation(.easeInOut(duration: 0.2)) {
                    expandedSkills.remove(name)
                }
            case .failed(let message):
                skillInstallErrors[name] = message
            case .needsTerminal(let command, _):
                skillTerminalCommands[name] = command
            }
        }
    }
}

// MARK: - Scroll Content (isolates scroll from @Observable service)

/// Uses a plain VStack (not Lazy) since skill count is small (~50).
/// LazyVStack caused main-thread freezes during fast scrolling due to
/// heavy view creation/destruction overhead with complex card rows.
private struct SkillScrollContent: View {
    let skills: [Skill]
    let expandedSkills: Set<String>
    let skillInstallErrors: [String: String]
    let skillTerminalCommands: [String: String]
    let skillEnvInputs: [String: [String: String]]
    let onToggle: (Skill, Bool) -> Void
    let onInstall: (String) -> Void
    let onOpenTerminal: (String, String) -> Void
    let onSkipTerminal: (String) -> Void
    let onEnvInputChange: (String, String, String) -> Void
    let onEnvSave: (Skill, [String: String]) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(skills) { skill in
                    SkillCardRow(
                        skill: skill,
                        isExpanded: expandedSkills.contains(skill.name),
                        installError: skillInstallErrors[skill.name],
                        terminalCommand: skillTerminalCommands[skill.name],
                        envInputs: skillEnvInputs[skill.name] ?? [:],
                        onToggle: { onToggle(skill, $0) },
                        onInstall: { onInstall(skill.name) },
                        onOpenTerminal: { cmd in onOpenTerminal(skill.name, cmd) },
                        onSkipTerminal: { onSkipTerminal(skill.name) },
                        onEnvInputChange: { key, val in onEnvInputChange(skill.name, key, val) },
                        onEnvSave: { inputs in onEnvSave(skill, inputs) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Skill Card Row (pure data, no @Observable references)

private struct SkillCardRow: View {
    let skill: Skill
    let isExpanded: Bool
    let installError: String?
    let terminalCommand: String?
    @Environment(\.themeColor) private var themeColor
    let envInputs: [String: String]
    let onToggle: (Bool) -> Void
    let onInstall: () -> Void
    let onOpenTerminal: (String) -> Void
    let onSkipTerminal: () -> Void
    let onEnvInputChange: (String, String) -> Void
    let onEnvSave: ([String: String]) -> Void

    private var isOn: Bool { !skill.disabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow

            if isOn && isExpanded {
                expandedSection
            }

            if let terminalCommand {
                terminalFallbackSection(terminalCommand)
            }

            if let installError, terminalCommand == nil {
                errorSection(installError)
            }

            if isOn, let homepage = skill.homepage, let url = URL(string: homepage) {
                homepageLink(url)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isOn ? themeColor.opacity(0.20) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Main Row

    private var mainRow: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                Text(skill.displayEmoji)
                    .font(.system(size: 20))
                    .frame(width: 28, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.system(size: 14, weight: .semibold))

                        skillRequirementBadge

                        Text(skill.sourceLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(sourceColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(sourceColor.opacity(0.12), in: Capsule())
                    }

                    if let description = skill.description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .scaleEffect(0.88)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Expanded Section

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.bottom, 2)

            if !skill.missing.isEmpty {
                missingDepsInfo
            }

            if skill.needsBinInstall {
                binInstallSection
            }

            if skill.needsEnvConfig {
                envSection
            }

            if skill.needsAppConfig {
                configHintSection
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var missingDepsInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !skill.missing.bins.isEmpty {
                Text("命令行工具: \(skill.missing.bins.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !skill.missing.anyBins.isEmpty {
                Text("可选工具（任一）: \(skill.missing.anyBins.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !skill.missing.env.isEmpty {
                Text("环境变量: \(skill.missing.env.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !skill.missing.config.isEmpty {
                Text("配置项: \(skill.missing.config.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !skill.missing.os.isEmpty {
                Text("不支持的系统: \(skill.missing.os.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var binInstallSection: some View {
        let allBins = skill.missing.bins + skill.missing.anyBins
        return VStack(alignment: .leading, spacing: 8) {
            Text("需要安装：\(allBins.joined(separator: ", "))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if terminalCommand == nil {
                Button {
                    onInstall()
                } label: {
                    Label("安装", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var envSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(skill.missing.env, id: \.self) { envKey in
                VStack(alignment: .leading, spacing: 4) {
                    Text(envKey)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    TextField("填写 \(Self.friendlyEnvName(envKey))", text: Binding(
                        get: { envInputs[envKey] ?? "" },
                        set: { onEnvInputChange(envKey, $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                }
            }

            let allFilled = skill.missing.env.allSatisfy { !(envInputs[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

            Button {
                onEnvSave(envInputs)
            } label: {
                Label(skill.needsBinInstall ? "保存并安装" : "保存", systemImage: "checkmark.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!allFilled)
        }
    }

    private var configHintSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("此技能需要额外配置才能使用：")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(skill.missing.config, id: \.self) { configKey in
                Text("• \(Self.friendlyConfigName(configKey))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("开启后，可在设置中完成配置。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Terminal Fallback

    private func terminalFallbackSection(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("自动安装未成功，需要在终端手动完成")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("点击下方按钮后，终端会打开并自动运行安装命令。终端中出现 Password 提示时，请输入你的 Mac 登录密码（输入时不会显示任何字符，这是正常的），然后按回车。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    onOpenTerminal(command)
                } label: {
                    Label("打开终端并安装", systemImage: "terminal")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    onSkipTerminal()
                } label: {
                    Text("跳过")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Error

    private func errorSection(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(3)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Homepage Link

    private func homepageLink(_ url: URL) -> some View {
        HStack {
            Spacer()
            Link(destination: url) {
                Label("主页", systemImage: "safari")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Badges

    @ViewBuilder
    private var skillRequirementBadge: some View {
        if !skill.eligible && !skill.disabled {
            if skill.needsBinInstall && skill.needsEnvConfig {
                skillBadge("需安装 + 配置", color: .orange)
            } else if skill.needsBinInstall {
                skillBadge("需安装依赖", color: .orange)
            } else if skill.needsEnvConfig {
                skillBadge("需填写密钥", color: .blue)
            } else if skill.needsAppConfig {
                skillBadge("需配置", color: .purple)
            } else if skill.blockedByOS {
                skillBadge("系统不支持", color: .red)
            }
        } else if skill.disabled {
            if skill.blockedByAllowlist {
                skillBadge("未开放", color: .orange)
            } else if skill.blockedByOS {
                skillBadge("系统不支持", color: .red)
            }
        }
    }

    private func skillBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var sourceColor: Color {
        switch skill.source {
        case "openclaw-bundled": return .blue
        case "openclaw-extra": return .purple
        case "openclaw-workspace": return .orange
        default: return .gray
        }
    }

    // MARK: - Helpers

    static func friendlyEnvName(_ key: String) -> String {
        if key.hasSuffix("_API_KEY") || key.hasSuffix("_TOKEN") {
            return "API 密钥"
        }
        if key.contains("DIR") || key.contains("PATH") {
            return "路径"
        }
        return "值"
    }

    static func friendlyConfigName(_ key: String) -> String {
        if key.hasPrefix("channels.") {
            let channel = key.replacingOccurrences(of: "channels.", with: "")
                .replacingOccurrences(of: ".token", with: "")
            return "连接 \(channel.capitalized) 频道"
        }
        if key.hasPrefix("plugins.entries.") {
            let plugin = key.replacingOccurrences(of: "plugins.entries.", with: "")
                .replacingOccurrences(of: ".enabled", with: "")
            return "启用 \(plugin) 插件"
        }
        return key
    }
}

// MARK: - Loading Placeholder

private struct SkillPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                    .frame(width: 132, height: 12)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
                    .frame(maxWidth: .infinity)
                    .frame(height: 10)
            }

            ProgressView()
                .controlSize(.small)
                .frame(width: 22)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.10), lineWidth: 1)
        )
        .redacted(reason: .placeholder)
    }
}
