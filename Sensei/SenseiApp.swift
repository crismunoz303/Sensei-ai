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
        _ = BackgroundModelDownloadManager.shared.cleanVisionTemporaryFiles()
        Task { @MainActor in
            SenseiDiagnostics.shared.record(stage: "APP_LIFECYCLE", message: "Application finished launching.")
        }
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

    private static func scenePhaseName(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "ACTIVE"
        case .inactive: return "INACTIVE"
        case .background: return "BACKGROUND"
        @unknown default: return "UNKNOWN"
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chat)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, newPhase in
                    SenseiDiagnostics.shared.record(
                        stage: "APP_LIFECYCLE",
                        message: "Scene phase changed to \(Self.scenePhaseName(newPhase))."
                    )
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
