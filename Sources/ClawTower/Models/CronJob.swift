import Foundation

struct CronJob: Identifiable, Sendable {
    let id: String
    var name: String?
    var enabled: Bool
    var schedule: String
    var sessionTarget: String?
    var lastRunAt: Date?
    var lastRunStatus: String?

    var displaySchedule: String {
        // Convert cron expressions to human-readable (simplified)
        if schedule.contains("0 8 * * *") { return "每天 08:00" }
        if schedule.contains("0 0 * * *") { return "每天 00:00" }
        if schedule.contains("0 3 * * *") { return "每天 03:00" }
        return schedule
    }
}
