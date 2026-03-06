import CloudKit
import Foundation

/// Direction of a CloudKit relay message
enum MessageDirection: String, Sendable {
    case toGateway
    case fromGateway
}

/// Status of a CloudKit relay message
enum MessageStatus: String, Sendable {
    case pending
    case delivered
    case read
}

/// A message record stored in CloudKit for iOS ↔ macOS relay
struct MessageRecord: Sendable {
    static let recordType = "MessageRecord"

    let id: String
    let sessionKey: String
    let direction: MessageDirection
    let content: String
    var status: MessageStatus
    let timestamp: Date
    let metadata: String  // JSON string
    var imageAsset: CKAsset?

    /// The CKRecord.ID derived from our message id
    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: CloudKitConstants.zoneID)
    }

    // MARK: - CKRecord conversion

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["id"] = id as CKRecordValue
        record["sessionKey"] = sessionKey as CKRecordValue
        record["direction"] = direction.rawValue as CKRecordValue
        record["content"] = content as CKRecordValue
        record["status"] = status.rawValue as CKRecordValue
        record["timestamp"] = timestamp as CKRecordValue
        record["metadata"] = metadata as CKRecordValue
        if let imageAsset {
            record["imageAsset"] = imageAsset
        }
        return record
    }

    static func from(record: CKRecord) -> MessageRecord? {
        guard
            let id = record["id"] as? String,
            let sessionKey = record["sessionKey"] as? String,
            let directionStr = record["direction"] as? String,
            let direction = MessageDirection(rawValue: directionStr),
            let content = record["content"] as? String,
            let statusStr = record["status"] as? String,
            let status = MessageStatus(rawValue: statusStr),
            let timestamp = record["timestamp"] as? Date
        else {
            return nil
        }
        let metadata = record["metadata"] as? String ?? "{}"
        let imageAsset = record["imageAsset"] as? CKAsset
        var msg = MessageRecord(
            id: id,
            sessionKey: sessionKey,
            direction: direction,
            content: content,
            status: status,
            timestamp: timestamp,
            metadata: metadata
        )
        msg.imageAsset = imageAsset
        return msg
    }
}

/// Shared CloudKit constants
enum CloudKitConstants {
    static let containerID = "iCloud.com.clawtower.app"
    static let zoneName = "ClawTowerZone"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
}
