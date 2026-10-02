import SwiftUI

@main
struct LuckyMinerApp: App {
    @StateObject private var miner = MiningEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(miner)
                .preferredColorScheme(.dark)
        }
    }
}
