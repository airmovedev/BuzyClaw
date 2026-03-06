import Foundation

@MainActor
@Observable
final class SkillsService {
    private(set) var skills: [Skill] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func loadSkills() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/node")
            process.arguments = ["/usr/local/lib/node_modules/openclaw/openclaw.mjs", "skills", "list", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                errorMessage = "命令执行失败 (exit \(process.terminationStatus))"
                return
            }

            // Find first '{' to skip any non-JSON prefix
            guard let startIndex = data.firstIndex(of: UInt8(ascii: "{")) else {
                errorMessage = "无法解析 JSON 输出"
                return
            }

            let jsonData = data[startIndex...]
            let response = try JSONDecoder().decode(SkillsListResponse.self, from: Data(jsonData))
            skills = response.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSkillEnabled(name: String, enabled: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(".openclaw/openclaw.json")

        do {
            var json: [String: Any] = [:]
            if let data = try? Data(contentsOf: configURL),
               let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = parsed
            }

            var skillsSection = json["skills"] as? [String: Any] ?? [:]
            var entries = skillsSection["entries"] as? [String: Any] ?? [:]
            var entry = entries[name] as? [String: Any] ?? [:]
            entry["enabled"] = enabled
            entries[name] = entry
            skillsSection["entries"] = entries
            json["skills"] = skillsSection

            let outputData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try outputData.write(to: configURL, options: .atomic)

            // Update local state
            if let idx = skills.firstIndex(where: { $0.name == name }) {
                skills[idx].disabled = !enabled
                skills[idx].eligible = enabled && skills[idx].missing.isEmpty
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
