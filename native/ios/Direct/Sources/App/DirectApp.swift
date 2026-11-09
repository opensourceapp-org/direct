import DirectCore
import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let network = NetworkMonitor()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // BGTaskScheduler handlers must be registered before launch finishes.
        BackgroundDelivery.register()
        network.start()
        UNUserNotificationCenter.current().delegate = self
        MessageAlerts.requestPermission()
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(MessageAlerts.uiVisible ? [] : [.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let peer = response.notification.request.content.userInfo[MessageAlerts.peerKey] as? String {
            Task { @MainActor in AppModel.shared?.openChat(peer) }
        }
        completionHandler()
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
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { phase in model.scenePhaseChanged(phase) }
    }
}
