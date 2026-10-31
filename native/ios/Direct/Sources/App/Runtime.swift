import BackgroundTasks
import DirectCore
import Foundation
import Network
import UIKit

/// The one DirectNode for this process, with the iOS secret store, socket, and WebRTC transport.
@DirectActor
final class Runtime {
    static let shared = Runtime()

    let node: DirectNode

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Direct", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var excluded = support
        var values = URLResourceValues()
        // The store is useless without this device's Keychain key, so it is kept out of backups.
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        node = DirectNode(
            secrets: KeychainSecretStore(),
            storeFile: support.appendingPathComponent("direct.store"),
            sockets: URLSessionSocketFactory(),
            transportFactory: { bootstrap, selfId in WebRTCTransport(bootstrap: bootstrap, selfId: selfId) }
        )
    }
}

/// Network changes reconnect the bootstrap at once instead of waiting for the retry timer.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private var lastSatisfied: Bool?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            guard self?.lastSatisfied != satisfied else { return }
            self?.lastSatisfied = satisfied
            Task { @DirectActor in
                if satisfied { Runtime.shared.node.onNetworkAvailable() } else { Runtime.shared.node.onNetworkLost() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.direct.network"))
    }
}

/// iOS suspends the app shortly after it leaves the screen. Pending messages get one short
/// background window right away, then BGAppRefreshTask passes when the system allows.
/// Nothing can arrive while the app is suspended: there is no push service in this design.
enum BackgroundDelivery {
    static let taskId = "app.direct.messaging.delivery"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let work = Task { @DirectActor in
            let pending = await Runtime.shared.node.backgroundFlush(budgetMs: 25_000)
            if pending > 0 { schedule() }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Called when the app moves to the background with messages still waiting for a receipt.
    @MainActor
    static func flushBeforeSuspension() {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "direct.flush") {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        Task { @DirectActor in
            let pending = await Runtime.shared.node.backgroundFlush(budgetMs: 20_000)
            if pending > 0 { schedule() }
            await MainActor.run {
                if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
            }
        }
    }
}
