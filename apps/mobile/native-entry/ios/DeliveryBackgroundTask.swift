import Foundation
import BackgroundTasks

/// Not registered with the Capacitor shell yet. The installed app retries the
/// queue while it is open. iOS may still suspend that work.
enum DeliveryBackgroundTask {
  static let identifier = "app.direct.messaging.delivery"

  static func register(flush: @escaping () async -> Void) {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      guard let refresh = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      let work = Task {
        await flush()
        refresh.setTaskCompleted(success: true)
      }
      refresh.expirationHandler = {
        work.cancel()
        refresh.setTaskCompleted(success: false)
      }
    }
  }

  static func schedule() {
    let request = BGAppRefreshTaskRequest(identifier: identifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }
}
