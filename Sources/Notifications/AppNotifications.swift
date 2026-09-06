import AppKit
import Foundation
import UserNotifications

/// Manages native macOS notification delivery for quota resets and low-quota alerts.
@MainActor
final class AppNotifications {
    static let shared = AppNotifications()

    private let centerProvider: () -> UNUserNotificationCenter
    private var authorizationRequested = false

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    init(centerProvider: @escaping () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.centerProvider = centerProvider
    }

    /// Request permission from macOS to display notification banners.
    func requestAuthorization() {
        guard !Self.isRunningTests, !authorizationRequested else { return }
        authorizationRequested = true
        let center = centerProvider()
        Task {
            try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// Post a native notification banner.
    func post(
        id: String,
        title: String,
        body: String,
        sound: Bool = true
    ) {
        guard !Self.isRunningTests else { return }
        let center = centerProvider()

        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: "codenotch-\(id)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            try? await center.add(request)
        }
    }
}
