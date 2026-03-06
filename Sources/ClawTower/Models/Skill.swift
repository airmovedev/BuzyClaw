import Foundation

struct SkillMissing: Codable, Sendable {
    var bins: [String]
    var anyBins: [String]
    var env: [String]
    var config: [String]
    var os: [String]

    var isEmpty: Bool {
        bins.isEmpty && anyBins.isEmpty && env.isEmpty && config.isEmpty && os.isEmpty
    }
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

    var id: String { name }

    var displayEmoji: String { emoji ?? "📦" }

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
}

struct SkillsListResponse: Codable, Sendable {
    var workspaceDir: String?
    var managedSkillsDir: String?
    var skills: [Skill]
}
