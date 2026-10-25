import Foundation

/// Settings an organisation enforces with a configuration profile (MDM). Only values macOS marks
/// as forced count, so ordinary preferences can't lock anything. They win over the person's own
/// choices, and the Settings pane shows them as set by the organisation. Keys are documented in
/// docs/ADMINS.md.
public enum ManagedSettings {
    public static let domain = "io.github.enigmaticzee.Burnish"

    public enum Key: String, Sendable, CaseIterable {
        case checkFrequency = "CheckFrequency"
        case notificationsEnabled = "NotificationsEnabled"
        case autoUpdate = "AutoUpdate"
        case autoUpdateWait = "AutoUpdateWait"
        case keepEarlierVersions = "KeepEarlierVersions"
        case scanUserApplications = "ScanUserApplications"
        case homebrewHandling = "HomebrewHandling"
        case appStoreLookups = "AppStoreLookups"
        case communityOverrides = "CommunityOverrides"
        case skipOnboarding = "SkipOnboarding"
    }

    /// The forced value for a key, from the configuration profile.
    public static func forcedValue(_ key: Key) -> Any? {
        guard CFPreferencesAppValueIsForced(key.rawValue as CFString, domain as CFString) else { return nil }
        return CFPreferencesCopyAppValue(key.rawValue as CFString, domain as CFString)
    }

    /// `settings` with every enforced value applied, and which keys are locked.
    public static func apply(to settings: Settings, read: (Key) -> Any? = forcedValue) -> (settings: Settings, locked: Set<Key>) {
        var s = settings
        var locked = Set<Key>()
        func bool(_ key: Key, _ set: (inout Settings, Bool) -> Void) {
            if let value = read(key) as? Bool { set(&s, value); locked.insert(key) }
        }
        func string<T: RawRepresentable>(_ key: Key, _ type: T.Type, _ set: (inout Settings, T) -> Void) where T.RawValue == String {
            if let raw = read(key) as? String, let value = T(rawValue: raw) { set(&s, value); locked.insert(key) }
        }
        string(.checkFrequency, CheckFrequency.self) { $0.checkFrequency = $1 }
        bool(.notificationsEnabled) { $0.notificationsEnabled = $1 }
        bool(.autoUpdate) { $0.autoUpdate = $1 }
        string(.autoUpdateWait, AutoUpdateWait.self) { $0.autoUpdateWait = $1 }
        bool(.keepEarlierVersions) { $0.keepEarlierVersions = $1 }
        bool(.scanUserApplications) { $0.scanUserApplications = $1 }
        string(.homebrewHandling, HomebrewHandling.self) { $0.homebrewHandling = $1 }
        bool(.appStoreLookups) { $0.appStoreLookups = $1 }
        bool(.communityOverrides) { $0.communityOverrides = $1 }
        if read(.skipOnboarding) as? Bool == true { s.hasCompletedOnboarding = true; locked.insert(.skipOnboarding) }
        return (s, locked)
    }
}
