import CloudKit
import SwiftUI

struct iCloudStatusBanner: View {
    let status: CKAccountStatus

    private var message: String {
        switch status {
        case .noAccount:
            return "请在设置中登录 iCloud 以启用消息同步"
        case .restricted:
            return "iCloud 访问受限"
        case .temporarilyUnavailable:
            return "iCloud 暂时不可用，稍后重试"
        case .couldNotDetermine:
            return "正在检查 iCloud 状态..."
        default:
            return ""
        }
    }

    private var icon: String {
        switch status {
        case .noAccount: return "icloud.slash"
        case .restricted: return "lock.icloud"
        case .temporarilyUnavailable: return "icloud.and.arrow.up"
        case .couldNotDetermine: return "icloud"
        default: return "icloud"
        }
    }

    var body: some View {
        if status != .available {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline)
                Text(message)
                    .font(.subheadline)
            }
            .foregroundStyle(.black.opacity(0.8))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.25))
        }
    }
}
