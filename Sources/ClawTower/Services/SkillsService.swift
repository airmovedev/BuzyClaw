import Foundation

@MainActor
@Observable
final class SkillsService {
    private(set) var skills: [Skill] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private struct RuntimeCommand {
        let executable: URL
        let arguments: [String]
    }

    private static func resolveSkillsRuntimeCommand() -> RuntimeCommand {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledNode = resourceURL.appendingPathComponent("Resources/runtime/node")
            let bundledOpenclaw = resourceURL.appendingPathComponent("Resources/runtime/openclaw/openclaw.mjs")
            if FileManager.default.fileExists(atPath: bundledNode.path)
                && FileManager.default.fileExists(atPath: bundledOpenclaw.path)
            {
                return RuntimeCommand(
                    executable: bundledNode,
                    arguments: [bundledOpenclaw.path, "skills", "list", "--json"]
                )
            }
        }

        // Dev fallback
        return RuntimeCommand(
            executable: URL(fileURLWithPath: "/usr/local/bin/node"),
            arguments: ["/usr/local/lib/node_modules/openclaw/openclaw.mjs", "skills", "list", "--json"]
        )
    }

    func loadSkills() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let command = Self.resolveSkillsRuntimeCommand()
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
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
