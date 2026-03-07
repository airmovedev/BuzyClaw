import Foundation

struct Agent: Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    var emoji: String
    var roleDescription: String?
    var status: AgentStatus
    var model: String?
    var lastActivity: Date?

    enum AgentStatus: String, Sendable {
        case online
        case offline
        case starting
        case error
    }
}

struct AgentDraft: Sendable {
    var name: String = ""
    var emoji: String = "🤖"
    var roleDescription: String = ""
    var model: String = "anthropic/claude-sonnet-4-20250514"

    // 内置 provider 的基础模型（这些不在 openclaw.json 的 models.providers 中）
    private static let builtInModels = [
        "anthropic/claude-sonnet-4-20250514",
        "anthropic/claude-opus-4-6",
        "openai-codex/gpt-5.3-codex",
    ]

    // 动态读取 openclaw.json 中已配置的 provider 模型
    static var modelOptions: [String] {
        var result = builtInModels

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")

        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: Any],
              let providers = models["providers"] as? [String: Any]
        else {
            return result
        }

        for (providerId, providerValue) in providers {
            guard let providerDict = providerValue as? [String: Any],
                  let modelsList = providerDict["models"] as? [[String: Any]]
            else { continue }

            for modelEntry in modelsList {
                guard let modelId = modelEntry["id"] as? String else { continue }
                let fullId = "\(providerId)/\(modelId)"
                if !result.contains(fullId) {
                    result.append(fullId)
                }
            }
        }

        return result
    }
}
