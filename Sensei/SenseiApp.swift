import SwiftUI
import UIKit

final class SenseiAppDelegate: NSObject, UIApplicationDelegate {
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
    @StateObject private var chat = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chat)
                .preferredColorScheme(.dark)
        }
    }
}
