# Development notes

Burnish is a native macOS menu bar app (Swift 6, SwiftUI, macOS 14+) that finds updates for every
installed app and installs them safely. Read the README first, then these rules before changing
behaviour.

## Rules of the road

### Trust comes first
- **A wrong alert costs more than a missed one.** Low-confidence matches never say "Update
  available". Unreadable or mismatched versions are "Can't compare", never an update. Every bug in
  version comparison or matching gets a test in `Tests/VersionsTests` or `Tests/CaskIndexTests`.
- **No server, no account, no telemetry, no analytics, no crash reporting that sends data.** Logs
  stay on the Mac.
- **Network requests are limited to the list in the README.** Adding one means adding it to that
  list first. Every request carries Burnish's `User-Agent` (`Net.HTTPClient`) and goes through its
  eight-in-flight limit. Homebrew's cask list is fetched at most once every 24 hours.
- **No third-party dependencies** except Sparkle, which is used only to update Burnish itself.

### Install safety (all must pass, or Burnish offers the download page instead)
1. Trusted origin: an HTTPS URL from the app's own feed or Homebrew's cask data.
2. Sparkle EdDSA signature verifies when the installed app pins `SUPublicEDKey`.
3. SHA-256 (Homebrew) / SHA-512 (Electron) matches when the source gives one.
4. The new copy has a valid signature, passes Gatekeeper, and is signed by an Apple-issued
   certificate for the same Team ID, with the same bundle ID. Unsigned installed apps are never
   replaced.
5. `.pkg` files are never run: verified packages open in Apple's Installer.
6. Graceful quit only: ask, wait 10 seconds, then let the person decide. Never force-quit.
7. The old version goes to the Trash, never deleted; the new one takes its place; relaunch only if
   it was running.
8. Admin rights only through the macOS administrator prompt. Never store a password.

Every check happens before the installed app is touched, against the app as it is on disk at that
moment. Every rule has a test that feeds a bad file and proves the install is refused. Installer
tests run in temporary folders, never `/Applications`, and never use the real Trash.

## Layout

One Swift package, one target per module:

| Target | Role |
| --- | --- |
| `Versions` | Version parsing and comparison rules (pure Swift) |
| `Net` | `HTTPClient` protocol, URLSession client, `MockHTTPClient` for tests |
| `Inventory` | Scan app folders, read Info.plist, receipts, Caskroom, code signatures |
| `CaskIndex` | Homebrew cask cache (ETag, daily), index and matcher |
| `UpdateSources` | App Store, Sparkle, Homebrew, Electron and GitHub sources; release-notes sanitiser |
| `Store` | Settings, ignore rules, match overrides, last results (JSON in Application Support) |
| `Installer` | Download → verify → unpack → verify → quit → replace → relaunch |
| `Scheduler` | Daily background check |
| `BurnishCore` | The per-app decision flow (`StatusDecider`), the checker and install coordination |
| `BurnishApp` | SwiftUI menu bar app, main window, settings, onboarding, Burnish's own updates |
| `BurnishCLI` | The `burnish` command (`inventory`, `check`, `update`) |

## Build, test, release

- SwiftUI's macros ship with Xcode, not the Command Line Tools. The scripts use Xcode's toolchain
  on their own when it's installed; for plain `swift build`, prefix
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `scripts/test.sh` runs the suite (Swift Testing). No network in tests: use `MockHTTPClient` and
  the fixtures under `Tests/*/Fixtures`.
- `scripts/build-app.sh` builds `build/Burnish.app`. It signs ad hoc with a stable designated
  requirement (`identifier "io.github.enigmaticzee.Burnish"`), so macOS keeps the App Management
  grant across updates and Sparkle accepts new builds. A Developer ID signature replaces this once
  there is one (`scripts/sign.sh`).
- After any UI change, render every screen in both themes and look at them:
  `build/Burnish.app/Contents/MacOS/Burnish --render-previews <dir>` (debug builds; add `--demo`
  for the sample apps used in the README art).
- **Burnish's own updates** use Sparkle. The feed is `appcast.xml` on the latest GitHub release;
  updates must be signed with Burnish's EdDSA key. The private key lives in the maintainer's
  Keychain (account `burnish`) and in the `SPARKLE_PRIVATE_KEY` Actions secret; the public key is
  `SUPublicEDKey` in `App/Info.plist`. Never put the private key in the repository.
- **Releasing:** `scripts/build-app.sh <version>` (writes `VERSION`), add the entry to
  `docs/HISTORY.md`, commit, tag `v<version>` and push the tag. The release workflow builds the
  universal app and DMG, signs the update, writes the appcast from the history entry and publishes
  the release.
- **Before a release,** on a fresh macOS user account with a few common apps installed by hand
  (not through Homebrew): install from the DMG, go through onboarding and App Management, run a
  check, update one app, put it back, and confirm the old version landed in the Trash each time.
  Note anything odd in the release notes.
- `docs/HISTORY.md` entries are the release notes everywhere: the GitHub release and, through
  `scripts/release-notes-html.py`, the update window inside Burnish.

## Scripts

| Script | What it does |
| --- | --- |
| `scripts/test.sh` | Runs the test suite |
| `scripts/build-app.sh` | Builds `build/Burnish.app` (`RELEASE=1` for the universal release build) |
| `scripts/make-dmg.sh` | Builds the release app and packs `dist/Burnish.dmg` (needs `dmgbuild`) |
| `scripts/update-strings.sh` | Refreshes the string catalog from the source |
| `scripts/make-icons.sh` | Rebuilds the icons from `App/AppIcon.icon` (Icon Composer) |
| `scripts/make-dmg-art.swift` | Redraws the DMG window background |
| `scripts/make-showcase.sh` | Redraws the README banner from the app's screens, filled with sample apps |
| `scripts/make-cask-fixture.py` | Cuts the test fixtures out of a full copy of Homebrew's cask list |
| `scripts/sign.sh` | Developer ID signing, once there's a certificate |

## Text and translations

Every word Burnish shows goes through the string catalog, `App/Localizable.xcstrings`, so
translations can be added without touching code. Translations themselves wait until the interface
settles; the groundwork is in place.

- Write text as a literal where SwiftUI takes one (`Text("Check Now")`, `Button("Ignore App")`).
  Text built in code, including every message from the core modules, uses
  `String(localized: "…")`. Counts are one string with interpolation (`"\(count) updates"`); the
  catalog holds the plural forms, so never branch on `count == 1` for wording. The one exception
  is text that leaves the number out ("updates waiting" under a big count): catalogs can't
  pluralise that, so it's two strings.
- Things that aren't words (bullets, bare numbers, version strings) use `Text(verbatim:)` or a
  formatter, so they don't end up in the catalog.
- After changing any visible text, run `scripts/update-strings.sh` and commit the catalog with the
  change. `scripts/build-app.sh` compiles it into the app.
- The `burnish` command-line tool and log messages stay in English.

## Commits and release notes

Meaningful first, fun second: every commit and release note says exactly what changed, and the
good ones make you smile while doing it. [docs/VOICE.md](VOICE.md) has the rules and examples;
read it before your first commit.
