import Foundation

struct CronJob: Identifiable, Sendable {
    let id: String
    let agentId: String
    let name: String
    let enabled: Bool
    let schedule: CronSchedule
    let message: String
    let lastRunAt: Date?
    let lastStatus: String?
    let nextRunAt: Date?
}

struct CronSchedule: Sendable {
    let kind: String   // "cron" / "every" / "at"
    let expr: String?
    let tz: String?
}

// MARK: - Cron Expression Helpers

enum CronExpressionFormatter {
    private static let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    /// Parse a cron expression into a human-readable Chinese string
    static func humanReadable(_ expr: String?) -> String {
        guard let expr, !expr.isEmpty else { return "未知" }
        let parts = expr.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return expr }

        let minute = parts[0]
        let hour = parts[1]
        let dayOfMonth = parts[2]
        let month = parts[3]
        let dayOfWeek = parts[4]

        let timeStr: String
        if let h = Int(hour), let m = Int(minute) {
            timeStr = String(format: "%02d:%02d", h, m)
        } else {
            timeStr = "\(hour):\(minute)"
        }

        // Every N minutes patterns like */5
        if hour == "*" && minute.hasPrefix("*/") {
            let interval = minute.dropFirst(2)
            return "每 \(interval) 分钟"
        }

        if dayOfMonth == "*" && month == "*" {
            if dayOfWeek == "*" {
                return "每天 \(timeStr)"
            } else {
                let days = dayOfWeek.split(separator: ",").compactMap { Int($0) }
                if !days.isEmpty {
                    let dayStr = days.map { weekdayNames[safe: $0] ?? "\($0)" }.joined()
                    return "每周\(dayStr) \(timeStr)"
                }
                return "每周\(dayOfWeek) \(timeStr)"
            }
        }

        return expr
    }

    /// Extract sort key (hour * 60 + minute) from cron expression
    static func sortMinuteOfDay(_ expr: String?) -> Int {
        guard let expr else { return 9999 }
        let parts = expr.split(separator: " ").map(String.init)
        guard parts.count >= 2,
              let h = Int(parts[1]),
              let m = Int(parts[0]) else { return 9999 }
        return h * 60 + m
    }
}

// MARK: - JSON Parsing

enum CronJobParser {
    static func parse(from data: Data) -> [CronJob] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let details = result["details"] as? [String: Any],
              let jobs = details["jobs"] as? [[String: Any]] else {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let jobs = result["jobs"] as? [[String: Any]] else {
                return []
            }
            return jobs.compactMap(parseJob)
        }
        return jobs.compactMap(parseJob)
    }

    private static func parseJob(_ dict: [String: Any]) -> CronJob? {
        guard let id = dict["id"] as? String else { return nil }

        let agentId = dict["agentId"] as? String
            ?? dict["agent_id"] as? String
            ?? dict["agent"] as? String
            ?? "main"

        let name = dict["name"] as? String
            ?? dict["label"] as? String
            ?? dict["task"] as? String
            ?? id

        let enabled = dict["enabled"] as? Bool ?? true

        let scheduleDict = dict["schedule"] as? [String: Any]
        let cronExpr = scheduleDict?["expr"] as? String
            ?? dict["schedule"] as? String
            ?? dict["cron"] as? String
        let scheduleKind = scheduleDict?["kind"] as? String ?? "cron"
        let scheduleTz = scheduleDict?["tz"] as? String

        let schedule = CronSchedule(kind: scheduleKind, expr: cronExpr, tz: scheduleTz)

        let payloadDict = dict["payload"] as? [String: Any]
        let message = payloadDict?["message"] as? String
            ?? dict["message"] as? String
            ?? dict["task"] as? String
            ?? ""

        let stateDict = dict["state"] as? [String: Any]
        let lastRunAt = parseDate(stateDict?["lastRunAtMs"] ?? dict["lastRunAt"] ?? dict["last_run"])
        let lastStatus = stateDict?["lastStatus"] as? String ?? dict["lastStatus"] as? String
        let nextRunAt = parseDate(stateDict?["nextRunAtMs"] ?? dict["nextRunAt"] ?? dict["next_run"])

        return CronJob(
            id: id,
            agentId: agentId,
            name: name,
            enabled: enabled,
            schedule: schedule,
            message: message,
            lastRunAt: lastRunAt,
            lastStatus: lastStatus,
            nextRunAt: nextRunAt
        )
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let ts = value as? Double {
            return Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
        }
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = formatter.date(from: str) { return d }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: str)
        }
        return nil
    }
}

// MARK: - Today Check

extension CronJob {
    var didRunToday: Bool {
        guard let lastRunAt,
              let tz = TimeZone(identifier: "Asia/Shanghai") else { return false }
        var calendar = Calendar.current
        calendar.timeZone = tz
        return calendar.isDateInToday(lastRunAt)
    }

    var statusColor: String {
        if lastStatus == "error" { return "red" }
        if didRunToday { return "green" }
        return "gray"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
