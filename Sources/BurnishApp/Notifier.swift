import Foundation
import Scheduler
import Store
import UserNotifications

/// At most one notification a day, listing the count (F13). Permission is asked the first
/// time an update is found, never at launch.
@MainActor
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func notifyIfNeeded(model: AppModel) async {
        let outdated = model.outdated
        guard available, model.settings.notificationsEnabled, !outdated.isEmpty else { return }
        guard CheckScheduler.mayNotify(lastNotification: model.state.lastNotification) else { return }

        let center = UNUserNotificationCenter.current()
        if !model.state.askedForNotifications {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await model.engine.store.update(.appState, default: AppState()) { $0.askedForNotifications = true }
        }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = outdated.count == 1 ? "1 app update" : "\(outdated.count) app updates"
        let names = outdated.prefix(3).map(\.app.name)
        content.body = names.joined(separator: ", ") + (outdated.count > 3 ? " and \(outdated.count - 3) more" : "")
        let request = UNNotificationRequest(identifier: "burnish.updates", content: content, trigger: nil)
        try? await center.add(request)
        await model.engine.store.update(.appState, default: AppState()) { $0.lastNotification = Date() }
    }
}
