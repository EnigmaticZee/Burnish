import AppKit
import BurnishCore
import SwiftUI
import UserNotifications

@main
struct BurnishApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(delegate.model)
        } label: {
            MenuBarLabel()
                .environment(delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Burnish", id: "main") {
            MainWindow()
                .environment(delegate.model)
        }
        .defaultSize(width: 980, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Burnish Updates…") { SelfUpdater.shared.checkForUpdates() }
            }
            CommandMenu("Apps") {
                Button("Check Now") { Task { await delegate.model.check() } }
                    .keyboardShortcut("r")
                Button("Update All") { Task { await delegate.model.updateAll() } }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(!delegate.model.canUpdateAll)
            }
        }

        Window("Welcome to Burnish", id: "onboarding") {
            OnboardingView()
                .environment(delegate.model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if PreviewRenderer.runIfRequested(model: model) { return }
        #endif
        if Notifier.available {
            UNUserNotificationCenter.current().delegate = self
            Notifier.registerActions()
        }
        // Starts Burnish's own update checks; an update waits while Burnish is busy with another app.
        let model = model
        SelfUpdater.shared.isBusy = { model.isChecking || model.anyInstalling }
        model.justUpdatedTo = SelfUpdater.versionJustUpdatedTo()
        Task {
            await model.start()
            if !model.settings.hasCompletedOnboarding { openWindow(id: "onboarding") }
        }
    }

    /// The notification's Update All button updates everything Burnish can; clicking the
    /// notification itself opens the main window on the Updates tab.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Notifier.updateAllAction {
                Task { await model.updateAll() }
            } else {
                model.selectedTab = .updates
                openWindow(id: "main")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// burnish://check, burnish://update-all and burnish://open, for Shortcuts and the widget.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "burnish" {
            switch url.host {
            case "check": Task { await model.check() }
            case "update-all": Task { await model.updateAll() }
            default:
                model.selectedTab = .updates
                openWindow(id: "main")
            }
        }
    }

    /// Opens a SwiftUI `Window` scene from AppKit code.
    private func openWindow(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == id }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        WindowOpener.shared.request(id)
    }
}

/// Holds SwiftUI's `openWindow` action so AppKit callbacks can use it.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    private var pending: [String] = []
    var open: ((String) -> Void)? {
        didSet {
            guard let open else { return }
            pending.forEach(open)
            pending = []
        }
    }

    /// Opens now if SwiftUI is ready, or as soon as it is.
    func request(_ id: String) {
        if let open { open(id) } else { pending.append(id) }
    }
}

/// Captures `openWindow` from the menu bar label, which SwiftUI creates at launch.
struct WindowOpenerBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WindowOpener.shared.open = { id in openWindow(id: id) }
        }
    }
}
