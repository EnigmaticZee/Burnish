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
    private var animationTimer: Timer?
    var animationFrame = 0

    init(engine: BurnishEngine = BurnishEngine()) {
        self.engine = engine
    }

    // MARK: Lifecycle

    func start() async {
        await loadSnapshot()

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
    func loadDemo(_ demo: [AppCheckResult], lastCheck: Date) {
        results = demo
        self.lastCheck = lastCheck
        caskDataDate = lastCheck
        caskDataOffline = false
        isOnline = true
    }
    #endif

    /// Loads saved state without scheduling or checking (previews and tests).
    func loadSnapshot() async {
        isLoading = true
        settings = await engine.store.load(.settings, default: Settings())
        isLoading = false
        state = await engine.store.load(.appState, default: AppState())
        if let report = await engine.lastReport() { apply(report) }
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
            problems.append("Couldn't change Open at Login: \(error.localizedDescription)")
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
    var canUpdateAll: Bool { isOnline && (!updateAllCandidates.isEmpty || !appStoreUpdates.isEmpty) }

    func isInstalling(_ result: AppCheckResult) -> Bool {
        if case .running = installStates[result.id] { return true }
        return false
    }

    var anyInstalling: Bool { installStates.values.contains { if case .running = $0 { true } else { false } } }

    /// "Using data from 23 Oct, 09:14" when offline.
    var offlineBanner: String? {
        guard !isOnline || caskDataOffline else { return nil }
        guard let caskDataDate else { return "You're offline" }
        return "Using data from \(caskDataDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
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
        case .brewUpgrade(let token):
            installStates[result.id] = .running(.replacing)
            do {
                try await engine.brewUpgrade(token: token)
                installStates[result.id] = .done(relaunched: false)
                await recheck(result)
            } catch {
                installStates[result.id] = .failed(error.errorDescription ?? "brew upgrade failed")
            }
        case .managedByHomebrew, .none:
            break
        }
    }

    /// Installs everything Burnish can, then sends any App Store updates to the App Store.
    func updateAll() async {
        for result in updateAllCandidates { await update(result) }
        if !appStoreUpdates.isEmpty { openAppStoreUpdates() }
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
        let outcome = await engine.install(result, progress: { phase in
            Task { @MainActor [weak self] in
                guard let self, case .running = self.installStates[id] else { return }
                self.installStates[id] = .running(phase)
            }
        }, askToQuit: { name in
            await MainActor.run { Self.askToQuit(name) }
        })

        switch outcome {
        case .installed(_, let relaunched):
            installStates[id] = .done(relaunched: relaunched)
            AppIcons.forget(result.app.url)
            await recheck(result)
        case .openedInInstaller:
            installStates[id] = .openedInstaller
        case .refused(let refusal):
            if refusal.rule == .permission, refusal.message.contains("App Management") { needsAppManagement = true }
            installStates[id] = .refused(refusal)
        case .cancelled:
            installStates[id] = nil
        }
    }

    /// Rule 6: the app didn't quit within 10 seconds, so the person decides. Never force-quit.
    static func askToQuit(_ name: String) -> QuitDecision {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(name) didn't quit"
        alert.informativeText = "It may have unsaved work. Save it and quit \(name) yourself, then choose Try Again."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel Update")
        return alert.runModal() == .alertFirstButtonReturn ? .tryAgain : .cancel
    }

    // MARK: Ignore rules (F11)

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

    // MARK: Match corrections (F5, F19)

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
