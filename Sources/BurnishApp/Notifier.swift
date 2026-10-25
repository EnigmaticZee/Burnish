import Foundation
import Scheduler
import Store
import UserNotifications

/// At most one notification a day: what Burnish updated on its own, and what's still waiting,
/// with an Update All button when there's something it can install. Permission is asked the
/// first time there's something to say, never at launch.
@MainActor
enum Notifier {
    static let category = "burnish.updates"
    static let updateAllAction = "burnish.update-all"

    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// The Update All button, registered once at launch.
    static func registerActions() {
        guard available else { return }
        let updateAll = UNNotificationAction(identifier: updateAllAction, title: String(localized: "Update All"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [updateAll], intentIdentifiers: []),
        ])
    }

    static func notifyIfNeeded(model: AppModel, autoUpdated: [String] = []) async {
        let outdated = model.outdated
        guard available, model.settings.notificationsEnabled, !outdated.isEmpty || !autoUpdated.isEmpty else { return }
        guard CheckScheduler.mayNotify(lastNotification: model.state.lastNotification) else { return }

        let center = UNUserNotificationCenter.current()
        if !model.state.askedForNotifications {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await model.engine.store.update(.appState, default: AppState()) { $0.askedForNotifications = true }
        }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        if autoUpdated.isEmpty {
            content.title = String(localized: "\(outdated.count) app updates")
            content.body = names(outdated.map(\.app.name))
        } else {
            content.title = String(localized: "Updated \(autoUpdated.count) apps")
            let done = names(autoUpdated)
            content.body = outdated.isEmpty ? done : done + " · " + String(localized: "\(outdated.count) more waiting")
        }
        if !model.updateAllCandidates.isEmpty { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: "burnish.updates", content: content, trigger: nil)
        try? await center.add(request)
        await model.engine.store.update(.appState, default: AppState()) { $0.lastNotification = Date() }
    }

    private static func names(_ all: [String]) -> String {
        all.count > 3
            ? String(localized: "\(all.prefix(3).joined(separator: ", ")) and \(all.count - 3) more")
            : ListFormatter.localizedString(byJoining: all)
    }
}
