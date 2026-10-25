import AppKit
import BurnishCore
import Store
import SwiftUI

/// One pane, kept to ten controls or fewer.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Check for updates", selection: $model.settings.checkFrequency) {
                    ForEach(CheckFrequency.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Notify me when updates are found", isOn: $model.settings.notificationsEnabled)
                Text("At most one notification a day.").font(.caption).foregroundStyle(.secondary)
                Toggle("Open Burnish at login", isOn: $model.settings.launchAtLogin)
                Toggle("Keep Burnish up to date automatically", isOn: Bindable(SelfUpdater.shared).automaticallyChecks)
            }
            Section {
                Toggle("Also check apps in ~/Applications", isOn: $model.settings.scanUserApplications)
                Picker("Apps installed with Homebrew", selection: $model.settings.homebrewHandling) {
                    ForEach(HomebrewHandling.allCases) { Text($0.label).tag($0) }
                }
                Text("By default Burnish shows their status and leaves updating to `brew upgrade --cask`, so the two never fight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Look up App Store apps with Apple", isOn: $model.settings.appStoreLookups)
                Text("Sends the bundle IDs of your App Store apps to Apple's public lookup.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use community match fixes", isOn: $model.settings.communityOverrides)
                Text("Downloads corrections from Burnish's GitHub repository once a day.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            } footer: {
                HStack {
                    Button("App Management Settings…", action: Permissions.openAppManagement)
                    Spacer()
                    Button("Show Burnish's Data") { NSWorkspace.shared.open(model.engine.store.directory) }
                }
                .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

/// First run: what Burnish scans and sends, the App Management permission, then the first scan.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch step {
            case 0: privacy
            case 1: permission
            default: firstScan
            }
        }
        .padding(28)
        .frame(width: 480, height: 460, alignment: .topLeading)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Burnish keeps your apps up to date").font(.title2.weight(.semibold))
            Text("It checks the apps in /Applications and ~/Applications against each app's own update feed, the App Store and Homebrew's public app list.")
                .fixedSize(horizontal: false, vertical: true)
            Text("No account, no analytics, nothing about your apps leaves this Mac except what it takes to ask for updates:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label("Homebrew's app list, once a day", systemImage: "shippingbox")
                Label("Apple's App Store lookup, with your App Store apps' bundle IDs", systemImage: "bag")
                Label("Each app's own update feed, its release notes, and the download itself", systemImage: "arrow.down.circle")
                Label("GitHub, for apps whose downloads live there, and for community match fixes", systemImage: "chevron.left.forwardslash.chevron.right")
                Label("Burnish's own update feed, about once a day", systemImage: "bell")
            }
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Spacer()
                Button("Continue") { step = 1 }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("Allow Burnish to update apps").font(.title2.weight(.semibold))
            Text("macOS asks before one app replaces another. To install updates, turn on Burnish in System Settings → Privacy & Security → App Management.")
            Text("Burnish can find updates without it. It never force-quits an app, always keeps the old version in the Trash, and only installs updates signed by the same developer as the copy you have.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Open System Settings", action: Permissions.openAppManagement)
                Spacer()
                Button("Continue") {
                    step = 2
                    Task { await model.check() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var firstScan: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(model.isChecking ? "Checking your apps" : "All set").font(.title2.weight(.semibold))
            if model.isChecking {
                ProgressView(value: Double(model.checkedCount), total: Double(max(model.totalCount, 1)))
                Text("Checked \(model.checkedCount) of \(model.totalCount) apps").foregroundStyle(.secondary)
            } else {
                let count = model.outdated.count
                Text(count == 0 ? "Everything's up to date." : "\(count) apps have updates.")
                Text("Burnish lives in the menu bar and checks once a day.").foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") {
                    model.markOnboardingDone()
                    dismissWindow(id: "onboarding")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isChecking)
            }
        }
    }
}
