import AppKit
import BurnishCore
import CaskIndex
import Foundation
import Installer
import Inventory
import Network
import Observation
import Scheduler
import ServiceManagement
import Store
import UpdateSources
import WidgetKit

/// Per-row install progress (the "Installing" and "Install refused" states).
enum InstallState: Equatable {
    case running(InstallPhase)
    case done(relaunched: Bool)
    case openedInstaller
    case refused(InstallRefusal)
    case failed(String)
}

/// Everything the menu bar popover, main window and settings show. Main-actor only.
@MainActor
@Observable
final class AppModel {
    let engine: BurnishEngine
    private let scheduler = CheckScheduler()
    private let pathMonitor = NWPathMonitor()

    private(set) var results: [AppCheckResult] = []
    private(set) var isChecking = false
    private(set) var checkedCount = 0
    private(set) var totalCount = 0
    private(set) var lastCheck: Date?
    private(set) var caskDataDate: Date?
    private(set) var caskDataOffline = false
    private(set) var problems: [String] = []
    private(set) var isOnline = true
    /// Set when an install failed for want of App Management; shown as the menu bar dot.
    var needsAppManagement = false
    var installStates: [String: InstallState] = [:]
    var selectedTab: StatusTab? = .updates
    /// Set after Burnish updated itself, for a one-time note in the popover.
    var justUpdatedTo: String?
    var selectedID: String?
    var settings = Settings() {
        didSet { if settings != oldValue, !isLoading { settingsChanged(from: oldValue) } }
    }
    /// Loading saved settings must not count as the person changing them.
    private var isLoading = false
    private(set) var state = AppState()
    /// What Burnish has done with each app, for the detail pane.
    private(set) var history = UpdateHistory()
    /// Per-app choices: automatic or not, stay on a major version, follow betas.
    private(set) var appRules = AppRules()
    private var animationTimer: Timer?
    var animationFrame = 0

    init(engine: BurnishEngine = BurnishEngine()) {
        self.engine = engine
    }

    // MARK: Lifecycle

    func start() async {
        await loadSnapshot()
        refreshWidget()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        pathMonitor.start(queue: DispatchQueue(label: "burnish.path"))

        reschedule()
        if settings.hasCompletedOnboarding,
           CheckScheduler.isOverdue(lastCheck: lastCheck, interval: settings.checkFrequency.interval) {
            await check(background: true)
        }
    }

    #if DEBUG
    /// Sample results for README art (see PreviewRenderer).
    func loadDemo(_ demo: [AppCheckResult], history: UpdateHistory, lastCheck: Date) {
        results = demo
        self.history = history
        self.lastCheck = lastCheck
        caskDataDate = lastCheck
        caskDataOffline = false
        isOnline = true
    }
    #endif

    /// Loads saved state without scheduling or checking (previews).
    func loadSnapshot() async {
        isLoading = true
        settings = await engine.store.load(.settings, default: Settings())
        isLoading = false
        state = await engine.store.load(.appState, default: AppState())
        if let report = await engine.lastReport() { apply(report) }
        history = await engine.history()
        appRules = await engine.store.load(.appRules, default: AppRules())
        lastCheck = state.lastCheck ?? results.first?.checkedAt
    }

    private func reschedule() {
        scheduler.schedule(every: settings.checkFrequency.interval) { [weak self] in
            await self?.check(background: true)
        }
    }

