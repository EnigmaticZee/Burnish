# Burnish for IT admins

Burnish can be deployed to a fleet and configured centrally. Settings come from a configuration
profile (MDM); reports come from the command-line tool that ships inside the app.

## Settings by configuration profile

Burnish reads the preference domain `io.github.enigmaticzee.Burnish`. Only values a profile
**enforces** count (macOS marks them as forced), so nothing a user writes with `defaults` can lock
a setting. Enforced settings win over the person's own choices, and Settings shows them disabled
with "Some settings are set by your organisation".

| Key | Type | Values | What it does |
| --- | --- | --- | --- |
| `CheckFrequency` | String | `twiceDaily`, `daily`, `weekly`, `manual` | How often Burnish checks |
| `NotificationsEnabled` | Boolean | | The once-a-day notification |
| `AutoUpdate` | Boolean | | Install minor updates on their own, for apps that aren't open |
| `AutoUpdateWait` | String | `none`, `oneDay`, `threeDays`, `oneWeek` | How long an update must be out first (security updates skip it) |
| `KeepEarlierVersions` | Boolean | | Keep each replaced version for 30 days in Burnish's folder |
| `ScanUserApplications` | Boolean | | Also check `~/Applications` |
| `HomebrewHandling` | String | `showOnly`, `hide`, `upgradeWithBrew` | What to do with apps installed by `brew install --cask` |
| `AppStoreLookups` | Boolean | | Send App Store apps' bundle IDs to Apple's public lookup |
| `CommunityOverrides` | Boolean | | Fetch the community match fixes and feeds from this repository |
| `SkipOnboarding` | Boolean | | Skip the welcome window (grant App Management through the profile too) |

Burnish's own updates use Sparkle's keys in the same domain: `SUEnableAutomaticChecks` and
`SUAutomaticallyUpdate`.

App Management (Privacy & Security) is required for Burnish to replace apps. Grant it with a
Privacy Preferences Policy Control payload (`SystemPolicyAppBundles`) for the bundle ID
`io.github.enigmaticzee.Burnish`.

A minimal profile payload:

```xml
<dict>
    <key>PayloadType</key>
    <string>io.github.enigmaticzee.Burnish</string>
    <key>PayloadIdentifier</key>
    <string>com.example.burnish.settings</string>
    <key>PayloadUUID</key>
    <string>REPLACE-WITH-A-UUID</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>AutoUpdate</key>
    <true/>
    <key>AutoUpdateWait</key>
    <string>threeDays</string>
    <key>SkipOnboarding</key>
    <true/>
</dict>
```

## Reports

The `burnish` tool ships at `/Applications/Burnish.app/Contents/Helpers/burnish` and runs the same
checks as the app, without its window:

```sh
/Applications/Burnish.app/Contents/Helpers/burnish check --json   # every app's status, machine-readable
/Applications/Burnish.app/Contents/Helpers/burnish check --csv
/Applications/Burnish.app/Contents/Helpers/burnish count          # how many updates are waiting
/Applications/Burnish.app/Contents/Helpers/burnish inventory      # bundle IDs, versions, Team IDs, Intel-only apps
```

Run it as the logged-in user (it reads that user's settings and rules). Enforced settings apply
to the command-line tool too. Nothing is sent anywhere; collect the output with your MDM's
scripting tools.
