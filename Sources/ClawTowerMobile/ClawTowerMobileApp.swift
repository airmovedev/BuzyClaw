import SwiftUI
import CloudKit
import UserNotifications

@MainActor
@Observable
final class NavigationState {
    var pendingAgentId: String?
}

@main
struct ClawTowerMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var messageClient = CloudKitMessageClient()
    @State private var snapshotStore = DashboardSnapshotStore()
    @State private var navigationState = NavigationState()
    @State private var speechService = SpeechRecognitionService()
    @Environment(\.scenePhase) private var scenePhase
    private let themeManager = ThemeManager.shared

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
            iCloudStatusBanner(status: messageClient.iCloudStatus)
            TabView {
                MobileAgentListView()
                    .tabItem {
                        Label("对话", systemImage: "bubble.left.and.bubble.right")
                    }

                MobileDashboardView()
                    .tabItem {
                        Label("看板", systemImage: "checklist")
                    }

                MobileSecondBrainView()
                    .tabItem {
                        Label("记忆", systemImage: "brain")
                    }

                MobileCronJobsView()
                    .tabItem {
                        Label("任务", systemImage: "clock")
                    }

                MobileSettingsView()
                    .tabItem {
                        Label("设置", systemImage: "gearshape")
                    }
            }
            } // end VStack
            .environment(\.themeColor, themeManager.themeColor)
            .tint(themeManager.themeColor)
            .environment(messageClient)
            .environment(snapshotStore)
            .environment(navigationState)
            .environment(speechService)
            .alert("iCloud 空间不足", isPresented: $messageClient.showQuotaExceededAlert) {
                Button("好的", role: .cancel) {}
            } message: {
                Text("无法同步数据。请及时扩容或清理空间。")
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    messageClient.appDidBecomeActive()
                    snapshotStore.appDidBecomeActive()
                    UIApplication.shared.applicationIconBadgeNumber = 0
                case .background:
                    messageClient.appDidEnterBackground()
                    snapshotStore.appDidEnterBackground()
                default:
                    break
                }
            }
            .task {
                await NotificationManager.shared.requestPermission()
                UNUserNotificationCenter.current().delegate = appDelegate
                AppDelegate.navigationState = navigationState
                AppDelegate.messageClient = messageClient
                messageClient.start()
                snapshotStore.start()
                // Load WhisperKit model in background so it's ready when user taps mic
                await speechService.loadModel()
            }
        }
    }
}

// MARK: - AppDelegate for remote notification registration

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var navigationState: NavigationState?
    static var messageClient: CloudKitMessageClient?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {}

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard let client = Self.messageClient else {
                completionHandler(.noData)
                return
            }
            let hasNew = await client.handleBackgroundPush()
            completionHandler(hasNew ? .newData : .noData)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sessionKey = userInfo["sessionKey"] as? String {
            let parts = sessionKey.split(separator: ":")
            if parts.count >= 2 {
                let agentId = String(parts[1])
                Task { @MainActor in
                    Self.navigationState?.pendingAgentId = agentId
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager: Sendable {
    static let shared = NotificationManager()

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                print("✅ 通知权限已授权")
            }
        } catch {
            print("⚠️ 通知权限请求失败: \(error.localizedDescription)")
        }
    }

    nonisolated func sendLocalNotification(title: String, body: String, sessionKey: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(200))
        content.sound = .default
        content.userInfo = ["sessionKey": sessionKey]
        content.badge = NSNumber(value: UIApplication.shared.applicationIconBadgeNumber + 1)

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("⚠️ 本地通知发送失败: \(error.localizedDescription)")
            }
        }
    }
}
