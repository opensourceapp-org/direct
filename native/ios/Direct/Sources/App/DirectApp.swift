import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let network = NetworkMonitor()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // BGTaskScheduler handlers must be registered before launch finishes.
        BackgroundDelivery.register()
        network.start()
        return true
    }
}

@main
struct DirectApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { phase in model.scenePhaseChanged(phase) }
    }
}
