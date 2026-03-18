import SwiftUI

struct SkillMissing: Codable, Sendable {
    var bins: [String]
    var anyBins: [String]
    var env: [String]
    var config: [String]
    var os: [String]

    var isEmpty: Bool {
        bins.isEmpty && anyBins.isEmpty && env.isEmpty && config.isEmpty && os.isEmpty
    }

    var summary: String? {
        var parts: [String] = []
        if !bins.isEmpty {
            parts.append("命令行工具：\(bins.joined(separator: ", "))")
        }
        if !anyBins.isEmpty {
            parts.append("可选工具（任一）：\(anyBins.joined(separator: ", "))")
        }
        if !env.isEmpty {
            parts.append("环境变量：\(env.joined(separator: ", "))")
        }
        if !config.isEmpty {
            parts.append("配置项：\(config.joined(separator: ", "))")
        }
        if !os.isEmpty {
            parts.append("系统限制：\(os.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct SkillInstallOption: Codable, Sendable {
    var id: String
    var kind: String
    var label: String
    var bins: [String]
}

struct Skill: Identifiable, Codable, Sendable {
    var name: String
    var description: String?
    var emoji: String?
    var eligible: Bool
    var disabled: Bool
    var blockedByAllowlist: Bool
    var source: String
    var bundled: Bool
    var homepage: String?
    var missing: SkillMissing
    var install: [SkillInstallOption]?

    var id: String { name }

    var displayEmoji: String { emoji ?? "📦" }
    var canBeEnabled: Bool { eligible && !blockedByAllowlist }
    var hasInstallOptions: Bool { !(install ?? []).isEmpty }

    /// Whether the only blocker is missing OS support — nothing the user can do about it
    var blockedByOS: Bool { !missing.os.isEmpty }

    /// Whether bins might be installable — true if we have install info, or bins are the
    /// only (or part of the) missing requirement (most can be installed via brew/npm/go)
    var needsBinInstall: Bool { !missing.bins.isEmpty || !missing.anyBins.isEmpty }

    /// Whether the skill needs env vars to be configured
    var needsEnvConfig: Bool { !missing.env.isEmpty }

    /// Whether the skill needs config entries (channels, plugins, etc.)
    var needsAppConfig: Bool { !missing.config.isEmpty }

    /// In onboarding, only OS-blocked and allowlist-blocked skills are truly untoggleable
    var canBeToggledInOnboarding: Bool { !blockedByAllowlist && !blockedByOS }
    var missingSummary: String? { missing.summary }

    var sourceLabel: String {
        switch source {
        case "openclaw-bundled": return "bundled"
        case "openclaw-extra": return "extra"
        case "openclaw-workspace": return "workspace"
        default: return source
        }
    }

    enum Status {
        case ready, missingDeps, disabled
    }

    var status: Status {
        if disabled { return .disabled }
        if !eligible { return .missingDeps }
        return .ready
    }

    var onboardingStatusText: String {
        if blockedByAllowlist {
            return "当前环境未开放此技能"
        }
        switch status {
        case .ready:
            return disabled ? "可启用" : "已启用"
        case .missingDeps:
            return "缺少依赖，暂时不能启用"
        case .disabled:
            return canBeEnabled ? "可启用" : "暂时不可启用"
        }
    }

    var onboardingStatusColor: Color {
        if blockedByAllowlist {
            return .orange
        }
        switch status {
        case .ready:
            return .green
        case .missingDeps, .disabled:
            return canBeEnabled ? .secondary : .orange
        }
    }
}

struct SkillsListResponse: Codable, Sendable {
    var workspaceDir: String?
    var managedSkillsDir: String?
    var skills: [Skill]
}
