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

    // 从 ~/.openclaw/openclaw.json 动态读取所有已配置模型
    static var modelOptions: [String] {
        let fallbackModels = ["anthropic/claude-sonnet-4-20250514"]

        guard let json = loadPreferredConfig() else {
            return fallbackModels
        }

        var result: [String] = []

        // 1. agents.defaults.model.primary
        if let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let modelConfig = defaults["model"] as? [String: Any] {
            if let primary = modelConfig["primary"] as? String {
                result.append(primary)
            }
            // 2. agents.defaults.model.fallbacks
            if let fallbacks = modelConfig["fallbacks"] as? [String] {
                for fb in fallbacks where !result.contains(fb) {
                    result.append(fb)
                }
            }
        }

        // 3. agents.defaults.models keys
        if let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let defaultModels = defaults["models"] as? [String: Any] {
            for key in defaultModels.keys where !result.contains(key) {
                result.append(key)
            }
        }

        // 4. models.providers 下各 provider 的 models
        if let models = json["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
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
        }

        return result.isEmpty ? fallbackModels : result
    }

    private static func loadPreferredConfig() -> [String: Any]? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/ClawTower/.openclaw/openclaw.json"),
            home.appendingPathComponent(".openclaw/openclaw.json")
        ]

        var best: [String: Any]?
        var bestScore = -1

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let score = modelCount(in: json)
            if score > bestScore {
                best = json
                bestScore = score
            }
        }

        return best
    }

    private static func modelCount(in json: [String: Any]) -> Int {
        var count = 0

        if let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let model = defaults["model"] as? [String: Any] {
            if model["primary"] as? String != nil { count += 1 }
            count += (model["fallbacks"] as? [String] ?? []).count
        }

        if let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let models = defaults["models"] as? [String: Any] {
            count += models.count
        }

        if let models = json["models"] as? [String: Any],
           let providers = models["providers"] as? [String: Any] {
            for value in providers.values {
                if let dict = value as? [String: Any] {
                    count += (dict["models"] as? [[String: Any]])?.count ?? 0
                    count += (dict["models"] as? [String])?.count ?? 0
                }
            }
        }

        return count
    }
}
