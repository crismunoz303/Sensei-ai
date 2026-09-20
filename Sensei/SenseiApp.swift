import SwiftUI
import UIKit
import UserNotifications

final class SenseiAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        _ = BackgroundModelDownloadManager.shared
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundModelDownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }

        BackgroundModelDownloadManager.shared
            .setBackgroundEventsCompletionHandler(completionHandler)
    }
}

@main
struct SenseiApp: App {
    @UIApplicationDelegateAdaptor(SenseiAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var chat = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chat)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        BackgroundModelDownloadManager.shared.beginBackgroundHandoff()
                    case .active:
                        BackgroundModelDownloadManager.shared.endBackgroundHandoff()
                    default:
                        break
                    }
                }
        }
    }
}
