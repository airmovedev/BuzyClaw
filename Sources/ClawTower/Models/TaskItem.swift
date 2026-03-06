import Foundation
import SwiftUI

struct TaskItem: Identifiable, Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case todo
        case inProgress
        case inReview
        case done

        var title: String {
            switch self {
            case .todo: "待办"
            case .inProgress: "进行中"
            case .inReview: "待审核"
            case .done: "已完成"
            }
        }
    }

    enum Priority: String, Codable, CaseIterable, Hashable {
        case low
        case medium
        case high
        case urgent

        var color: Color {
            switch self {
            case .low: .gray
            case .medium: .blue
            case .high: .orange
            case .urgent: .red
            }
        }

        var title: String {
            switch self {
            case .low: "低"
            case .medium: "中"
            case .high: "高"
            case .urgent: "紧急"
            }
        }
    }

    var id: String
    var title: String
    var status: Status
    var priority: Priority
    var source: String
    var context: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case priority
        case source
        case context
        case createdAt
        case updatedAt
    }

    init(id: String = UUID().uuidString, title: String, status: Status, priority: Priority, source: String, context: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.source = source
        self.context = context
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(Status.self, forKey: .status)
        priority = try container.decode(Priority.self, forKey: .priority)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        context = try container.decodeIfPresent(String.self, forKey: .context) ?? ""

        let createdString = try container.decode(String.self, forKey: .createdAt)
        let updatedString = try container.decode(String.self, forKey: .updatedAt)
        guard let created = TaskDateCodec.date(from: createdString),
              let updated = TaskDateCodec.date(from: updatedString) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: container, debugDescription: "Invalid ISO8601 datetime")
        }
        createdAt = created
        updatedAt = updated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(priority, forKey: .priority)
        try container.encode(source, forKey: .source)
        try container.encode(context, forKey: .context)
        try container.encode(TaskDateCodec.string(from: createdAt), forKey: .createdAt)
        try container.encode(TaskDateCodec.string(from: updatedAt), forKey: .updatedAt)
    }
}

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case todo
    case inProgress
    case inReview
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .todo: "待办"
        case .inProgress: "进行中"
        case .inReview: "待审核"
        case .done: "已完成"
        }
    }
}

enum TaskDateCodec {
    static func date(from string: String) -> Date? {
        let withFractional = makeFormatter(withFractionalSeconds: true)
        if let value = withFractional.date(from: string) {
            return value
        }
        return makeFormatter(withFractionalSeconds: false).date(from: string)
    }

    static func string(from date: Date) -> String {
        makeFormatter(withFractionalSeconds: true).string(from: date)
    }

    private static func makeFormatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        if withFractionalSeconds {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        } else {
            formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        }
        formatter.timeZone = .current
        return formatter
    }
}
