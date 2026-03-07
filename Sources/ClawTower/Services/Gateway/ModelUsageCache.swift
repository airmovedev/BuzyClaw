import Foundation

/// Caches ModelUsageInfo per model in UserDefaults so data persists across view transitions.
@MainActor
final class ModelUsageCache {
    static let shared = ModelUsageCache()

    private let defaults = UserDefaults.standard
    private let keyPrefix = "ModelUsageCache_"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func save(_ info: ModelUsageInfo, for modelId: String) {
        guard let data = try? encoder.encode(info) else { return }
        defaults.set(data, forKey: keyPrefix + modelId)
    }

    func load(for modelId: String) -> ModelUsageInfo? {
        guard let data = defaults.data(forKey: keyPrefix + modelId) else { return nil }
        return try? decoder.decode(ModelUsageInfo.self, from: data)
    }

    func clear(for modelId: String) {
        defaults.removeObject(forKey: keyPrefix + modelId)
    }
}
