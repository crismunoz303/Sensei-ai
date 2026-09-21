import SwiftUI
import UIKit
import GoogleSignIn
@preconcurrency import UserNotifications

final class SenseiAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = BackgroundModelDownloadManager.shared
        return true
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
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
                        chat.restoreSelectedModelIfNeeded()
                    default:
                        break
                    }
                }
        }
    }
}
