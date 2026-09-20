import SwiftUI

@main
struct SenseiApp: App {
    @StateObject private var chat = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chat)
                .preferredColorScheme(.dark)
        }
    }
}
