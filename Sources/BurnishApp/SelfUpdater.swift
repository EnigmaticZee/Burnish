import AppKit
import Observation
import Sparkle

/// Burnish's own updates, via Sparkle. Checks the appcast attached to the latest GitHub release
/// shortly after launch and about once a day after that (if the person leaves that on), downloads
/// new versions quietly and installs them, accepting only updates signed with Burnish's key.
@MainActor
@Observable
final class SelfUpdater {
    static let shared = SelfUpdater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let installer = InstallWhenIdle()

    var automaticallyChecks: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
            controller.updater.automaticallyDownloadsUpdates = automaticallyChecks
        }
    }

    private init() {
        // Off-screen renders must not start a real updater.
        let start = !CommandLine.arguments.contains("--render-previews")
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: installer, userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        if start && automaticallyChecks {
            controller.updater.automaticallyDownloadsUpdates = true
            // Sparkle skips the very first launch and then waits a day between checks; also check
            // shortly after every launch so a new version arrives promptly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [controller] in
                controller.updater.checkForUpdatesInBackground()
            }
        }
    }

    /// Set by the app so an update never restarts Burnish in the middle of installing someone else's.
    var isBusy: () -> Bool {
        get { installer.isBusy }
        set { installer.isBusy = newValue }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// "Updated to Burnish 0.2.0" once, after Sparkle has replaced the app.
    static func versionJustUpdatedTo() -> String? {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "lastRunVersion")
        defaults.set(current, forKey: "lastRunVersion")
        guard let previous, previous != current, !current.isEmpty else { return nil }
        return current
    }
}

/// Sparkle normally installs a downloaded update when the app quits, which a menu bar app rarely
/// does. Install it straight away instead (Burnish relaunches in a moment), but never while it's
/// checking or installing another app's update: then wait until it's done.
private final class InstallWhenIdle: NSObject, SPUUpdaterDelegate {
    var isBusy: () -> Bool = { false }
    private var waiting: Task<Void, Never>?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        // Sparkle calls this on the main thread and wants the block run there too.
        nonisolated(unsafe) let install = install
        MainActor.assumeIsolated {
            waiting?.cancel()
            waiting = Task { @MainActor [weak self] in
                while let self, self.isBusy() {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if Task.isCancelled { return }
                }
                install()
            }
        }
        return true
    }
}
