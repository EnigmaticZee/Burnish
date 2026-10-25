# Version history

## 0.2.0-beta — 2026-10-25
Now accepting returns.

- **Put back the version you had before.** Every update already left the old copy in the Trash;
  now Burnish remembers which one and brings it back in one click, after checking it as carefully
  as a fresh download. It then skips the version you rolled back from, so Update All doesn't undo
  the undo.
- **A history for every app.** Updates found, installs, hand-offs and refusals, newest first, kept
  on your Mac.
- **A desktop widget.** How many updates are waiting, and in the medium size, which ones.
- **Apps with their own updater get it.** Office opens Microsoft AutoUpdate, Adobe apps open
  Creative Cloud, and Setapp and JetBrains apps open Setapp and Toolbox, instead of a download
  page.
- **Tauri apps get checked too.** Burnish finds the update address compiled into the app and asks
  it; the app installs the update itself. They used to wait in *Can't check*, looking left out.
- **App Store updates in one trip.** With several waiting, one click opens the App Store's
  Updates page, where Apple's Update All does them together.
- **Fixed:** error messages no longer say "Feed not reachable" twice in one breath, the welcome
  screen now lists every place Burnish talks to (it was four short), and the disk image has
  proper art and passes strict signature checks.

On the command line, `burnish restore` and `burnish history` do the same as the app. Every word
Burnish shows now lives in a string catalog, ready for translators once the interface settles.

## 0.1.0-alpha — 2026-10-25
First light. Burnish is ready for people who like to try things early.

- **Finds updates for apps from anywhere.** Direct downloads, the Mac App Store and Homebrew,
  checked against each app's own update feed first and Homebrew's public app list second, so the
  version you see is the developer's own wherever it can be.
- **Tells you when it isn't sure.** Apps it can't match confidently wait under *Needs
  confirmation*, and anything it can't check says why. It would rather miss an update than raise a
  false alarm.
- **Updates safely, one click at a time or all at once.** Every download is checked for the
  developer's signature, its checksum and Apple's notarisation before anything changes, apps are
  asked politely to quit (never forced), and the old version goes to the Trash in case you want it
  back.
- **Leaves paid upgrades to you.** A jump like 5.x to 6.x is marked *May be paid* and never
  included in Update All.
- **Keeps itself up to date**, quietly, the same careful way.

This is an alpha: detection has been tested on a handful of Macs, not hundreds. If Burnish matches
an app to the wrong thing, use **Wrong Match? → Report a Wrong Match on GitHub** in the app and it
opens a ready-made issue.