    private func settingsChanged(from old: Settings) {
        let new = settings
        Task { await engine.store.save(new, .settings) }
        if new.checkFrequency != old.checkFrequency { reschedule() }
        if new.launchAtLogin != old.launchAtLogin { applyLaunchAtLogin(new.launchAtLogin) }
        if new.homebrewHandling != old.homebrewHandling || new.scanUserApplications != old.scanUserApplications
            || new.appStoreLookups != old.appStoreLookups || new.communityOverrides != old.communityOverrides {
            Task { await check() }
        }
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problems.append(String(localized: "Couldn't change Open Burnish at login: \(error.localizedDescription)"))
        }
    }

    // MARK: Checking

    func check(background: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        startAnimation()
        checkedCount = 0
        // A finished install's "Done" shouldn't hide a newer update found by this check.
        installStates = installStates.filter { if case .running = $0.value { true } else { false } }
        let engine = engine
        let settings = settings
        let apps = await Task.detached { engine.scan(settings: settings).apps }.value.filter {
            settings.homebrewHandling != .hide || !$0.isManagedByHomebrew
        }
        totalCount = apps.count

        let report = await engine.check(apps, settings: settings) { [weak self] result in
            await self?.receive(result)
        }
        apply(report)
        await engine.store.save(report, BurnishEngine.lastReportKey)
        state = await engine.store.update(.appState, default: AppState()) { $0.lastCheck = report.finishedAt }
        lastCheck = report.finishedAt
        history = await engine.history()
        refreshWidget()
        isChecking = false
        stopAnimation()
        await engine.releaseCaches()
        if background { await Notifier.notifyIfNeeded(model: self) }
    }

    private func receive(_ result: AppCheckResult) {
        checkedCount += 1
        if let index = results.firstIndex(where: { $0.id == result.id }) {
            results[index] = result
        } else {
            results.append(result)
        }
    }

    private func apply(_ report: CheckReport) {
        results = report.results
        caskDataDate = report.caskDataDate
        caskDataOffline = report.isOffline
        problems = report.problems
    }

    private func replace(_ result: AppCheckResult) {
        if let index = results.firstIndex(where: { $0.id == result.id }) { results[index] = result }
        Task { await persistResults() }
        refreshWidget()
    }

    /// Writes what the desktop widget shows and asks WidgetKit to redraw it.
    private func refreshWidget() {
        let top = outdated.prefix(3).map {
            WidgetSnapshot.Item(name: $0.app.name, installed: $0.app.version.display,
                                latest: $0.status.candidate?.displayVersion ?? "", appPath: $0.app.url.path)
        }
        try? WidgetSnapshot(updateCount: outdated.count, top: Array(top), lastCheck: lastCheck).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func persistResults() async {
        guard var report = await engine.lastReport() else { return }
        report.results = results
        await engine.store.save(report, BurnishEngine.lastReportKey)
    }

    func recheck(_ result: AppCheckResult) async {
        if let fresh = await engine.recheck(result.app, settings: settings) { replace(fresh) }
        await engine.releaseCaches()
    }

    // MARK: Derived lists

    var outdated: [AppCheckResult] { results.filter(\.status.isOutdated) }

    func results(in tab: StatusTab) -> [AppCheckResult] { results.filter { $0.status.tab == tab } }

    func count(_ tab: StatusTab) -> Int { results.reduce(0) { $0 + ($1.status.tab == tab ? 1 : 0) } }

    var updateAllCandidates: [AppCheckResult] {
        outdated.filter { $0.includedInUpdateAll(homebrew: settings.homebrewHandling) && !isInstalling($0) }
    }

    func action(for result: AppCheckResult) -> UpdateAction { result.action(homebrew: settings.homebrewHandling) }

    /// Updates Apple installs. Burnish hands them over in one trip rather than one per app.
    var appStoreUpdates: [AppCheckResult] {
        outdated.filter { if case .openAppStore = action(for: $0) { true } else { false } }
    }

    /// Update All has something to do: an install Burnish can run, or App Store updates to hand over.
    var canUpdateAll: Bool { isOnline && (!updateAllCandidates.isEmpty || !appStoreUpdates.isEmpty || !vendorUpdates.isEmpty) }

    func isInstalling(_ result: AppCheckResult) -> Bool {
        if case .running = installStates[result.id] { return true }
        return false
    }

    var anyInstalling: Bool { installStates.values.contains { if case .running = $0 { true } else { false } } }

    /// "Using data from 23 Oct, 09:14" when offline.
    var offlineBanner: String? {
        guard !isOnline || caskDataOffline else { return nil }
        guard let caskDataDate else { return String(localized: "You're offline") }
        return String(localized: "Using data from \(caskDataDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
    }

    // MARK: Updating

    func update(_ result: AppCheckResult) async {
        switch action(for: result) {
        case .install:
            await install(result)
        case .openAppStore(let url):
            if let url { NSWorkspace.shared.open(url) }
        case .openDownloadPage(let url, _):
            if let url { NSWorkspace.shared.open(url) }
        case .openUpdater(let updater):
            NSWorkspace.shared.open(updater.url)
        case .brewUpgrade(let token):
            installStates[result.id] = .running(.replacing)
            do {
                try await engine.brewUpgrade(result, token: token)
                installStates[result.id] = .done(relaunched: false)
                await recheck(result)
            } catch {
                installStates[result.id] = .failed(error.errorDescription ?? String(localized: "brew upgrade failed"))
            }
            history = await engine.history()
        case .managedByHomebrew, .none:
            break
        }
    }

    /// Installs everything Burnish can, then hands the rest to the App Store and to each
    /// developer's own updater, opening each one once.
    func updateAll() async {
        for result in updateAllCandidates { await update(result) }
        if !appStoreUpdates.isEmpty { openAppStoreUpdates() }
        for updater in vendorUpdates { NSWorkspace.shared.open(updater.url) }
    }

    /// The vendor updaters with something waiting, each once.
    var vendorUpdates: [VendorUpdater] {
        var seen = Set<String>()
        return outdated.compactMap { result -> VendorUpdater? in
            guard case let .openUpdater(updater) = action(for: result), seen.insert(updater.path).inserted else { return nil }
            return updater
        }
    }

    /// One App Store update opens its own page; several open the Updates page, where Apple's Update
    /// All installs them together.
    func openAppStoreUpdates() {
        let pending = appStoreUpdates
        if pending.count == 1, case .openAppStore(let url?) = action(for: pending[0]) {
            NSWorkspace.shared.open(url)
        } else if !pending.isEmpty {
            NSWorkspace.shared.open(AppStoreSource.updatesPage)
        }
    }

    private func install(_ result: AppCheckResult) async {
        guard isOnline else { return }
        let id = result.id
        installStates[id] = .running(.downloading(received: 0, total: nil))
        let outcome = await engine.install(result, progress: progressHandler(id), askToQuit: Self.askToQuitHandler)
        await finish(result, outcome)
    }

    /// The version Burnish can put back: the one its latest update of this app replaced, while
    /// that copy is still in the Trash and the app is still on the version Burnish installed.
    func restorableVersion(_ result: AppCheckResult) -> String? {
        guard case let .updated(from, to, copy?, _, _)? = history.latestUpdate(for: result.app.bundleID)?.kind,
              result.app.version.display == to, FileManager.default.fileExists(atPath: copy) else { return nil }
        return from
    }

    func restore(_ result: AppCheckResult) async {
        let id = result.id
        installStates[id] = .running(.replacing)
        let outcome = await engine.restore(result, progress: progressHandler(id), askToQuit: Self.askToQuitHandler)
        await finish(result, outcome)
    }

    private func progressHandler(_ id: String) -> @Sendable (InstallPhase) -> Void {
        { [weak self] phase in
            Task { @MainActor in
                guard let self, case .running = self.installStates[id] else { return }
                self.installStates[id] = .running(phase)
            }
        }
    }

    private static let askToQuitHandler: @Sendable (String) async -> QuitDecision = { name in
        await MainActor.run { askToQuit(name) }
    }

    private func finish(_ result: AppCheckResult, _ outcome: InstallOutcome) async {
        let id = result.id
        switch outcome {
        case .installed(_, let relaunched):
            installStates[id] = .done(relaunched: relaunched)
            AppIcons.forget(result.app.url)
            await recheck(result)
        case .openedInInstaller:
            installStates[id] = .openedInstaller
        case .refused(let refusal):
            if refusal.rule == .appManagement { needsAppManagement = true }
            installStates[id] = .refused(refusal)
        case .cancelled:
            installStates[id] = nil
        }
        history = await engine.history()
    }

    /// Rule 6: the app didn't quit within 10 seconds, so the person decides. Never force-quit.
    static func askToQuit(_ name: String) -> QuitDecision {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "\(name) didn't quit")
        alert.informativeText = String(localized: "It may have unsaved work. Save it and quit \(name) yourself, then choose Try Again.")
        alert.addButton(withTitle: String(localized: "Try Again"))
        alert.addButton(withTitle: String(localized: "Cancel Update"))
        return alert.runModal() == .alertFirstButtonReturn ? .tryAgain : .cancel
    }

    // MARK: Ignore rules

    func ignoreVersion(_ result: AppCheckResult) async {
        guard let candidate = result.status.candidate else { return }
        await engine.store.update(.ignoreRules, default: IgnoreRules()) { $0.versions[result.app.bundleID] = candidate.displayVersion }
        var changed = result
        changed.status = .ignored(.version(candidate.displayVersion), candidate)
        replace(changed)
    }

    func ignoreApp(_ result: AppCheckResult) async {
        await engine.store.update(.ignoreRules, default: IgnoreRules()) { $0.apps.insert(result.app.bundleID) }
        var changed = result
        changed.status = .ignored(.app, result.status.candidate)
        replace(changed)
    }

    func stopIgnoring(_ result: AppCheckResult) async {
        await engine.store.update(.ignoreRules, default: IgnoreRules()) {
            $0.apps.remove(result.app.bundleID)
            $0.versions[result.app.bundleID] = nil
        }
        await recheck(result)
    }

    // MARK: Per-app rules

    func setRule(_ rule: AppRule, for result: AppCheckResult) async {
        appRules.set(rule, for: result.app.bundleID)
        let rules = appRules
        await engine.store.save(rules, .appRules)
        await recheck(result)
    }

    // MARK: Match corrections

    func confirmMatch(_ result: AppCheckResult, token: String) async {
        await engine.store.update(.userOverrides, default: MatchOverrides()) {
            $0.chosen[result.app.bundleID] = token
            $0.noCask.remove(result.app.bundleID)
        }
        await recheck(result)
    }

    func rejectMatch(_ result: AppCheckResult) async {
        guard let token = result.match?.token else { return }
        await engine.store.update(.userOverrides, default: MatchOverrides()) {
            $0.rejected[result.app.bundleID, default: []].insert(token)
            if $0.chosen[result.app.bundleID] == token { $0.chosen[result.app.bundleID] = nil }
        }
        await recheck(result)
    }

    func reportWrongMatch(_ result: AppCheckResult) {
        NSWorkspace.shared.open(WrongMatchReport.url(for: result))
    }

    // MARK: Animation for the menu bar icon while checking

    private func startAnimation() {
        animationTimer?.invalidate()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.animationFrame += 1 }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = 0
    }

    func markOnboardingDone() {
        settings.hasCompletedOnboarding = true
    }
}
